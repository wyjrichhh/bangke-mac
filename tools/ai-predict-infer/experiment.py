#!/usr/bin/env python3
"""按实验分组批量跑推理，输出对照表与统计。

用例在 cases.json，每组是一次实验。每条只给模型层面的结果：
输入了什么、模型吐了什么、是否等于预期。

不做业务前置判断（不判该输入能不能过插件的门禁、不判输出够不够格当候选）——
这里只探模型本身。业务侧怎么用这些输出，看插件。

用法: ./experiment.py [组名 ...]     （不填则跑全部）
"""
from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path

from session import DEFAULT_PARAMS, Engine

HERE = Path(__file__).resolve().parent
CASES = HERE / "cases.json"

COLS = [("#", 3), ("上文", 22), ("拼音", 20), ("模型输出", 18),
        ("预期", 22), ("结果", 6)]


def width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s: str, n: int) -> str:
    return s + " " * max(0, n - width(s))


def row(cells: list[str], note: str = "") -> str:
    return "  " + "".join(pad(c, w) for c, (_, w) in zip(cells, COLS)) + note


def main(argv: list[str]) -> int:
    groups: dict = json.loads(CASES.read_text(encoding="utf-8"))
    names = argv or list(groups)
    unknown = [n for n in names if n not in groups]
    if unknown:
        print(f"没有这组用例: {', '.join(unknown)}", file=sys.stderr)
        print(f"可用: {', '.join(groups)}", file=sys.stderr)
        return 2

    cpp = Engine("c++", [str(HERE / "infer")], takes_params=False)
    py = Engine("py", [str(HERE / ".venv/bin/python"), str(HERE / "infer.py")],
                takes_params=True)
    has_py = (HERE / ".venv/bin/python").exists()

    for name in names:
        cases = groups[name]
        print(f"\n{'=' * 96}\n{name}\n{'=' * 96}")
        print(row([c for c, _ in COLS], "说明"))

        hits = judged = empty = 0
        diverged = []
        for i, c in enumerate(cases, 1):
            window, prompt = c["window"], c["prompt"]
            try:
                h = cpp.run(window, prompt, DEFAULT_PARAMS)[0]
            except Exception as e:  # noqa: BLE001 - 单条失败不该中断整组
                print(row([str(i), window, prompt, f"跑失败: {e}", "", ""]))
                continue

            if has_py:
                try:
                    if py.run(window, prompt, DEFAULT_PARAMS)[0]["output"] != h["output"]:
                        diverged.append(i)
                except Exception:  # noqa: BLE001
                    diverged.append(i)

            out = h["output"]
            if not out:
                empty += 1
                out = "(无输出)"
            verdict = ""
            expect = c.get("expect", "")
            if expect:
                # expect 可给多个可接受输出（模型自带标点，形式会飘）
                accepted = expect if isinstance(expect, list) else [expect]
                judged += 1
                hits += h["output"] in accepted
                verdict = "✓" if h["output"] in accepted else "✗"
                expect = " | ".join(accepted)

            print(row([str(i), window, prompt, out, expect or "—", verdict], c.get("note", "")))

        total = len(cases)
        if judged:
            print(f"\n  命中预期 {hits}/{judged}")
        if empty:
            print(f"  模型无输出 {empty}/{total}")
        if has_py and diverged:
            print(f"  ⚠ C++/Python 输出不同: 第 {diverged} 条"
                  f"（见 README「两版为何会有差异」）")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
