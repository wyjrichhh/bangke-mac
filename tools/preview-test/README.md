# preview-test

离屏跑候选栏预览（设置窗口顶部那条），断言它的视图树和几何。

```bash
bash tools/preview-test/run.sh
```

## 为什么需要它

预览的失败方式编译器看不见。

`BangkeView.draw()` 只画背景、高亮、圆角、边框——**汉字不是它画的**。真正的文字来自一个
独立的 `NSTextView`，而 `BangkeView` 并不持有它：`BangkePanel.swift` 把它作为
`BangkeView` 的**兄弟视图**加进 contentView，并单独设置它的 frame（还要减去
`pagingOffset` 给翻页箭头让位）。

2026-09-17 的 bug 就是这么来的：预览只 `addSubview(bangkeView)`，漏了 textView。
结果编译通过、构建通过、SwiftLint 干净，跑起来却是一个**只有色块、一个字都没有**的框。
`textView.frame` 甚至是非空的（代码确实设了），只是它没有父视图，永远不会被绘制。

所以这里断言的是 `superview` 这类结构事实，不是"编译过了就算数"。

## 测什么

1. textView 挂在视图树上、和 `BangkeView` 平级、frame 非空、装着文本
2. 内容不溢出画布
3. 开翻页时左侧让出 `pagingOffset`
4. 竖排交换长短轴并把内容旋转 -90°
5. 反复 apply 不会重复添加或丢失子视图
6. `inline_preedit` 开关真的改变预览：关时候选框里画出拼音行，开时不画
   （控制器是 `showPanel(preedit: inlinePreedit ? "" : preedit, ...)`，预览必须一致）
7. 画布被撑大时面板贴左上角，不是缩在左下角留一片空白
8. `inline_preedit` 经过 `bangke.custom.yaml` 存取往返不丢，且注释与
   非本界面管理的键（`accent_text_color`）原样保留
9. 每个接好 AI 的方案各有一份设置；AI 页默认打开**正在使用**的那个方案
10. 改 A 方案的 AI 只写 A 的文件，B 方案原样不动；没改 AI 的保存不写任何方案文件

11. 窗口开着时用 Ctrl+` 切方案，设置页跟着切；但用户自己在下拉里选过之后，
    就不再跟着走（那是 deliberate 的选择）
12. 保存时重新枚举 AI-wired 方案，方案被移除后不会凭空重建一个孤儿
    `.custom.yaml`

第 9–12 条针对的是「AI 设置到底属于谁」以及「方案会动态增删」这两件事。
`ai_predict` 由插件从 schema 配置读取，天然是 per-schema 的。早先的实现是
「读第一个方案 → 写全部方案」，于是两个方案一旦不一致，打开设置页什么都不动
直接保存就会把其中一个抹掉。

第 12 条要注意：删掉 `.schema.yaml` 文件是不够的，`get_schema_list()` 报的是
**部署后**的状态，所以测试里得跑一次 `redeployForHarness()` 才算真的移除。

## 脚手架会真的部署一份 Rime

`Scaffold.swift` 用最小 schema 在临时目录里搭一套 `luna_pinyin` + `rime_ice` 并跑
`start_maintenance`，否则 `get_schema_list()` 返回空，第 9、10 条会**假通过**
（没有方案就谈不上分歧，也谈不上被抹平）。基线 `default.yaml` 必须写在
shared 目录里 —— 只写 `default.custom.yaml` 的话没有东西可 patch，部署不出
schema_list。

第 6、7、8 条是 2026-09-17 修的两个 bug 的回归：

- 预览无条件画拼音行，于是 `inline_preedit` 开关看起来毫无作用
- 预览用 `maxWidth: .infinity` + 非翻转坐标，面板缩在整条区域的左下角

## 注意（续）

- 第 8 条要 `BangkeSettings.load()`，它会经 `aiWiredSchemas()` 走到 librime 的
  schema API；那个 API 在 `setup()` + `initialize()` 之前解引用会段错误。
  真机上打开设置窗口时 librime 早已初始化，所以 `Scaffold.swift` 里补了
  `initializeRimeForHarness()`，用独立的临时目录，不碰设置沙箱。
- 输出是无缓冲的（`setvbuf`），后面崩了也不会把前面的结果一起吞掉。

## 直接链生产代码

不复制任何逻辑——编译的是 `sources/` 下的真文件，链的是 `lib/librime.1.dylib`，
主题也走真实的 `BangkeTheme.load()`（用一段 YAML 喂给 librime，绕开需要 app bundle 的
`Bundle.main.sharedSupportPath`）。

`Scaffold.swift` 里是 `BangkeApp` / `BangkeApplicationDelegate` 的替身：`Main.swift`
带 `@main` 没法进测试二进制，真 delegate 又会拉进 Sparkle 和整个 IMK 栈。预览只用到
`NSApp.bangkeAppDelegate.config` 和 `BangkeApp.userDir` 两个成员，替身就够。

## 注意

- 需要先 `make deps`，否则没有 `lib/librime.1.dylib`（脚本会提示并以 2 退出）
- 开头那行 `WARNING: Logging before InitGoogleLogging()` 是 librime 的 glog 噪音，正常
- 新增依赖的源文件时，`run.sh` 里的 `SOURCES` 列表要补；漏了会以
  `cannot find X in scope` 明确报错，不会静默漏测
