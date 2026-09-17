#!/usr/bin/env python3
"""交互式验证台：一次输入，同时看 C++ 与 Python 两版的模型输出并比对。

只做推理，不做业务前置——输出什么就是模型吐了什么，怎么用是插件的事。

比直接开两个 REPL 省事的地方：
  - 一个输入框跑两版，不一致当场标出来（而不是自己左右对照）
  - `/w` 固定上文，之后只敲拼音（IME 里上文本来就在累积，测长词时不用反复重打）
  - 解码参数用斜杠命令改，改完下一条就生效，不用退出去重开

用法: ./session.py   （或 make repl）
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HISTORY = HERE / ".repl_history"

# 与 ctranslate2::TranslationOptions 默认值一致（见 ct2_backend.h）
DEFAULT_PARAMS: dict[str, object] = {
    "--beam": 1,
    "--num-hypotheses": 1,
    "--max-tokens": 64,
    "--length-penalty": 1.0,
    "--repetition-penalty": 1.2,
    "--topk": 1,
    "--temperature": 1.0,
    "--no-repeat-ngram": 0,
}

# 斜杠命令里的短名 -> 完整参数名
PARAM_ALIASES = {
    "beam": "--beam",
    "nh": "--num-hypotheses",
    "max": "--max-tokens",
    "lp": "--length-penalty",
    "rp": "--repetition-penalty",
    "topk": "--topk",
    "temp": "--temperature",
    "ngram": "--no-repeat-ngram",
}


class Engine:
    """一个推理实现。每次查询起一个一次性进程（模型加载约 0.15s，够快）。"""

    def __init__(self, label: str, cmd: list[str], takes_params: bool):
        self.label = label
        self.base = cmd
        self.model: str | None = None
        self.compute_type: str | None = None
        self.takes_params = takes_params

    def run(self, window: str, prompt: str, params: dict) -> list[dict]:
        cmd = list(self.base) + ["--json"]
        if self.takes_params:
            for k, v in params.items():
                cmd += [k, str(v)]
            if self.compute_type:
                cmd += ["--compute-type", self.compute_type]
        if self.model:
            cmd += ["--model", self.model]
        cmd += [window, prompt]

        proc = subprocess.run(cmd, cwd=HERE, capture_output=True,
                              text=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(
                (proc.stderr.strip().splitlines() or ["未知错误"])[-1])

        obj = json.loads(proc.stdout.strip().splitlines()[-1])
        if "outputs" in obj:  # Python 版返回多候选
            hyps = obj["outputs"]
        else:  # C++ 版只有单条
            hyps = [{"output": obj["output"], "score": None,
                     "ms": obj.get("ms")}]
        return hyps or [{"output": "", "score": None, "ms": None}]


def key_of(h: dict) -> str:
    return h["output"]


def fmt(h: dict, show_score: bool) -> str:
    s = f"output={h['output']!r}"
    if show_score and h.get("score") is not None:
        s += f" score={h['score']:.3f}"
    if h.get("ms") is not None:
        s += f" {h['ms']}ms"
    return s


class Session:
    def __init__(self) -> None:
        self.window = ""
        self.params = dict(DEFAULT_PARAMS)
        self.cpp = Engine("c++", [str(HERE / "infer")], takes_params=False)
        self.py = Engine("py", [str(HERE / ".venv/bin/python"),
                                str(HERE / "infer.py")], takes_params=True)
        self.encoders = [self.cpp] if not (HERE / ".venv/bin/python").exists() \
            else [self.cpp, self.py]

    # ------------------------------------------------------------ 查询 --

    def query(self, window: str, prompt: str) -> None:
        if " " in window:
            print("  上文含空格，会与「首个空格分隔上文/拼音」的约定冲突，"
                  "请改用不含空格的上下文。")
            return

        results: dict[str, list[dict]] = {}
        for eng in self.encoders:
            try:
                results[eng.label] = eng.run(window, prompt, self.params)
            except (RuntimeError, subprocess.TimeoutExpired,
                    json.JSONDecodeError) as e:
                results[eng.label] = []
                print(f"  {eng.label:<5} 失败: {e}")

        print()
        print(f"  window  {window or '(冷启动)'}")
        print(f"  prompt  {prompt}")
        multi = int(self.params["--num-hypotheses"]) > 1
        for eng in self.encoders:
            hyps = results.get(eng.label) or []
            if not hyps:
                continue
            print(f"  {eng.label:<5}   {fmt(hyps[0], multi)}")
            for i, h in enumerate(hyps[1:], start=2):
                print(f"        #{i} {fmt(h, multi)}")

        if len(results) < 2:
            return
        cpp, py = results.get("c++"), results.get("py")
        if not cpp or not py:
            return
        if key_of(cpp[0]) == key_of(py[0]):
            print("  ✓ 一致")
        elif self.params != DEFAULT_PARAMS:
            # 参数只喂给了 Python 侧，两版输入本就不同，差异是预期的
            print("  · 输出不同（Python 侧参数非默认，属预期）")
        else:
            print("  ✗ 不一致 —— 见 README「两版为何会有差异」")
            print(f"      c++: {key_of(cpp[0])!r}")
            print(f"      py : {key_of(py[0])!r}")

    # ------------------------------------------------------------ 命令 --

    def cmd_help(self) -> None:
        print("""\
  直接输入    <拼音>            用当前上文推理（未设上文即冷启动）
              <上文> <拼音>     本条临时指定上文
  /w <文本>   固定上文；/w 单独用则清空（回到冷启动）
  /p <拼音>   同上，显式写法
  参数        仅影响 Python 版；C++ 版固定用插件默认值，代表线上真实行为
  /beam N     /nh N      /max N        束宽 / 候选数 / 最大长度
  /rp F       /lp F      /topk N       重复惩罚 / 长度惩罚 / 采样 topk
  /temp F     /ngram N                 采样温度 / no-repeat-ngram
  /params     查看当前参数       /reset  恢复默认
  /eng cpp|py|both            只跑指定实现
  /model <路径>               更换模型目录（两版共用）
  /ct <精度>                  Python 侧 compute_type，默认 default 与 C++ 同规则解析
                              C++ 固定用插件编译时的能力，传 float32 可看差异
  /help  /quit""")

    def cmd_params(self) -> None:
        print("  " + "  ".join(f"{k}={v}" for k, v in self.params.items()))

    def handle_command(self, line: str) -> bool:
        """返回 False 表示要退出。"""
        parts = line.split(maxsplit=1)
        cmd, arg = parts[0], (parts[1].strip() if len(parts) > 1 else "")

        if cmd in ("/quit", "/q", "/exit"):
            return False
        if cmd == "/help":
            self.cmd_help()
        elif cmd == "/w":
            self.window = arg
            print(f"  上文 = {arg or '(已清空)'}")
        elif cmd == "/p":
            if arg:
                self.query(self.window, arg)
            else:
                print("  用法: /p <拼音>")
        elif cmd == "/params":
            self.cmd_params()
        elif cmd == "/reset":
            self.params = dict(DEFAULT_PARAMS)
            print("  参数已恢复默认")
        elif cmd == "/eng":
            table = {"cpp": [self.cpp], "py": [self.py],
                     "both": [self.cpp, self.py]}
            if arg in table:
                if arg in ("py", "both") and not (HERE / ".venv/bin/python").exists():
                    print("  Python 版不可用，先运行 make venv")
                else:
                    self.encoders = table[arg]
                    print(f"  引擎 = {' + '.join(e.label for e in self.encoders)}")
            else:
                print("  用法: /eng cpp|py|both")
        elif cmd == "/model":
            if not Path(arg).is_dir():
                print(f"  目录不存在: {arg}")
            else:
                for eng in (self.cpp, self.py):
                    eng.model = arg  # 一次性进程，下条查询自然生效
                print(f"  模型 = {arg}")
        elif cmd == "/ct":
            if not arg:
                print(f"  compute_type = "
                      f"{self.py.compute_type or 'default（按模型与构建能力自动解析）'}")
            else:
                self.py.compute_type = arg
                print(f"  py compute_type = {arg}"
                      + ("（与 C++ 不同，输出差异属预期）"
                         if arg != "default" else ""))
        elif cmd in self.params:
            self.set_param(cmd, arg)
        else:
            key = PARAM_ALIASES.get(cmd.lstrip("/"))
            if key:
                self.set_param(key, arg)
            else:
                print(f"  未知命令 {cmd}，/help 看用法")
        return True

    def set_param(self, key: str, arg: str) -> None:
        cur = self.params[key]
        if not arg:
            print(f"  {key} = {cur}")
            return
        try:
            self.params[key] = type(cur)(arg)
            print(f"  {key} = {self.params[key]}")
        except ValueError:
            print(f"  {key} 需要{'整数' if isinstance(cur, int) else '数字'}")

    # ------------------------------------------------------------ 主循环 --

    def run(self) -> int:
        self._load_history()

        print("蚌壳拼音 · 推理验证台")
        print(f"  引擎   {' + '.join(e.label for e in self.encoders)}")
        if len(self.encoders) < 2:
            print("         （缺 Python 版：运行 make venv 可开启交叉比对）")
        print("  输入 <拼音>，或 /help 看命令。\n")

        try:
            while True:
                tag = f"[{self.window}] " if self.window else ""
                try:
                    line = input(f"{tag}> ").strip()
                except EOFError:
                    break
                if not line:
                    continue

                if line.startswith("/"):
                    if not self.handle_command(line):
                        break
                    continue

                if " " in line:
                    window, _, prompt = line.partition(" ")
                    self.query(window, prompt)
                else:
                    self.query(self.window, line)
        except KeyboardInterrupt:
            print()
        finally:
            self._save_history()
        print("再见。")
        return 0

    # 历史文件只是便利：只读挂载、权限受限等情况下写入会抛错，不能让它打断会话
    def _load_history(self) -> None:
        try:
            import readline
            readline.set_history_length(500)
            readline.read_history_file(HISTORY)
        except Exception:
            pass

    def _save_history(self) -> None:
        try:
            import readline
            readline.write_history_file(HISTORY)
        except Exception:
            pass


if __name__ == "__main__":
    if not (HERE / "infer").exists():
        print("缺少 ./infer，先运行 make（本目录）", file=sys.stderr)
        sys.exit(2)
    sys.exit(Session().run())
