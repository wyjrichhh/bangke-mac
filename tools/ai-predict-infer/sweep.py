#!/usr/bin/env python3
"""在标注测试集（accuracy.json）上扫参数，看哪个配置准确率更高。

指标：expect 是否出现在模型输出里。模型会自带标点（`，我想去看看西安的大雁塔。`），
用「包含」而非「相等」，避免把标点算成错误——这是度量约定，不是对输出做加工。
同时给出精确匹配数供参考。

在进程内直接调 Infer，不为每条用例起子进程。

用法: ./sweep.py [组名 ...]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent

# 本脚本依赖 ctranslate2，只有 .venv 里有；被系统 python3 直接跑时自动切过去
try:
    import ctranslate2  # noqa: F401
except ImportError:
    _venv = HERE / ".venv/bin/python"
    if _venv.exists() and Path(sys.executable) != _venv:
        os.execv(str(_venv), [str(_venv), str(Path(__file__).resolve()),
                              *sys.argv[1:]])
    print("缺少 ctranslate2，先运行 make venv", file=sys.stderr)
    raise SystemExit(2)

from infer import DEFAULT_MODEL, Infer  # noqa: E402

CASES = HERE / "accuracy.json"

BASE = dict(max_tokens=64, beam=1, num_hypotheses=1, length_penalty=1.0,
            repetition_penalty=1.2, topk=1, temperature=1.0, no_repeat_ngram=0)

# 每项是一个待试配置；compute_type 变了会重新加载模型（约 1s），其余只换解码参数
CONFIGS: list[tuple[str, dict]] = [
    ("基线（插件默认 compute_type）", {}),
    ("float32", {"compute_type": "float32"}),
    ("int8_float32", {"compute_type": "int8_float32"}),
    ("beam=2", {"beam": 2}),
    ("beam=4", {"beam": 4}),
    ("beam=8", {"beam": 8}),
    ("repetition_penalty=1.0", {"repetition_penalty": 1.0}),
    ("repetition_penalty=1.5", {"repetition_penalty": 1.5}),
    ("length_penalty=0.6", {"length_penalty": 0.6}),
    ("length_penalty=1.5", {"length_penalty": 1.5}),
    ("no_repeat_ngram=3", {"no_repeat_ngram": 3}),
    # 组合：上面单独有效的两项叠起来，以及 beam 下才有意义的 length_penalty
    ("int8 + beam=4", {"compute_type": "int8_float32", "beam": 4}),
    ("int8 + beam=8", {"compute_type": "int8_float32", "beam": 8}),
    ("beam=4 + lp=0.6", {"beam": 4, "length_penalty": 0.6}),
    ("beam=4 + lp=1.5", {"beam": 4, "length_penalty": 1.5}),
    ("beam=4 + rp=1.0", {"beam": 4, "repetition_penalty": 1.0}),
    ("int8 + beam=4 + rp=1.0",
     {"compute_type": "int8_float32", "beam": 4, "repetition_penalty": 1.0}),
]


def nbest(cases: list[dict], inf: Infer, n: int) -> None:
    """取 n 个候选，看正确答案出现在前 k 个里的比例（k=1..n）。

    top-1 修不好的用例，未必没救——可能只是排在后面。这个视角对应产品决策：
    候选栏愿不愿给 AI 多几个位置。
    """
    conf = SimpleNamespace(**{**BASE, "beam": n, "num_hypotheses": n})
    ranks: list[int | None] = []
    for c in cases:
        out = inf.predict(c.get("window", ""), c["prompt"], conf)
        rank = next((i for i, h in enumerate(out, 1)
                     if c["expect"] in h["output"]), None)
        ranks.append(rank)

    print(f"\n  beam={n} / num_hypotheses={n} 的累计覆盖（{len(cases)} 条）\n")
    print(f"  {'前 k 个候选':<14}{'覆盖':>8}{'覆盖率':>10}   相对 top-1")
    top1 = sum(r == 1 for r in ranks)
    for k in range(1, n + 1):
        got = sum(r is not None and r <= k for r in ranks)
        delta = got - top1
        print(f"  前 {k:<12}{got:>4}/{len(cases):<3}{got / len(cases):>9.0%}"
              f"   {f'+{delta}' if delta else '—'}")

    missed = [(c, r) for c, r in zip(cases, ranks) if r is None]
    if missed:
        print(f"\n  {n} 个候选都没覆盖到的 {len(missed)} 条：")
        for c, _ in missed:
            src = f"{c.get('window', '')} + {c['prompt']}".lstrip(" +")
            print(f"    ✗ {src}  期望 {c['expect']!r}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("groups", nargs="*", help="accuracy.json 里的组名，不填跑全部")
    ap.add_argument("--show-misses", action="store_true", help="打印每条未命中的输出")
    ap.add_argument("--nbest", type=int, metavar="N",
                    help="改用 N-best 视角：取 N 个候选，看前 k 个的覆盖率")
    args = ap.parse_args(argv)

    data = json.loads(CASES.read_text(encoding="utf-8"))
    names = args.groups or [k for k in data if not k.startswith("_")]
    for n in names:
        if n not in data:
            print(f"没有这组: {n}；可用: "
                  f"{[k for k in data if not k.startswith('_')]}", file=sys.stderr)
            return 2

    cases = [c for n in names for c in data[n]]

    cache: dict[str, Infer] = {}

    if args.nbest:
        nbest(cases, Infer(Path(DEFAULT_MODEL), "cpu", "default"), args.nbest)
        return 0

    print(f"用例 {len(cases)} 条（{' + '.join(names)}）\n")
    print(f"  {'配置':<30}{'命中':>8}{'精确':>8}   与基线")

    baseline = None
    for label, over in CONFIGS:
        ct = over.get("compute_type", "default")
        if ct not in cache:
            cache[ct] = Infer(Path(DEFAULT_MODEL), "cpu", ct)
        inf = cache[ct]
        conf = SimpleNamespace(**{**BASE, **over})

        hit = exact = 0
        misses = []
        for c in cases:
            out = inf.predict(c.get("window", ""), c["prompt"], conf)
            text = out[0]["output"] if out else ""
            ok = c["expect"] in text
            hit += ok
            exact += text == c["expect"]
            if not ok:
                misses.append((c, text))

        if baseline is None:
            baseline = hit
            delta = "—"
        else:
            d = hit - baseline
            delta = f"{d:+d}" if d else "0"

        print(f"  {label:<30}{hit:>4}/{len(cases):<3}{exact:>4}/{len(cases):<3}   {delta}")

        if args.show_misses and misses:
            for c, text in misses:
                src = f"{c.get('window', '')} + {c['prompt']}".lstrip(" +")
                print(f"      ✗ {src}\n        得到 {text!r}  期望 {c['expect']!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
