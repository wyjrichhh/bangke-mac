#!/usr/bin/env bash
#
# 编译并运行候选栏预览的离屏测试.
#
# 用法:
#   bash tools/preview-test/run.sh
#
# 退出码:
#   0 = 全部通过
#   1 = 有断言失败
#   2 = 环境缺失 (没跑过 make deps / 没编译过 librime)
#
# 直接把生产代码 (sources/BangkePreviewView.swift 等) 和 lib/librime.1.dylib
# 链在一起跑, 不复制任何逻辑 —— 测的是真代码, 不是副本.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

RIME_LIB="${REPO_ROOT}/lib/librime.1.dylib"
if [ ! -f "${RIME_LIB}" ]; then
    echo "缺少 ${RIME_LIB}" >&2
    echo "先跑 make deps (或 make librime) 把引擎和插件编出来." >&2
    exit 2
fi

# 预览这一条依赖链上的生产代码。新增依赖时这里会以
# "cannot find X in scope" 报错, 按提示补进列表即可。
SOURCES=(
    sources/BangkePreviewView.swift
    sources/BangkeSettingsControls.swift
    sources/BangkePreferencesWindow.swift
    sources/BangkeView.swift
    sources/BangkeTheme.swift
    sources/BangkeSettings.swift
    sources/RimePatchFile.swift
    sources/BangkeConfig.swift
    sources/Brand.swift
    sources/BridgingFunctions.swift
)

OUT_DIR="${REPO_ROOT}/build/preview-test"   # build/ 已在 .gitignore 里
mkdir -p "${OUT_DIR}"

# CLI 二进制的 Bundle.main 需要伪装成 app: BangkePreviewTheme 从
# SharedSupport/<config>.yaml 读基础配置, Brand.configName 从 Info.plist 读。
# Bundle.main 对裸可执行文件的 bundleURL 就是其所在目录。
cp -R "${REPO_ROOT}/data/." "${OUT_DIR}/SharedSupport/" 2>/dev/null || {
    mkdir -p "${OUT_DIR}/SharedSupport" && cp -R "${REPO_ROOT}/data/." "${OUT_DIR}/SharedSupport/"
}
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>RimeConfigName</key><string>bangke</string>' \
    '</dict></plist>' > "${OUT_DIR}/Info.plist"

# librime 走 glog, 部署时会刷一屏 INFO; 只留 warning 及以上.
export GLOG_minloglevel=2

# -enable-bare-slash-regex: BangkeConfig 用了 Swift 正则字面量
# -import-objc-header + -I: rime_api_stdbool.h 与 rime/key_table.h
swiftc \
    -enable-bare-slash-regex \
    -import-objc-header sources/Bangke-Bridging-Header.h \
    -I librime/src -I librime/include -I librime/dist/include \
    -Xlinker -rpath -Xlinker "${REPO_ROOT}/lib" \
    -o "${OUT_DIR}/run" \
    "${SOURCES[@]}" \
    "${SCRIPT_DIR}/Scaffold.swift" \
    "${SCRIPT_DIR}/main.swift" \
    "${RIME_LIB}"

exec "${OUT_DIR}/run"
