# ai-predict-infer

脱离输入法探模型本身：加载 `zh-base-ct2-int8`，喂进「上文 + 拼音」，看模型吐什么。

输入法里排错太贵——改配置、重新部署、注销重登，还只能从日志反推。这里把推理单独拎出来，
模型能接收什么输入、对这些输入推理出什么，一敲就知道。

**不做任何业务前置**：不套插件的 prompt 门禁、不剥标点、不判候选资格、不管触发策略。
输出什么就是模型吐了什么。业务侧怎么用这些输出，是插件的事，不在此处模拟。

## 两个版本的分工

| | `main.cc`（C++） | `infer.py`（Python） |
|---|---|---|
| 推理路径 | **直接复用插件的 `ct2_backend.cc`**，与 IME 内同一份代码 | 用 `ctranslate2` + `tokenizers` 复刻 |
| 用途 | 验证线上真实行为 | 快速试解码参数（`--beam`、`--repetition-penalty` 等） |
| 解码参数 | 固定为插件默认值，不可调 | 全部开放 |

`session.py` 是两者的交互式外壳：一次输入跑两版并当场比对。`parity.py` 是无头版本，
用同一批用例做回归。

两版出自同一份推理路径的独立实现，**默认对齐 compute type 后输出应当一致**；
不一致的原因见[「两版为何会有差异」](#两版为何会有差异)。参数只喂给 Python 侧，
调过参之后两版不同是预期的，验证台会标成「属预期」。

## 前置条件

1. 插件目录已就位（`librime/plugins/ai-predict/`），且已预编 CTranslate2 静态库：

   ```bash
   bash librime/install-plugins.sh \
       hchunhui/librime-lua lotem/librime-octagram \
       rime/librime-predict wyjrichhh/librime-ai-predict
   ( cd librime/plugins/ai-predict && make deps )
   ```

2. 模型已下载到 `~/Library/Rime/predict_models/zh-base-ct2-int8/`
   （见插件 README「获取模型」）。

### int8 与 float32

C++ 侧的精度由**链接的 CTranslate2 构建能力**决定，不是这个工具能选的：

| CT2 构建 | `default` 解析为 | 常驻内存 | 推理 p50 |
|---|---|---|---|
| 只有 Accelerate（`WITH_RUY=OFF`） | float32（静默退回） | ~1018 MB | 57 ms |
| Accelerate + ruy（`WITH_RUY=ON`） | int8_float32 | ~295 MB | 41 ms |

模型本身就是 int8（`zh-base-ct2-int8`，权重 226MB）。退回 float32 只是把权重在内存里
展开 4 倍重算，**精度不会变高**，白占内存、白费时间。

开启方式（已应用于插件仓库的 `deps.mk`）：

```diff
-  -DWITH_RUY:BOOL=OFF \
+  -DWITH_RUY:BOOL=ON \
+  -DCMAKE_POLICY_VERSION_MINIMUM:STRING=3.5 \
```

> `CMAKE_POLICY_VERSION_MINIMUM` 是必需的：ruy 内置的 cpuinfo/clog 声明
> `cmake_minimum_required(VERSION 3.1)`，CMake 4.x 已拒绝 < 3.5 的声明。
> `WITH_ACCELERATE` 保持不动——它排在 ruy 前面，float32 仍归它管。

还有一步容易漏：ruy 被编成数十个子归档，而**静态库不吸收依赖**，必须合并成一个
`libruy.a` 放进 `lib/`，插件的 `find_library(RUY_LIBRARY)` 才找得到。
`deps.mk` 里已有这一步，本工具的 Makefile 也会自动探测并链接它。

```bash
cd librime/plugins/ai-predict && make -f deps.mk   # 重编 CT2，约 20-40 分钟
cd ../../../ && make deps && make                  # 重编 librime + App
```

`make deps` 会覆盖 `lib/libctranslate2.a`，动手前先备份。
注意这同时改变线上行为——**装 App 之后输入法也会用 int8**。

## 用法

日常调模型走验证台，一条命令备齐两版：

```bash
make repl       # 交互式验证台（自动编译 C++ 版 + 建好 venv）
```

```
[今天天气] > zenmeyang
  window  今天天气
  prompt  zenmeyang
  c++     output='怎么样' 59ms
  py      output='怎么样'
  ✓ 一致
```

比开两个 REPL 省事的地方：一次输入跑两版并当场比对；`/w 今天天气` 固定上文后只敲拼音
（测长词时不用反复重打上下文）；`/beam`、`/rp` 等参数改完下一条即生效。`/help` 看全部命令。

需要单条调用或写进脚本时：

```bash
make            # 只编译 C++ 版 -> ./infer
make venv       # 只建 Python 版 venv -> ./.venv

./infer 今天天气 zenmeyang          # 带上文
./infer zenmeyang                   # 冷启动（无上文）
./infer                             # 自己的交互模式
./infer --json 今天天气 zenmeyang   # JSON 行，便于脚本消费

./.venv/bin/python infer.py 今天天气 zenmeyang
./.venv/bin/python infer.py --beam 4 --num-hypotheses 3 今天天气 zenmeyang

make check      # 端到端自检：模型能加载 + 示例输入给出预期输出
make parity     # 交叉验证两版是否一致
```

`./infer` 与 `infer.py` 自己的交互模式按行输入 `<上文> <拼音>`（首个空格分隔；
只填拼音即冷启动），`exit` / `quit` 退出。加了 `--json` 后不打印提示符与横幅，
退化为「一行输入换一行 JSON」，可被脚本当子进程驱动。

## 输出字段

| 字段 | 含义 |
|---|---|
| `window` | 喂给模型的上下文（对应插件的 `window_text`） |
| `prompt` | 当前输入的拼音 |
| `input` | 实际送进模型的完整串：`window + <pinyin_start> + prompt + </pinyin_start>` |
| `output` | **模型原始输出**，未经任何加工 |
| `time` | 推理耗时（仅 C++ 版） |

## 实验

`experiment.py` 按组批量跑推理并统计，用例在 `cases.json`：

```bash
./experiment.py                 # 跑全部
./experiment.py "1 · 乱序拼音"   # 只跑一组
```

每条只给模型层面的结果：输入了什么、模型输出什么、是否命中预期。`expect` 可给多个
可接受输出（模型自带标点，形式会飘），例如 `["怎么样", "怎么样？"]`。

加一组实验就是在 `cases.json` 里加一个数组，每条 `{window, prompt, expect?, note?}`。

## 量准确率 / 扫参数

`accuracy.json` 是**标注**测试集（prompt 是正确拼写，expect 是人工确认的正确中文），
`sweep.py` 在它上面比不同配置：

```bash
make sweep                      # 跑内置的配置清单
./sweep.py --show-misses        # 打印每条未命中的实际输出
./sweep.py --nbest 8            # 换 N-best 视角：正确答案出现在前 k 个候选里的比例
```

指标是 `expect` 是否**出现在**输出里——模型会自带标点（`，我想去看看西安的大雁塔。`），
用包含而非相等，避免把标点算成错误。这是度量约定，不是对输出做加工。

### 已知结论（40 条标注集，2026-09-16）

| 配置 | 命中 |
|---|---|
| 基线（float32 + beam=1，即线上） | 38/40 |
| int8_float32 / beam≥2 / 各种组合 | 39/40 |

**解码参数基本没用**：凡是有提升的配置都是 39/40，且修的是同一条用例，组合不叠加；
`repetition_penalty`、`length_penalty`、`no_repeat_ngram` 全是零收益或负收益。

**真正有效的是多给候选**（float32，beam=8 取 8 个）：

| | 覆盖 |
|---|---|
| 前 1 个 | 39/40 (98%) |
| **前 2 个** | **40/40 (100%)** |

剩下那条（`xiandedayanta` → `西岸的大雁塔`）正确答案是第 2 候选，两者分数只差 0.05
（-0.1017 vs -0.1552），模型本来就犹豫。插件目前只放 1 个 AI 候选（`target_index`），
放到 2 个即可全覆盖。

> ⚠️ 40 条样本分辨率很低（1 条 = 2.5%），且都是常用短语、不代表真实输入分布。
> 上面的「+1」不足以判定 int8 一定更好。要下结论得用几百条以上的真实日志样本，
> 方法论见插件 README 的 `scripts/analyze_predictions.py`。

## 两版为何会有差异

**先查 compute type。**

两版的 `--compute-type` 默认都是 `default`，交给 CT2 按「模型 + 本机构建能力」自行解析，
规则相同，正常情况会落在同一精度上。不一致多半说明**两侧链接的 CTranslate2 构建能力不同**：

CT2 的后端判定是「从上往下第一个匹配」（`src/cpu/backend.cc`）：

```
MKL → DNNL → Accelerate → OpenBLAS → ruy
```

其中 **Accelerate 只接 float32，int8 只有 ruy/MKL/DNNL 能接**。所以：

| 构建 | float32 | int8 | `default` 解析为 |
|---|---|---|---|
| Accelerate + ruy（pip wheel） | Accelerate | ruy | int8_float32 |
| 只有 Accelerate（`WITH_RUY=OFF`） | Accelerate | **无后端** | float32（静默退回） |

第二种情况 CT2 会在 stderr 打一条警告：

```
The compute type inferred from the saved model is int8_float32, but the target device
or backend do not support efficient int8_float32 computation. The model weights have
been automatically converted to use the float32 compute type instead.
```

两边精度不同，输出必然不同，而且不是无关紧要的抖动——同一个输入：

| compute type | 输出 |
|---|---|
| float32 | `我想去看看，显得大眼塌。` |
| int8_float32 | `，我想去看看西安的大雁塔。` |

对齐办法：让两侧用同一种 compute type（`--compute-type float32` / `int8_float32`），
或者把两边的 CT2 都编成支持 int8（插件的 `deps.mk` 里 `-DWITH_RUY:BOOL=ON`）。

### 顺带发现：float32 的代价

| | float32 | int8_float32 |
|---|---|---|
| 常驻内存 | ~1018 MB | ~316 MB |
| 推理 p50 | 57 ms | 41 ms |

模型本身就是 int8（`zh-base-ct2-int8`，权重 226MB）。退回 float32 等于把权重在内存里展开
4 倍重算一遍，**精度不会变高**（知识已固化在 int8 里），只是白占内存、白费时间。
