#!/usr/bin/env bash
#
# 离屏 dump 候选栏: 把各 CAShapeLayer 的 path、图层树、以及一张像素字符画打成
# 文本。给 Windows 侧 QML 预览对账用 —— 高亮块的位置/尺寸/圆角在路径级上唯一
# 确定, 不必靠肉眼看截图。
#
# 用法:
#   bash tools/preview-test/run-dump.sh [linear|stacked|vertical] [yaml 覆盖行,逗号分隔]
#   例: bash tools/preview-test/run-dump.sh linear "inline_preedit: true,hilited_corner_radius: 7"
#   DUMP_PIXELS=1 时额外渲染像素: 阴影、半透明这类"合成之后才看得见"的效果,
#   图层树只能证明结构、证明不了观感。
#
# 只打印, 不做断言 —— 断言在 run.sh 里。
#
# 退出码:
#   2 = 环境缺失 (没跑过 make deps / 没编译过 librime)
#
# 直接把生产代码 (sources/BangkePreviewView.swift 等) 和 lib/librime.1.dylib
# 链在一起跑, 不复制任何逻辑 —— 跑的是真代码, 不是副本.
#
# 注意: 下面的 SOURCES 与 run.sh 里那份是同一组文件, 两边要一起改。

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
    sources/BangkePreferencesWindow.swift
    sources/BangkeView.swift
    sources/BangkeTheme.swift
    sources/BangkeSettings.swift
    sources/RimePatchFile.swift
    sources/BangkeConfig.swift
    sources/Brand.swift
    sources/BridgingFunctions.swift
)

OUT_DIR="${REPO_ROOT}/build/preview-dump"   # build/ 已在 .gitignore 里
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
    "${SCRIPT_DIR}/dump/main.swift" \
    "${RIME_LIB}"

exec "${OUT_DIR}/run" "$@"
