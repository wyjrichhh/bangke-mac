#!/usr/bin/env python3
"""交叉验证：C++ 版与 Python 版跑同一组输入，比对模型输出。

两版是同一份推理路径的独立实现（C++ 直接复用插件代码，Python 复刻），
输出不一致即说明其中一侧有问题——这正是保留两个版本的意义。
差异的成因与已知边界见 README「两版为何会有差异」。

用法:
    ./parity.py                     # 用默认用例
    ./parity.py "上文" "pinyin" ...  # 临时加用例（成对出现）

退出码非 0 表示存在不一致。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

CASES: list[tuple[str, str]] = [
    ("今天天气", "zenmeyang"),
    ("", "zenmeyang"),
    ("今天天气很好，我们出去", "womenchuquwan"),
    ("这个方案的问题在于", "xingnengbugou"),
    ("我看了一下", "zhege"),
]


def norm_cpp(obj: dict) -> str:
    return obj["output"]


def norm_py(obj: dict) -> str:
    outs = obj.get("outputs") or [{"output": ""}]
    return outs[0]["output"]


def run(cmd: list[str]) -> dict:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"{' '.join(cmd)} 退出码 {proc.returncode}\n{proc.stderr.strip()}")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main(argv: list[str]) -> int:
    cases = CASES
    if argv:
        if len(argv) % 2:
            print("用例需成对给出：<上文> <拼音>", file=sys.stderr)
            return 2
        cases = list(zip(argv[0::2], argv[1::2]))

    cpp_bin = HERE / "infer"
    if not cpp_bin.exists():
        print(f"缺少 {cpp_bin}，先运行 make", file=sys.stderr)
        return 2

    py_bin = Path(os.environ.get("PARITY_PYTHON", HERE / ".venv/bin/python"))
    if not py_bin.exists():
        print(f"缺少 {py_bin}，先运行 make venv", file=sys.stderr)
        return 2

    failed = 0
    for window, prompt in cases:
        label = f"{window or '(冷启动)'} + {prompt}"
        try:
            cpp = norm_cpp(run([str(cpp_bin), "--json", window, prompt]))
            py = norm_py(run([str(py_bin), str(HERE / "infer.py"),
                              "--json", window, prompt]))
        except (RuntimeError, json.JSONDecodeError) as e:
            print(f"FAIL  {label}\n      {e}")
            failed += 1
            continue

        if cpp == py:
            print(f"ok    {label}  ->  {cpp!r}")
        else:
            print(f"FAIL  {label}\n      c++: {cpp!r}\n      py : {py!r}")
            failed += 1

    print(f"\n{len(cases) - failed}/{len(cases)} 一致")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
