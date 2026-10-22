# 蚌壳拼音 · macOS

基于 [rime/squirrel（鼠须管）](https://github.com/rime/squirrel) 的 macOS 输入法分支，在 Rime 基础上提供本地神经网络候选、原生可视化设置及蚌壳发行集成。基础输入功能和通用 Rime 配置见[上游项目](https://github.com/rime/squirrel#readme)。

## 我们扩展了什么

- **本地 AI 联想**：接入 [bangke-ai-predict](https://github.com/wyjrichhh/bangke-ai-predict)，结合上文与当前拼音生成汉字候选，在本机通过 CTranslate2 推理。
- **异步结果展示**：输入控制器配合插件 pending 状态推动组合更新，并处理 `_refresh_ui` 等属性，推理完成后刷新候选栏。
- **候选语义配色**：解析 `_comment_highlight`、`_comment_warning`，通过 `accent_text_color`、`warning_text_color` 表达候选注释状态。这套机制可被其他插件复用。
- **原生可视化设置**：通过 AppKit 界面调整外观、按键行为、输入方案和 AI 参数，保存到各自配置位置并部署。
- **独立品牌与数据目录**：应用安装为 `BangkePinyin.app`；用户配置位于 `~/Library/BangkePinyin/`，与鼠须管的 `~/Library/Rime/` 分开。
- **日志与打包集成**：日志集中到 `~/Library/Logs/BangkePinyin/`，归档历史日志；打包脚本负责装配引擎、插件、模型和默认方案。

## 实现机制

```text
按键 → 输入控制器 → Rime 方案 → AI Translator / Filter
                           ↘ 后台模型推理
候选面板 ← 属性通知与会话刷新 ← 推理结果
```

AI 插件负责上下文、推理调度、缓存和候选重排，前端负责会话生命周期与界面更新。插件通过 Context 保留属性传递刷新和注释状态，避免前端直接依赖模型实现。

设置的写入目标按职责划分：前端样式写入 `bangke` 配置，候选数量和 Shift 行为写入 `default` 配置，AI 参数写入具体 schema。界面提供统一 AI 设置，保存时分发到相关方案。

产品名、bundle ID 和配置名集中在 [Brand.xcconfig](Brand.xcconfig)，供工程与打包脚本读取。

## 构建与安装

需要 macOS 13+、Xcode 工具链、CMake 和 Boost。完整构建、插件准备及安装包流程见 [INSTALL.md](INSTALL.md)。

```bash
export BOOST_ROOT="$(brew --prefix boost)"
make deps
make release
make install
```

构建前须按安装文档准备插件及 CTranslate2 依赖。`make install` 安装到 `/Library/Input Methods/BangkePinyin.app`；不要对整个构建使用 `sudo`，所需安装权限由脚本处理。首次安装后注销并重新登录，在系统键盘设置中添加「蚌壳拼音」。

模型、模块加载和 schema 接入说明见[插件文档](https://github.com/wyjrichhh/bangke-ai-predict#readme)。当前默认模型针对简体中文；仅编译前端不会自动完成所有模型与方案配置。

## 源码入口

| 路径 | 职责 |
|---|---|
| `sources/` | 输入控制器、候选面板、设置与属性协议 |
| `librime/` | 引擎及插件集成 |
| `resources/`、`data/` | 应用资源与默认配置 |
| `package/` | 安装包构建与安装脚本 |
| `tools/` | 预览、推理验证等开发工具 |

## 上游与许可

感谢 [rime/squirrel](https://github.com/rime/squirrel)、[rime/librime](https://github.com/rime/librime)、[雾凇拼音](https://github.com/iDvel/rime-ice) 及其贡献者。部分保留属性协议也已贡献到上游；此处描述的是本分支的集成方式，不表示这些能力仅本分支提供。

本项目采用 GPL-3.0，见 [LICENSE.txt](LICENSE.txt)。依赖、插件和模型保留各自许可与版权声明。
