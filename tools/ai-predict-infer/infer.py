#!/usr/bin/env python3
"""独立推理入口（Python 版）：加载模型，跑一次「上文 + 拼音 → 模型输出」。

刻意不做任何业务前置——不套插件的 prompt 门禁、不剥标点、不判候选资格。
这里只回答两件事：模型能接收什么输入、对这些输入推理出什么。

与 main.cc 是同一份推理路径的两种实现，输出应当一致（差异说明见 README）。
分工：本脚本用于快速实验解码参数；main.cc 跑的是线上真正那份 C++ 代码。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import ctranslate2
from tokenizers import Tokenizer

DEFAULT_MODEL = Path.home() / "Library/BangkePinyin/predict_models/zh-base-ct2-int8"

# 与 ct2_backend.cc Detokenize 的跳过集合一致
_DETOKENIZE_SKIP = {
    "<hanzi_start>", "</hanzi_start>", "<s>", "</s>", "<pad>",
    "<|endoftext|>", "<|im_start|>", "<|im_end|>",
    "<|PAD|>", "<|EOS|>", "<|BOS|>", "[CLS]", "[SEP]",
}

# 与 ct2_backend.cc Predict 在解码结果上的二次清理一致（比上面多 pinyin 标签）
_RESULT_STRIP_TAGS = (
    "<hanzi_start>", "</hanzi_start>",
    "<pinyin_start>", "</pinyin_start>",
    "<s>", "</s>", "<pad>",
)


# ------------------------------------------------------------ byte-level --

_DIRECT_BYTES = (
    list(range(ord("!"), ord("~") + 1))
    + list(range(ord("¡"), ord("¬") + 1))
    + list(range(ord("®"), ord("ÿ") + 1))
)
_DIRECT_SET = frozenset(_DIRECT_BYTES)


def _build_byte_maps() -> dict[int, int]:
    """GPT-2 bytes_to_unicode 的逆映射：unicode 码点 -> 原始字节。"""
    u2b: dict[int, int] = {b: b for b in _DIRECT_BYTES}
    n = 0
    for b in range(256):
        if b not in _DIRECT_SET:
            u2b[256 + n] = b
            n += 1
    return u2b


_UNICODE_TO_BYTE = _build_byte_maps()


def byte_level_decode(text: str) -> str:
    out = bytearray()
    for ch in text:
        b = _UNICODE_TO_BYTE.get(ord(ch))
        if b is None:
            out.extend(ch.encode("utf-8"))
        else:
            out.append(b)
    return out.decode("utf-8", errors="replace")


# ------------------------------------------------------------------- 推理 --

class Infer:
    def __init__(self, model_dir: Path, device: str = "cpu",
                 compute_type: str = "default"):
        self.model_dir = Path(model_dir)
        # 默认 "default"：交给 CT2 按模型与构建能力自行解析，与 C++ 侧同一套规则，
        # 两版才会落在同一精度上。想指定就显式传 float32 / int8_float32。
        # 背景见 README「两版为何会有差异」。
        self.translator = ctranslate2.Translator(
            str(self.model_dir), device=device, compute_type=compute_type)
        self.tok = Tokenizer.from_file(str(self.model_dir / "tokenizer.json"))
        self.tok.no_padding()
        self.tok.enable_truncation(max_length=128)

        # end_token 取自 shared_vocabulary.json —— 与 ct2_backend.cc 的
        # token_to_id_ 同源，两版才对得上。
        vocab = json.loads(
            (self.model_dir / "shared_vocabulary.json").read_text(encoding="utf-8"))
        self.end_tokens = [t for t in ("</hanzi_start>", "</s>") if t in vocab]

    def encode(self, text: str) -> list[str]:
        # ct2_backend.cc Tokenize：未带 <pinyin_start> 时自动包裹
        if "<pinyin_start>" not in text:
            text = f"<pinyin_start>{text}</pinyin_start>"
        return self.tok.encode(text).tokens

    def predict(self, window: str, prompt: str, args) -> list[dict]:
        src_tokens = self.encode(
            f"{window}<pinyin_start>{prompt}</pinyin_start>")
        # 与 ct2_backend.cc 的 source_tokens.size() <= 2 短路一致
        if len(src_tokens) <= 2:
            return []

        results = self.translator.translate_batch(
            [src_tokens],
            beam_size=args.beam,
            num_hypotheses=args.num_hypotheses,
            max_decoding_length=args.max_tokens,
            length_penalty=args.length_penalty,
            repetition_penalty=args.repetition_penalty,
            no_repeat_ngram_size=args.no_repeat_ngram,
            sampling_topk=args.topk,
            sampling_temperature=args.temperature,
            end_token=self.end_tokens or None,
            return_scores=args.num_hypotheses > 1,
        )[0]

        return [{
            "output": self._detokenize(tokens),
            "score": (results.scores[i] if results.scores else None),
        } for i, tokens in enumerate(results.hypotheses)]

    def _detokenize(self, tokens: list[str]) -> str:
        raw = "".join(t for t in tokens if t not in _DETOKENIZE_SKIP)
        text = byte_level_decode(raw).replace(" ", "")
        for tag in _RESULT_STRIP_TAGS:
            text = text.replace(tag, "")
        return text


# -------------------------------------------------------------------- CLI --

def run_one(inf: Infer, args, window: str, prompt: str) -> None:
    hyps = inf.predict(window, prompt, args)
    if args.json:
        print(json.dumps({
            "window": window,
            "prompt": prompt,
            "input": f"{window}<pinyin_start>{prompt}</pinyin_start>",
            "outputs": hyps,
        }, ensure_ascii=False), flush=True)
        return

    print(f"window  {window}")
    print(f"prompt  {prompt}")
    if not hyps:
        print("output  (无输出)")
        return
    show_score = args.num_hypotheses > 1
    for i, h in enumerate(hyps):
        prefix = "" if i == 0 else f"#{i + 1} "
        line = f"{prefix}output  {h['output']}"
        if show_score and h["score"] is not None:
            line += f"    score {h['score']:.4f}"
        print(line)


def repl(inf: Infer, args) -> None:
    # --json 下退化为「一行输入换一行 JSON」的协议，不打印提示符与横幅，
    # 以便被 session.py 之类的驱动脚本当作长驻子进程使用。
    if not args.json:
        print("输入 <上文> <拼音>（只填拼音为冷启动），exit/quit 退出。")
    while True:
        try:
            line = input("> " if not args.json else "")
        except EOFError:
            break
        line = line.rstrip("\r")
        if line in ("exit", "quit"):
            break
        if not line.strip():
            continue

        if " " in line:
            window, _, prompt = line.partition(" ")
        else:
            window, prompt = "", line
        if not prompt:
            if not args.json:
                print("需要拼音输入")
            continue
        if not args.json:
            print()
        run_one(inf, args, window, prompt)
        if not args.json:
            print()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("positional", nargs="*",
                    help="[上文] 拼音；不填进入交互模式")
    ap.add_argument("--model", default=str(DEFAULT_MODEL))
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--compute-type", default="default",
                    help="推理精度：default（按模型与构建能力自动解析，与 C++ 同规则）"
                         " / float32 / int8_float32")
    ap.add_argument("--json", action="store_true", help="JSON 行输出")
    # 解码参数：C++ 版固定用插件默认值，这里开放出来做实验
    ap.add_argument("--max-tokens", type=int, default=64)
    ap.add_argument("--beam", type=int, default=1)
    ap.add_argument("--num-hypotheses", type=int, default=1)
    ap.add_argument("--length-penalty", type=float, default=1.0)
    ap.add_argument("--repetition-penalty", type=float, default=1.2)
    ap.add_argument("--topk", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=1.0)
    ap.add_argument("--no-repeat-ngram", type=int, default=0)
    args = ap.parse_args(argv)

    if len(args.positional) > 2:
        ap.error("最多接受两个位置参数（上文、拼音）")

    if not Path(args.model).is_dir():
        print(f"模型目录不存在: {args.model}", file=sys.stderr)
        return 1

    inf = Infer(Path(args.model), args.device, args.compute_type)

    if not args.positional:
        repl(inf, args)
    elif len(args.positional) == 1:
        run_one(inf, args, "", args.positional[0])
    else:
        run_one(inf, args, args.positional[0], args.positional[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
