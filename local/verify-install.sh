#!/usr/bin/env bash
#
# verify-install.sh
#
# 装完 蚌壳拼音 (无论用 make install-debug 还是 package/build-pkg 出 pkg)
# 之后, 一键比对"工作区源 / .app 内嵌 / 用户 Rime"三处文件是否同步,
# 以及当前运行的 蚌壳拼音进程加载的到底是不是新装的二进制.
#
# 用法:
#   bash local/verify-install.sh
#
# 退出码:
#   0 = 所有可比对项均一致
#   1 = 至少一处不一致 (具体看输出 ✗ 标记)
#
# 设计目标:
#   - 纯只读, 不动任何文件
#   - 不依赖网络 / 不依赖 codesign 工具链, 任何机器都能跑
#   - 输出按"链路"组织 (源 -> .app -> 用户), 一眼看出卡在哪一层

# NOTE: 不用 pipefail. grep -q 找到匹配后会主动关 stdin, 上游 nm/strings
# 会因为 SIGPIPE 退出码非零 -- 在 pipefail 下会让整条 pipe 被判为 fail,
# 导致"明明有符号却判成 OLD"的假阴性. 这里只保留 -u 防止变量笔误.
set -u

# ---- 解析路径 (脚本位置 -> bangke-mac/ -> open-source/) ------------------
# 目录约定 (与 monorepo 平级 checkout):
#   open-source/
#   ├── librime/      <- 引擎 + 插件源码, cmake build
#   └── bangke-mac/   <- 前端 Xcode 工程, 当前脚本在 bangke-mac/local/ 下
#
# REPO_ROOT 指 bangke-mac/, WORKSPACE_ROOT 指 open-source/ (即 librime 的父目录).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
LIBRIME_ROOT="${WORKSPACE_ROOT}/librime"
DEFAULTS_DIR="${SCRIPT_DIR}/ai-predict-defaults"
APP_NAME="$(bash "${SCRIPT_DIR}/../scripts/brand.sh" APP_NAME)"
APP="/Library/Input Methods/${APP_NAME}"
URIME="${HOME}/Library/Rime"

C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'
C_DIM=$'\033[2m';   C_HDR=$'\033[1;36m'; C_END=$'\033[0m'

# 退出状态: 任何一处不一致就置 1
overall_status=0

# ---- 通用工具 -----------------------------------------------------------

# hash8 <path>  ->  prints "abcdef12" or "MISSING"
hash8() {
  if [ ! -f "$1" ]; then
    echo "MISSING"
    return
  fi
  shasum -a 256 "$1" 2>/dev/null | awk '{print substr($1,1,8)}'
}

# mark <ref_hash> <other_hash>
#   stdout: "="  if same, "≠" if differ, "?" if either is MISSING
#   exit:    0    if same, 1   if differ, 2 if missing
#
# Why exit code: mark() is invoked via $() command substitution, which runs
# in a subshell -- mutating a parent variable from inside is impossible.
# Callers must do `MARK=$(mark a b); rc=$?; [ "$rc" = 1 ] && overall_status=1`.
mark() {
  local a="$1" b="$2"
  if [ "$a" = "MISSING" ] || [ "$b" = "MISSING" ]; then
    printf '%s?%s' "$C_WARN" "$C_END"; return 2
  elif [ "$a" = "$b" ]; then
    printf '%s=%s' "$C_OK" "$C_END"; return 0
  else
    printf '%s≠%s' "$C_BAD" "$C_END"; return 1
  fi
}

# bump_on_mismatch <mark_exit_code>
# Tracks overall_status: any "≠" pushes us to fail. "?" is a soft warning
# (file genuinely doesn't exist, common for postinstall's soft-overwrite
# path) and does NOT fail the run.
bump_on_mismatch() {
  [ "$1" = "1" ] && overall_status=1
  return 0
}

# mark_soft <ref_hash> <other_hash>
#   像 mark, 但语义是"允许不一致" -- 用 ~ 而不是 ≠, 颜色用 WARN, 不影响
#   overall_status. 用于 postinstall 软覆盖 这种"用户侧本来就允许保留
#   自己版本"的对比, 避免脚本被误判为整体失败.
mark_soft() {
  local a="$1" b="$2"
  if [ "$a" = "MISSING" ] || [ "$b" = "MISSING" ]; then
    printf '%s?%s' "$C_WARN" "$C_END"
  elif [ "$a" = "$b" ]; then
    printf '%s=%s' "$C_OK" "$C_END"
  else
    printf '%s~%s' "$C_WARN" "$C_END"
  fi
}

