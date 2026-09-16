# local/ — 分发用内容物

打包逻辑不在这里，唯一入口是 `package/build-pkg`。本目录只放它要用的**内容物**：
出厂配置、扩展词库、rime-ice 资源。

本目录**已入库**，clone 完就能直接打包。唯一不进库的是 `local/cache/`（CT2 模型，
约 230M），已在 `.gitignore` 里显式排除，见下方「模型来源」。

## 目录结构

```
local/
├── ai-predict-defaults/             # 安装时落到 ~/Library/Rime/ 的默认配置与词库
│   ├── default.custom.yaml          hard-overwrite   引擎接线（挂 ai_predict 模块）
│   ├── luna_pinyin.custom.yaml      hard-overwrite   translator/filter 链
│   │                                 改动前务必先读下方「简繁默认」一节
│   ├── rime_ice.custom.yaml         hard-overwrite   雾凇拼音同上
│   ├── bangke.custom.yaml           soft-write      出厂外观默认值
│   │                                 （候选横排、AI 注释强调色、隐藏菜单栏图标）
│   └── dicts/                       44M 扩展词库
├── rime-ice/                        雾凇拼音资源（3.8M），随包分发
├── cache/                           (可选，不入库) 模型缓存，MODEL_SRC 优先查这里
│   └── predict_models/zh-base-ct2-int8/
├── verify-install.sh                装完后的只读校验脚本
└── README.md                        本文件
```

> hard-overwrite = 每次安装强制覆盖；soft-write = 仅当用户没有同名文件时才写入。
> 理由见下方「安装时对用户 Rime 目录的处理」。

## 打包

```bash
# 默认: arm64 + 公证, 模型从 ~/Library/Rime/predict_models/ 取
bash package/build-pkg

# Universal binary
ARCHS='arm64 x86_64' bash package/build-pkg

# 跳过编译, 复用 build/ 下已有 .app（公证失败重试时常用）
SKIP_BUILD=1 bash package/build-pkg

# 本机自测, 不公证
SKIP_NOTARIZE=1 bash package/build-pkg

# 显式指定模型源
MODEL_SRC=~/work/zh-base-ct2-int8 bash package/build-pkg
```

成品：`package/BangkePinyin-<版本>-ai-predict-<arch>.pkg`，约 230 MB。
（`make package` 是同一脚本的别名。）

**正式包只在 `main` 分支出。** 其他分支上跑会产出测试包：文件名带 `-test-<分支>`
后缀、默认跳过公证、首尾各打一次提示。这样「合入 main 前本地验证」不占公证时间，
测试包也不会被误当正式包发出去。要验证公证流程就显式 `SKIP_NOTARIZE=0`。

内容物默认从本目录取，可用 `ASSETS_DIR` / `DEFAULTS_DIR` / `RIME_ICE_DIR` 覆盖。

> 本机调试直装不走打包，用 `make install` / `make install-debug`
> （`scripts/dev-install`，不签名不公证，秒级）。

## 为什么打包脚本只有一份

历史上是两条链路：上游的 `package/make_package` + `Distribution` + `sign_app`
（服务于上游发布），和本分发版自己的签名打包脚本（要额外注入 CT2 模型、出厂配置、
分发版安装钩子）。两条并存会让**安装行为漂移**——同一个版本用不同命令打出来，
装完的结果不一样。

上游那条已删除，只留 `package/build-pkg`；它唯一使用的安装钩子是
`package/dist-scripts/{preinstall,postinstall}`。

## 安装时对用户 Rime 目录的处理

`package/dist-scripts/preinstall`（写入 .app 之前）：

1. 把 `~/Library/Rime/` **完整复制**到 `~/Library/Rime.backup-<时间戳>/` 兜底
2. **只移除**会与本版冲突的：`default.custom.yaml`、`luna_pinyin.custom.yaml`、
   `rime_ice.custom.yaml`、`build/`（旧 deploy 产物，本次会重新生成）
3. **保留**用户私有数据：`installation.yaml`（安装 ID）、`user.yaml`（偏好）、
   `*.userdb` / `*.userdb.txt`（词库与学习记忆）、其他方案的 `*.custom.yaml`

`package/dist-scripts/postinstall`（.app 写入之后）：

