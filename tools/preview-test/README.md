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