hdr() { printf '\n%s== %s ==%s\n' "$C_HDR" "$1" "$C_END"; }

# ---- 1. 配置文件三方对比 -------------------------------------------------
hdr "配置文件 (yaml)  -- 工作区源 → .app 内嵌 → 用户 Rime"

printf '  %-30s %-10s %-3s %-10s %-3s %-10s\n' \
  "文件" "源" "" ".app" "" "rime"

for f in default.custom.yaml luna_pinyin.custom.yaml rime_ice.custom.yaml bangke.custom.yaml; do
  H_SRC=$(hash8 "${DEFAULTS_DIR}/${f}")
  H_APP=$(hash8 "${APP}/Contents/SharedSupport/ai-predict-defaults/${f}")
  H_URM=$(hash8 "${URIME}/${f}")
  # 源 → .app 必须一致 (打包正确性), 不一致是 hard fail.
  M1=$(mark "$H_SRC" "$H_APP"); bump_on_mismatch $?
  # .app → 用户 Rime: 三个方案文件走 postinstall 合并 (引擎接线取自 .app,
  # 用户改过的值保留), bangke.custom.yaml 走软写入 (用户已有就完全不碰).
  # 两者都会让 hash 对不上, 属正常, 不算失败.
  M2=$(mark_soft "$H_APP" "$H_URM")
  printf '  %-30s %-10s  %s  %-10s  %s  %-10s\n' \
    "$f" "$H_SRC" "$M1" "$H_APP" "$M2" "$H_URM"
done

cat <<EOF

  ${C_DIM}标记含义:${C_END}
    ${C_OK}=${C_END} 两边 hash 一致           ${C_BAD}≠${C_END} 不一致, 打包没同步成功 (源 → .app 必须 =)
    ${C_WARN}~${C_END} 不一致但允许 (用户保留)  ${C_WARN}?${C_END} 其中一侧文件不存在
EOF

# ---- 2. 二进制对比 -------------------------------------------------------
#
# 设计说明:
#   hash 比对 dylib 链路是不可靠的: cmake install 会改 install_name/rpath,
#   Xcode 的 "Copy Rime plugins" build phase 带 CodeSignOnCopy 会重新签名,
#   打包脚本的 codesign --deep 又会再签一次. 这些
#   字节变换都是合法的, 但会让 hash 在链路上不停变.
#
#   真正能跨越变换检测"新代码是否真的生效"的, 是看 dylib 里有没有特定的
#   C++ 符号 / 字符串. 我们检测 `MakeRefreshUIPayload` —— 它是今天为
#   rime/squirrel#1124 协议层抽出来的 helper, 旧版本完全没有.
#   只要装机版的 dylib 里能 nm 出这个符号, 就证明新代码到位了.
#
hdr "二进制  --  各层 dylib 是否包含今天的协议层代码"

# 用 nm 检测一个新代码独有的 mangled C++ 符号. demangled 后是
# rime::predict::protocol::MakeRefreshUIPayload(...). 旧版本里没有.
NEW_SYMBOL='MakeRefreshUIPayload'

# has_new_code <dylib_path>  ->  prints OK/MISSING/MISS
#   stdout: human-readable status string with colour
#   exit:    0=has new code, 1=is old, 2=file missing
#
# 实现细节: nm 输出可能很大. 直接 `nm | grep -q` 在某些 shell 下因为
# grep -q 提前关 stdin -> nm 收到 SIGPIPE -> 整条 pipe 退出码 141 ->
# 在 errexit / pipefail / zsh 默认 PIPE_FAIL 等环境下被误判为失败.
# 改成先把 grep 的命中行收到变量, grep 自然读完输入, 不会触发 SIGPIPE.
has_new_code() {
  local path="$1" hit
  if [ ! -f "$path" ]; then
    printf '%s? file missing%s' "$C_WARN" "$C_END"
    return 2
  fi
  hit=$(nm "$path" 2>/dev/null | grep -F "$NEW_SYMBOL" 2>/dev/null | head -1)
  if [ -n "$hit" ]; then
    printf '%s✓ has %s%s' "$C_OK" "$NEW_SYMBOL" "$C_END"
    return 0
  fi
  printf '%s✗ OLD (no %s)%s' "$C_BAD" "$NEW_SYMBOL" "$C_END"
  return 1
}