1. 日志目录 `~/Library/Logs/BangkePinyin` 建好并 `chown` 给登录用户
   —— 安装脚本以 root 跑，不改属主的话输入法进程写不进 `RIME_LOG_DIR`，
   运行时日志会静默丢失（目录里只剩 root 写的 `install.log`）
2. 从 `SharedSupport/ai-predict-defaults/` **强制覆盖** `default` / `luna_pinyin` /
   `rime_ice` 三个 custom.yaml —— 它们决定 AI 候选能否出现，必须用我们的版本
3. **仅在用户没有同名文件时**写入 `bangke.custom.yaml`（出厂外观默认值）。
   已有用户手调过的字体/主题不会被我们的默认值盖掉
4. 落地扩展词库 `dicts/` 与 `rime-ice/`
5. 从 `SharedSupport/predict_models/zh-base-ct2-int8/` 复制模型
   （目标已存在且 `model.bin` 的 sha256 一致则跳过，避免重复 IO）
6. `chown -R` 整个 `~/Library/Rime/` 给登录用户
7. 调产物二进制做注册 / `--build` 部署 / 启用 / 选中

安装日志写在 `~/Library/Logs/BangkePinyin/install.log`。

## 简繁默认：filter 链千万别整列替换（2026-06-25 踩坑）

**症状**：重装后字形开关显示「简化字」，但输出仍是繁体——选中态与实际输出矛盾。

**根因**：新版朙月拼音的字形开关 `switches/@2` 是四态
`[zh_hant, zh_hans, zh_hant_hk, zh_hant_tw]`，真正执行 t2s 转换的是 schema
原生 `engine/filters` 里**带 `@` 后缀**的命名实例：

```yaml
filters:
  - simplifier@zh_hans        # 监听 @2 开关的 zh_hans 选项，opencc t2s.json
  - simplifier@zh_hant_hk
  - simplifier@zh_hant_tw
  - uniquifier
```

旧版 `luna_pinyin.custom.yaml` 用一个**裸 `simplifier` 整列替换**了
`engine/filters`，把三个带后缀的转换器全删了。裸 `simplifier` 默认监听老开关名
`simplification`，而新 schema 已无此开关 → 转换器永不触发 → 开关亮「简化字」
却照样输出繁体。每次重装都被这份模板覆盖，所以反复出现。

**正确做法**（现行模板已采用）：

- **filter 链**：用 list-append `'engine/filters/@next': ai_predict_filter`
  **只追加**，绝不整列替换，保留 schema 原生的 `simplifier@zh_hans` 等。
- **translator 链**：`ai_predict_translator` 必须排**首位**（否则
  `MergedTranslation::Elect` 不会先问它），Rime 无「插入第 0 位」语法，只能整列
  重写——重写时必须把原生 `table_translator@custom_phrase`、
  `reverse_lookup_translator` 一并列出，别漏。
- **默认简体**：`switches/@2/reset: 1`（index 1 = 简化字），与简体训练的
  CT2 模型对齐。注意这依赖 `@2` 恰好是字形开关——**plum 若调整 switches 顺序，
  这个索引会漂**，升级 schema 后需复核。

**改完怎么验证**（不必重打整个 pkg）：

```bash
cp local/ai-predict-defaults/luna_pinyin.custom.yaml ~/Library/Rime/
"/Library/Input Methods/BangkePinyin.app/Contents/MacOS/rime_deployer" \
    --build ~/Library/Rime "/Library/Input Methods/BangkePinyin.app/Contents/SharedSupport"
# 确认 build 产物保住了 simplifier@zh_hans 且 ai_predict_filter 在末尾:
grep -A5 'filters:' ~/Library/Rime/build/luna_pinyin.schema.yaml
```

## 模型来源

`MODEL_SRC` 环境变量优先级最高；否则按下列顺序自动查找：

1. `local/cache/predict_models/zh-base-ct2-int8/`
2. `~/Library/Rime/predict_models/zh-base-ct2-int8/`

**脚本不会自动联网下载模型**——避免一次构建悄悄拉 230 MB。首次构建前请先：

```bash
( cd librime/plugins/ai-predict && ./scripts/download_model.sh )
```

若想离线复用，把那个目录复制到 `local/cache/predict_models/`，
之后即使清空了用户 Rime 也能直接打包。（`local/cache/` 不入库。）
