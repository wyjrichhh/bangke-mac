#!/usr/bin/env python3
"""把品牌字面量对齐到 Brand.xcconfig。

绝大多数身份值由 Xcode 从 xcconfig 直接展开，但有两处 Xcode 展开不了，
必须是字面量，于是只能靠本脚本维护：

  1. resources/Info.plist 的输入模式 dict key —— Xcode 展开 plist 的值，
     但不展开 dict 的 key，`$(BRAND_BUNDLE_ID).Hans` 会原样留下。
  2. resources/InfoPlist.xcstrings 的输入源条目 —— JSON 本地化目录，
     key 必须是字面量、不参与 plist 变量展开。

两处都只做「改名」而不是重建，人工写过的译文原样保留。

用法：python3 scripts/sync-brand.py [--check]
  --check  只校验是否一致，不写文件（不一致时退出码 1）
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XCCONFIG = ROOT / "Brand.xcconfig"
INFOPLIST = ROOT / "resources" / "Info.plist"
XCSTRINGS = ROOT / "resources" / "InfoPlist.xcstrings"


def brand_value(key):
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")
    for line in XCCONFIG.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1)
    raise SystemExit(f"Brand.xcconfig 里找不到 {key}")


def sync_infoplist(bundle_id, check):
    """输入模式的 dict key 形如 <key>id.Hans</key>"""
    text = INFOPLIST.read_text(encoding="utf-8")
    pattern = re.compile(r"(<key>)([^<]*\.(?:Hans|Hant))(</key>)")

    changes = []

    def replace(match):
        old = match.group(2)
        suffix = old.rsplit(".", 1)[1]
        new = f"{bundle_id}.{suffix}"
        if new != old:
            changes.append((old, new))
        return f"{match.group(1)}{new}{match.group(3)}"

    updated = pattern.sub(replace, text)

    if not changes:
        print(f"Info.plist 输入模式 key 已与 {bundle_id} 一致")
        return 0
    if check:
        for old, new in changes:
            print(f"Info.plist: {old} -> {new}", file=sys.stderr)
        return 1

    INFOPLIST.write_text(updated, encoding="utf-8")
    for old, new in changes:
        print(f"Info.plist: {old} -> {new}")
    return 0


def sync_xcstrings(bundle_id, check):
    catalog = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    expected = [bundle_id, f"{bundle_id}.Hans", f"{bundle_id}.Hant"]

    hans_keys = [key for key in strings if key.endswith(".Hans")]
    if len(hans_keys) > 1:
        raise SystemExit(f"InfoPlist.xcstrings 里有多个 .Hans 条目：{hans_keys}")

    if hans_keys:
        old_root = hans_keys[0][: -len(".Hans")]
        stale = [old_root, f"{old_root}.Hans", f"{old_root}.Hant"]
    else:
        stale = []

    if stale == expected:
        print(f"InfoPlist.xcstrings 已与 {bundle_id} 一致")
        return 0
    if not stale:
        raise SystemExit("InfoPlist.xcstrings 里找不到输入源条目，无法推断旧 id，请手工补上")
    if check:
        print(f"InfoPlist.xcstrings: {stale} -> {expected}", file=sys.stderr)
        return 1

    # 先取出再删除，避免新旧 key 撞名时被覆盖
    renamed = {new: strings.pop(old) for old, new in zip(stale, expected) if old in strings}
    strings.update(renamed)
    catalog["strings"] = dict(sorted(strings.items()))

    XCSTRINGS.write_text(
        # Xcode 写 .xcstrings 用的是 " : " 分隔符，跟着它写以免产生无谓 diff
        json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n",
        encoding="utf-8",
    )
    for old, new in zip(stale, expected):
        if old != new:
            print(f"InfoPlist.xcstrings: {old} -> {new}")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    bundle_id = brand_value("BRAND_BUNDLE_ID")
    status = sync_infoplist(bundle_id, args.check)
    status |= sync_xcstrings(bundle_id, args.check)
    return status


if __name__ == "__main__":
    sys.exit(main())