# size_kb <path>  ->  "3107K" or "MISS"
size_kb() {
  local s
  s=$(stat -f '%z' "$1" 2>/dev/null) || { echo "MISS"; return; }
  echo "$((s/1024))K"
}

printf '  librime-ai-predict.dylib\n'
for label_path in \
  "[1] librime/build:${LIBRIME_ROOT}/build/lib/rime-plugins/librime-ai-predict.dylib" \
  "[2] librime/dist:${LIBRIME_ROOT}/dist/lib/rime-plugins/librime-ai-predict.dylib" \
  "[3] lib/:${REPO_ROOT}/lib/rime-plugins/librime-ai-predict.dylib" \
  "[4] build/.../.app:${REPO_ROOT}/build/Build/Products/Release/${APP_NAME}/Contents/Frameworks/rime-plugins/librime-ai-predict.dylib" \
  "[5] /Library/.../.app:${APP}/Contents/Frameworks/rime-plugins/librime-ai-predict.dylib"
do
  label="${label_path%%:*}"
  path="${label_path#*:}"
  STATUS=$(has_new_code "$path"); RC=$?
  bump_on_mismatch "$RC"
  printf '    %-25s %-8s  %s\n' "$label" "$(size_kb "$path")" "$STATUS"
done

# 2b. 蚌壳拼音主程序
#
# Swift Release binary 已被 strip, 既找不到 mangled 符号也找不到 type-name
# 字符串(swiftmodule 不打包进 .app, Apple 默认 strip-swift-symbols). 所以
# 这一段不能复用 has_new_code 的"找符号"策略, 改用两条信号:
#
#   - source vs binary mtime: 任何 sources/*.swift 比 binary 新, 就一定
#     是没重新编(Xcode 增量编译保证 source 新 -> binary 应该更新).
#   - build/Release vs /Library/.../.app shasum: installer copy 不改字节,
#     hash 不同就是装的不是 build 出来那一版.
hdr "蚌壳拼音主程序 -- mtime 与 hash 比对"

BUILD_REL="${REPO_ROOT}/build/Build/Products/Release/${APP_NAME}/Contents/MacOS/${APP_NAME%.app}"
BUILD_DBG="${REPO_ROOT}/build/Build/Products/Debug/${APP_NAME}/Contents/MacOS/${APP_NAME%.app}"
INSTALLED="${APP}/Contents/MacOS/${APP_NAME%.app}"

# 找 sources/ 下最新的 swift 源文件 mtime (epoch 秒)
SRC_MAX_MTIME=$(find "${REPO_ROOT}/sources" -name '*.swift' -exec stat -f '%m %N' {} \; 2>/dev/null | sort -n | tail -1)
SRC_MAX_EPOCH="${SRC_MAX_MTIME%% *}"
SRC_MAX_FILE="${SRC_MAX_MTIME#* }"
SRC_MAX_HUMAN=$(stat -f '%Sm' "$SRC_MAX_FILE" 2>/dev/null)

printf '  最新 swift 源       %s\n' "$SRC_MAX_HUMAN"
printf '                       %s\n' "$(basename "$SRC_MAX_FILE")"

for label_path in \
  "[R] build/Release:${BUILD_REL}" \
  "[D] build/Debug:${BUILD_DBG}"
do
  label="${label_path%%:*}"
  path="${label_path#*:}"
  if [ ! -f "$path" ]; then
    printf '  %-20s %s? not built%s\n' "$label" "$C_WARN" "$C_END"
    continue
  fi
  bin_epoch=$(stat -f '%m' "$path")
  bin_human=$(stat -f '%Sm' "$path")
  if [ "$bin_epoch" -ge "$SRC_MAX_EPOCH" ]; then
    printf '  %-20s %s (%s✓ 比最新源新%s)\n' "$label" "$bin_human" "$C_OK" "$C_END"
  else
    printf '  %-20s %s (%s✗ 比最新源旧, 没重编%s)\n' "$label" "$bin_human" "$C_BAD" "$C_END"
    overall_status=1
  fi
done

