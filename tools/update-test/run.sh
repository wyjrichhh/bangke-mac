#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc "$ROOT/sources/BangkeUpdateChecker.swift" "$ROOT/tools/update-test/main.swift" -o "$TEMP_DIR/check"
"$TEMP_DIR/check" "$@"
