#!/bin/bash
# 读取 Brand.xcconfig 的单一事实来源，供 Makefile 与打包脚本使用。
#
# 只做 CLI、不供 source：`source` 会把调用方的位置参数带进来，取错值。
#   PRODUCT_NAME="$(bash scripts/brand.sh BRAND_PRODUCT_NAME)"
#   APP_NAME="$(bash scripts/brand.sh APP_NAME)"

set -e

BRAND_XCCONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Brand.xcconfig"
[ -f "${BRAND_XCCONFIG}" ] || { echo "找不到 ${BRAND_XCCONFIG}" >&2; exit 1; }

brand() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${BRAND_XCCONFIG}" | head -1
}

case "${1:-}" in
    "")
        echo "用法: bash scripts/brand.sh <KEY>" >&2
        echo "可用 KEY: $(sed -n 's/^\(BRAND_[A-Z_]*\)[[:space:]]*=.*/\1/p' "${BRAND_XCCONFIG}" | tr '\n' ' ')APP_NAME" >&2
        exit 1
        ;;
    APP_NAME) echo "$(brand BRAND_PRODUCT_NAME).app" ;;
    *) brand "$1" ;;
esac