# build/Release vs 系统装机 hash 比对 (installer 不改字节)
H_R=$(hash8 "$BUILD_REL")
H_I=$(hash8 "$INSTALLED")
printf '  hash build/Release   %s\n' "$H_R"
printf '  hash installed       %s  ' "$H_I"
if [ "$H_I" = "MISSING" ]; then
  printf '%s? installed 文件缺失%s\n' "$C_WARN" "$C_END"
  overall_status=1
elif [ "$H_R" = "$H_I" ]; then
  printf '%s= 系统装的就是 build/Release%s\n' "$C_OK" "$C_END"
else
  printf '%s≠ 系统装的不是 build/Release%s\n' "$C_BAD" "$C_END"
  overall_status=1
fi

# ---- 3. 运行时状态 -------------------------------------------------------
hdr "运行时"

PID=$(pgrep -f "${APP_NAME}/Contents/MacOS/${APP_NAME%.app}" 2>/dev/null | head -1)
if [ -n "$PID" ]; then
  STARTED=$(ps -o lstart= -p "$PID" 2>/dev/null | sed 's/  */ /g')
  echo "  蚌壳拼音进程         PID=${PID}, 启动于${STARTED}"
  # 看进程加载的 dylib 与安装位置是否一致
  # lsof NAME 列从第 9 列起延伸到行末; 用 sub() 啃掉前 8 列才能保留路径里的空格
  LOADED=$(lsof -p "$PID" 2>/dev/null | awk '/librime-ai-predict\.dylib/ {
    for (i = 1; i <= 8; i++) sub(/^[^ ]+ +/, "");
    print
    exit
  }')
  if [ -n "$LOADED" ]; then
    printf '  实际加载的 dylib      %s\n' "$LOADED"
    # 直接对运行时加载的那个 dylib 做符号检测, 一锤定音
    printf '  含新协议层代码        '
    STATUS=$(has_new_code "$LOADED"); RC=$?
    printf '%s\n' "$STATUS"
    bump_on_mismatch "$RC"
  else
    printf '  %s? 没找到进程加载 librime-ai-predict.dylib%s\n' "$C_WARN" "$C_END"
  fi
else
  printf '  %s? 当前没有 蚌壳拼音进程在运行 (装完了但还没切到蚌壳拼音输入法?)%s\n' "$C_WARN" "$C_END"
fi

APP_VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${APP}/Contents/Info.plist" 2>/dev/null || echo '(unknown)')
APP_MTIME=$(stat -f '%Sm' "${APP}/Contents/MacOS/${APP_NAME%.app}" 2>/dev/null || echo '(unknown)')
APP_CTIME=$(stat -f '%Sm' "${APP}" 2>/dev/null || echo '(unknown)')
echo "  App 版本号            ${APP_VER}"
echo "  蚌壳拼音二进制 mtime ${APP_MTIME}  (打包时间)"
echo "  .app 目录 ctime       ${APP_CTIME}  (装机时间)"

# ---- 4. 总结 ------------------------------------------------------------
hdr "结论"
if [ "$overall_status" -eq 0 ]; then
  printf '  %s✓ 全链路对得上, 当前运行的是最新版本%s\n' "$C_OK" "$C_END"
else
  cat <<EOF
  ${C_BAD}✗ 至少有一处没对上, 请按上面的 ${C_BAD}≠${C_END}${C_BAD} / ${C_BAD}✗ OLD${C_END}${C_BAD} 行向上溯源找断点.${C_END}

  ${C_DIM}常见断点 → 解法:${C_END}
    [1] librime/build 旧:
        librime 那边根本没编出新版本.
        cd librime && make clean && make release install
    [2] librime/dist 旧 (但 [1] 新):
        cmake build 了但没 install. cd librime && make install
    [3] lib/ 旧 (但 [2] 新):
        librime 新版没拷到本仓库工作区.
        cd .. && cp -L librime/dist/lib/rime-plugins/librime-ai-predict.dylib lib/rime-plugins/
    [4] build/Release/.app 旧 (但 [3] 新):
        xcodebuild 没重新打包, 用了旧的 .app 产物.
        rm -rf build/Build/Products && make release
    [5] /Library/.../.app 旧 (但 [4] 新):
        新 .app 编出来了但没装到系统.
        sudo installer -pkg package/${APP_NAME%.app}.pkg -target /   (或 sudo make install-debug)
    进程没重启:
        killall "${APP_NAME%.app}"
EOF
fi

exit "$overall_status"
