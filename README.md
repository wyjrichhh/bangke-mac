蚌殼拼音 · Bangke Pinyin
===

macOS 输入法，由 [中州韻輸入法引擎／Rime Input Method Engine](https://rime.im)
驱动，在词库之上接入**本地神经网络联想**。

蚌殼拼音同名发行版另有 Windows（小狼毫分支）与 Linux（fcitx5-rime 分支）版本。

式恕堂 版權所無

授權條款：[GPL v3](https://www.gnu.org/licenses/gpl-3.0.en.html)

---

## 它能做什么

![demo](docs/ai-predict-demo.gif)

Rime 原本是「查词库」式输入法：输入拼音，按词频列出候选。蚌壳拼音在上面接入**本地神经网络联想**（[librime-ai-predict](https://github.com/wyjrichhh/librime-ai-predict)），结合你刚写下的上文，把你正在输入的拼音更准确地转成汉字，并把结果补进候选栏。

- **结合上文的拼音推理**：模型看的是「上文 + 当前拼音」，把你正在输入的拼音转成最可能的汉字——比如上文是「今天天气」、再输入 `zenmeyang` 时，它结合上下文直接给出「怎么样」，而不是词库按词频挑的默认候选。
- **长词是它的强项**：两个字的词语首选命中率约 92%，详见下方「准确率」。
- **只做它擅长的事**：单字高频词是词库的强项，AI 不跟它抢——单字预测默认交给词库。
- **装上即用**：装好模型和插件、重新部署，AI 候选默认出现在第 2 位，无需理解任何技术细节。

### 准确率

从开发者真实输入日志抽取 3531 条「上文 + 拼音 + 实际提交」，看模型首选是否正好等于用户最终打出的字：

| 提交长度 | 首选命中率 |
|---|---|
| 1 个汉字 | 81.4% |
| 2 个汉字 | 92.4% |
| 3 个汉字 | 84.2% |

整体首选命中率约 **87%**，前三个候选覆盖约 **94%**。上文越丰富、要补的词越长，命中率越高——有充分上下文时，长词的准确率可达 **97%**。

### 隐私：输入内容不出本机

所有推理都在**本机完成**（由 CTranslate2 这个本地神经网络推理引擎直接跑在 CPU 上），不联网、不上传任何输入内容。你打的每一个字、每一段上下文，都只存在于自己的 Mac 上；模型文件也是一次性下载到本地，之后完全离线可用。

## 安装

```bash
sudo make install
```

安装到 `/Library/Input Methods/BangkePinyin.app`。**注销并重新登录** macOS 让系统重新加载输入法。

> 首次安装后到「系统设置 → 键盘 → 输入法」里添加「蚌壳拼音」。

## 构建

### 前置依赖

- macOS 13.0+
- Xcode 14.0+（`xcode-select --install`）
- `brew install cmake boost`
- 可访问 GitHub（拉取若干仓库与子模块）

### 1. 克隆（含子模块）

```bash
git clone --recursive https://github.com/wyjrichhh/bangke-mac.git
cd bangke-mac
```

### 2. 注册插件并预编译 ai-predict 的依赖

Xcode 工程期望 `librime-lua` / `librime-octagram` / `librime-predict` 这 3 个上游插件存在（会被打包到 `BangkePinyin.app/Contents/Frameworks/rime-plugins/`），加上 `librime-ai-predict`，**4 个一起注册**：

```bash
bash librime/install-plugins.sh \
    hchunhui/librime-lua \
    lotem/librime-octagram \
    rime/librime-predict \
    wyjrichhh/librime-ai-predict
```

只有 `ai-predict` 需要额外预编译它依赖的 CTranslate2 静态库（其他 3 个是纯 librime 模块）：

```bash
( cd librime/plugins/ai-predict && make deps )
```

> 漏装任一个插件，编译时会在 "Copy Rime plugins" 阶段报 `librime-xxx.dylib couldn't be opened`。

### 3. 编译

```bash
export BOOST_ROOT="$(brew --prefix boost)"
make deps    # 编译 librime（含 ai_predict 插件）+ plum-data + opencc-data
make         # 编译 BangkePinyin.app
```

> Universal binary、出分发用 pkg（`bash package/build-pkg`）等请参考 [INSTALL.md](INSTALL.md)。

### 4. 下载 AI 模型

```bash
( cd librime/plugins/ai-predict && ./scripts/download_model.sh )
```

模型（约 300MB）会下载并解压到 `~/Library/Rime/predict_models/zh-base-ct2-int8/`。

### 5. 创建用户配置

`*.custom.yaml` 是 Rime 的 patch 文件，**默认不存在**，需要在 `~/Library/Rime/` 下手动创建。

> ⚠️ 当前模型 `zh-base-ct2-int8` **仅针对简体中文训练**，因此下面把字形开关默认置为简体。若你的方案以繁体为主，AI 候选质量会明显下降。

```bash
# default.custom.yaml：把 ai_predict 模块追加到 default.yaml 的 modules 列表
cat > ~/Library/Rime/default.custom.yaml <<'EOF'
patch:
  schema_list:
    - schema: luna_pinyin
  menu/page_size: 5
  'modules/@next': ai_predict
EOF

# luna_pinyin.custom.yaml：把 ai_predict_translator/filter 接入 schema 引擎
cat > ~/Library/Rime/luna_pinyin.custom.yaml <<'EOF'
patch:
  # 朙月拼音 switches 默认顺序为 @0 ascii_mode @1 full_shape @2 simplification；
  # states: [ 漢字, 汉字 ]，reset: 1 表示默认「汉字」(简体)，与模型语种一致
  switches/@2/reset: 1
  engine/translators:
    - ai_predict_translator       # 必须放在第一位
    - punct_translator
    - script_translator
  engine/filters:
    - simplifier
    - uniquifier
    - ai_predict_filter
  ai_predict:
    model_path: predict_models/zh-base-ct2-int8
    min_input_length: 12
    context_window_size: 10
    debounce_ms: 200
    max_tokens: 64
    device: cpu
    target_index: 1
    search_range: 10
EOF
```

> 用其他 schema 时把 `luna_pinyin` 换成对应名字即可，但 `switches/@2/reset` 的下标依赖 `simplification` 在该 schema 中的位置，需对照确认。完整可调项见 [librime-ai-predict README](https://github.com/wyjrichhh/librime-ai-predict#常用配置项)。

### 6. 部署

菜单 → 「重新部署」。完成后切到目标方案，输入拼音串（默认 200ms 防抖）。AI 候选默认出现在第 2 位；触发阈值由 `ai_predict/min_input_length` 控制。

### 7.（可选）让 AI 候选的 "AI" 字样以强调色显示

前端实现了 [rime/squirrel#1124](https://github.com/rime/squirrel/issues/1124) 提案的「语义色 + 保留 property key 协议」。AI 候选的注释由插件通过 `_comment_highlight` 告知前端，前端按配色方案的 `accent_text_color` 上色。**默认未配此色 → 与普通注释同色**，不影响功能。

```bash
cat > ~/Library/Rime/bangke.custom.yaml <<'EOF'
patch:
  preset_color_schemes/native/accent_text_color: 0xff8c5a   # 橙色, BGR
  # 用了其他配色方案时把 native 改成对应方案名
EOF
```

> Rime 颜色用 `0xBBGGRR` 字节序。`0xff8c5a` 表示 R=`5a` G=`8c` B=`ff`，呈现为亮橙偏红。

该机制是**通用的**：任何 librime 插件只要 `ctx->set_property("_comment_highlight", "<idx>")` 就能让对应索引的候选 comment 套这个色。

## 相比上游做了什么

在 Rime 之上，本项目做了 3 类通用的前端增强，**都不绑定 ai_predict 插件**，其他插件也能复用：

| 类别 | 改动 | 用途 |
|---|---|---|
| **日志集中** | 日志路径迁至 `~/Library/Logs/BangkePinyin/`，并开放给插件 | 各插件的日志写到同一目录，方便排查（参见 [rime/librime#983](https://github.com/rime/librime/issues/983)） |
| **语义化注释配色** | 配色方案新增 `accent_text_color` / `warning_text_color` 两个语义色字段 | 配色作者按「功能」命名颜色，无需记住具体索引 |
| **插件↔前端通信协议** | 前端识别 `_*` 前缀的保留属性键：`_comment_highlight`（高亮候选注释）、`_comment_warning`（警告色）、`_refresh_ui`（异步完成后刷新候选栏） | 任何插件都能用少量代码驱动前端刷新候选栏、上色 |

> 协议草案见 [rime/squirrel#1124](https://github.com/rime/squirrel/issues/1124)。

### 品牌配置

产品名、bundle id、连接名、配置文件名等都收敛在 **`Brand.xcconfig`**，Xcode 与打包脚本读同一份值。

> `resources/InfoPlist.xcstrings` 的输入源条目和 `resources/Info.plist` 里两个输入模式
> dict key 是 Xcode 展开不了的字面量，改 `BRAND_BUNDLE_ID` 后需跑一次
> `python3 scripts/sync-brand.py`。

## 常见问题

| 现象 | 检查 |
|---|---|
| 编译时 `BOOST_ROOT` 报错 | 确认 `echo $BOOST_ROOT` 非空且目录存在 |
| `make deps` 卡在 librime 编译 | 网络或 git 子模块问题；可单独重试 `cd librime && make deps` |
| 安装后无 AI 候选 | 检查 `~/Library/Logs/BangkePinyin/` 下日志；确认 schema 的 `engine/translators` 第一位是 `ai_predict_translator` |
| 候选栏不刷新 | 注销重登；或确认装的是本项目而非上游版本；日志里搜 `_refresh_ui` |
| AI 字样没颜色 | 上面的 `accent_text_color` 没配，或配色方案名写错 |

## 使用

- 选取输入法指示器菜单里的【蚌】字图标，开始写字。
- 快捷键 `` Ctrl+` `` 或 `F4` 呼出方案菜单、切换输入方式。
- 定制方法参考线上[帮助文档](https://rime.im/docs/)；编辑用户设定后选「重新部署」生效。
- 安装更多输入方案：[plum](https://github.com/rime/plum) 配置管理器。

## 致谢

本项目基于 [rime/squirrel](https://github.com/rime/squirrel)（【鼠鬚管】）修改而来，
感谢 RIME 开发者与输入方案设计者：

輸入方案設計：

  * 【朙月拼音】系列

    感謝 CC-CEDICT、Android 拼音、新酷音、opencc 等開源項目

程序設計：

  * 佛振
  * Linghua Zhang
  * Chongyu Zhu
  * 雪齋
  * faberii
  * Chun-wei Kuo
  * Junlu Cheng
  * Jak Wings
  * xiehuc

美術：

  * 圖標設計 佛振、梁海、雨過之後
  * 配色方案 Aben、Chongyu Zhu、skoj、Superoutman、佛振、梁海

本品引用了以下開源軟件：

  * Boost C++ Libraries  (Boost Software License)
  * capnproto (MIT License)
  * darts-clone  (New BSD License)
  * google-glog  (New BSD License)
  * Google Test  (New BSD License)
  * LevelDB  (New BSD License)
  * librime  (New BSD License)
  * OpenCC / 開放中文轉換  (Apache License 2.0)
  * plum / 東風破  (GNU Lesser General Public License 3.0)
  * Sparkle  (MIT License)
  * UTF8-CPP  (Boost Software License)
  * yaml-cpp  (MIT License)
