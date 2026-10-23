import AppKit
import SwiftUI

// Offscreen tests for BangkePreviewCanvas, the candidate-bar preview in the
// settings window.
//
// These exist because the preview's failure mode is invisible to the compiler:
// BangkeView paints backgrounds and highlights but not glyphs — the text comes
// from a separate NSTextView that BangkePanel adds as a *sibling*. Forget that
// one addSubview and the preview still compiles, still builds, and renders an
// empty box. Only asserting on the view tree catches it.

// Unbuffered: a crash later in the run must not swallow the results so far.
setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared
initializeRimeForHarness()

// Open the production settings view against the isolated harness configuration.
if CommandLine.arguments.contains("--review") {
  let base = BangkeConfig()
  if base.openBaseConfig() { NSApp.bangkeAppDelegate.config = base }
  let model = BangkeSettingsModel()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  window.title = "蚌壳拼音 · 界面验证"
  window.contentView = NSHostingView(rootView: BangkePreferencesView(model: model, onClose: { NSApp.terminate(nil) }))
  NSApp.setActivationPolicy(.regular)
  window.center()
  window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
  withExtendedLifetime(window) { NSApp.run() }
  exit(0)
}

var failures = 0
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
  if condition { print("  ok   \(label)") }
  else { failures += 1; print("  FAIL \(label) \(detail)") }
}

/// Build a real BangkeTheme from raw YAML, bypassing the app bundle that
/// BangkePreviewTheme.load needs.
func makeTheme(_ yaml: String, dark: Bool) -> BangkeTheme {
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  var config = RimeConfig()
  precondition(rimeAPI.config_init(&config), "config_init")
  precondition(rimeAPI.config_load_string(&config, yaml), "config_load_string")
  let theme = BangkeTheme()
  theme.load(config: BangkeConfig(adopting: config), dark: dark)
  return theme
}

/// `extra` is spliced at column 0, so it must carry its own 2-space indent.
func baseYAML(_ extra: String) -> String {
  """
  style:
    color_scheme: native
    color_scheme_dark: native
    font_point: 16
    candidate_format: '[label]. [candidate] [comment]'
    corner_radius: 7
  \(extra)
  """
}

func canvas(_ yaml: String) -> BangkePreviewCanvas {
  let view = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
  view.apply(light: makeTheme(yaml, dark: false), dark: makeTheme(yaml, dark: true))
  view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
  view.layoutSubtreeIfNeeded()
  return view
}

func bangkeView(in view: BangkePreviewCanvas) -> BangkeView? {
  view.subviews.first?.subviews.compactMap { $0 as? BangkeView }.first
}

/// Deployment runs off-thread, so poll rather than assuming it finished. Without
/// this the schema-list assertions race the deploy and pass or fail by timing.
func waitForSchemas(_ expected: [String], timeout: TimeInterval = 5) -> [String] {
  let deadline = Date().addingTimeInterval(timeout)
  var seen = BangkeSettings.load().aiSchemas.map(\.id)
  while seen != expected, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    seen = BangkeSettings.load().aiSchemas.map(\.id)
  }
  return seen
}

print("1. the text view is attached and laid out")
do {
  let view = canvas(baseYAML("  text_orientation: horizontal"))
  check(bangkeView(in: view) != nil, "BangkeView is in the hierarchy")
  guard let bangkeView = bangkeView(in: view) else { exit(1) }

  check(bangkeView.textView.superview != nil, "text view has a superview",
        "superview was nil — nothing would draw")
  check(bangkeView.textView.superview === bangkeView.superview,
        "text view is a SIBLING of BangkeView, as in BangkePanel")
  check(bangkeView.textView.frame.width > 0 && bangkeView.textView.frame.height > 0,
        "text view frame is non-empty", "got \(bangkeView.textView.frame)")
  check(bangkeView.frame.width > 0 && bangkeView.frame.height > 0,
        "BangkeView frame is non-empty", "got \(bangkeView.frame)")
  check((bangkeView.textView.textContentStorage?.attributedString?.length ?? 0) > 0,
        "text view holds the sample text")

  let size = view.intrinsicContentSize
  check(size.width > 32 && size.height > 32, "intrinsic size is usable", "got \(size)")
  print("       canvas \(size.width)x\(size.height), textView \(bangkeView.textView.frame.size)")
}

print("2. content stays inside the canvas")
do {
  let view = canvas(baseYAML("  text_orientation: horizontal"))
  guard let content = view.subviews.first, let bangkeView = bangkeView(in: view) else { exit(1) }
  check(content.frame.minX >= 0 && content.frame.minY >= 0,
        "content is inset from the canvas edge", "got \(content.frame)")
  check(content.frame.maxX <= view.intrinsicContentSize.width + 0.5
          && content.frame.maxY <= view.intrinsicContentSize.height + 0.5,
        "content does not overflow the canvas")
  check(bangkeView.textView.frame.maxX <= bangkeView.frame.maxX + 0.5,
        "text view does not overflow the panel",
        "text \(bangkeView.textView.frame) panel \(bangkeView.frame)")
}

print("3. paging arrows reserve space on the left")
do {
  let plain = canvas(baseYAML("  text_orientation: horizontal"))
  let paged = canvas(baseYAML("  text_orientation: horizontal\n  show_paging: true"))
  func textOrigin(_ view: BangkePreviewCanvas) -> CGFloat {
    bangkeView(in: view)?.textView.frame.minX ?? -1
  }
  check(textOrigin(plain) == 0, "no offset when paging is off", "got \(textOrigin(plain))")
  check(textOrigin(paged) > 0, "offset applied when paging is on", "got \(textOrigin(paged))")
}

print("4. vertical swaps the axes and rotates the content")
do {
  let horizontal = canvas(baseYAML("  text_orientation: horizontal"))
  let vertical = canvas(baseYAML("  text_orientation: vertical"))
  guard let content = vertical.subviews.first, let bangkeView = bangkeView(in: vertical) else { exit(1) }
  check(content.boundsRotation == -90, "content is rotated -90", "got \(content.boundsRotation)")
  check(content.bounds.origin.y != 0, "bounds origin shifted for the rotation",
        "got \(content.bounds.origin)")
  let horizontalSize = horizontal.intrinsicContentSize
  let verticalSize = vertical.intrinsicContentSize
  check(verticalSize.height > verticalSize.width, "vertical preview is taller than wide",
        "h=\(horizontalSize) v=\(verticalSize)")
  check(bangkeView.textView.frame.width > 0 && bangkeView.textView.frame.height > 0,
        "vertical text view frame is non-empty", "got \(bangkeView.textView.frame)")
}

print("5. re-applying does not duplicate or lose subviews")
do {
  let yaml = baseYAML("  text_orientation: horizontal")
  let view = canvas(yaml)
  guard let content = view.subviews.first else { exit(1) }
  let before = content.subviews.count
  view.apply(light: makeTheme(yaml, dark: false), dark: makeTheme(yaml, dark: true))
  view.layoutSubtreeIfNeeded()
  check(content.subviews.count == before, "subview count stable",
        "\(before) -> \(content.subviews.count)")
  check(view.subviews.count == 1, "canvas still has exactly one child")
}

print("6. inline preedit control hides the preedit row")
do {
  let off = canvas(baseYAML("  text_orientation: horizontal\n  inline_preedit: false"))
  let on = canvas(baseYAML("  text_orientation: horizontal\n  inline_preedit: true"))
  let offPreedit = bangkeView(in: off)?.preeditRange.length ?? -1
  let onPreedit = bangkeView(in: on)?.preeditRange.length ?? -1
  check(offPreedit > 0, "preedit drawn in the panel when inline preedit is off", "got \(offPreedit)")
  check(onPreedit == 0, "preedit omitted when inline preedit is on", "got \(onPreedit)")
  check(off.intrinsicContentSize.height > on.intrinsicContentSize.height,
        "panel is taller with the preedit row",
        "off=\(off.intrinsicContentSize.height) on=\(on.intrinsicContentSize.height)")
}

print("7. the panel anchors to the top-left of its frame")
do {
  let view = canvas(baseYAML("  text_orientation: horizontal"))
  // Deliberately oversized, the way a stretched SwiftUI row would hand it over.
  view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
  view.layoutSubtreeIfNeeded()
  guard let content = view.subviews.first else { exit(1) }
  let panel = content.frame
  check(panel.minX < 20, "hugs the left edge", "got \(panel.minX)")
  check(panel.minY < 20, "hugs the top edge, not the bottom", "got minY=\(panel.minY)")
  check(panel.height < 200 && panel.width < 600,
        "does not stretch to fill the frame", "got \(panel.size)")
}

print("8. inline preedit survives a settings round-trip through the patch file")
do {
  let path = BangkeSettings.customFile(Brand.configName)
  try! """
  # 用户自己的注释
  patch:
    preset_color_schemes/native/accent_text_color: 0xff8c5a
  """.write(to: path, atomically: true, encoding: .utf8)

  var settings = BangkeSettings.load()
  check(settings.appearance.inlinePreedit, "absent key falls back to the shipped default")

  settings.appearance.inlinePreedit = false
  _ = try settings.save()
  var text = try String(contentsOf: path, encoding: .utf8)
  check(text.contains("style/inline_preedit: false"), "written as false", text)
  check(text.contains("# 用户自己的注释"), "comment preserved")
  check(text.contains("accent_text_color: 0xff8c5a"), "unmanaged key preserved")
  check(!BangkeSettings.load().appearance.inlinePreedit, "reads back as false")

  settings.appearance.inlinePreedit = true
  _ = try settings.save()
  text = try String(contentsOf: path, encoding: .utf8)
  check(text.contains("style/inline_preedit: true"), "flips back to true", text)
  check(BangkeSettings.load().appearance.inlinePreedit, "reads back as true")
}

print("9. every AI-wired schema gets its own settings, opened on the active one")
do {
  let listed = waitForSchemas(["luna_pinyin", "rime_ice"])
  check(listed == ["luna_pinyin", "rime_ice"], "both listed in order", "got \(listed)")
  let settings = BangkeSettings.load()
  check(settings.aiPredict.count == 2, "one entry per schema", "got \(settings.aiPredict.keys.sorted())")
  check(settings.selectedAISchema == "luna_pinyin",
        "falls back to the first when no session has reported one", "got \(settings.selectedAISchema)")

  // The controller reports the schema in use; the page must follow it.
  NSApp.bangkeAppDelegate.loadSettings(for: "rime_ice")
  check(BangkeSettings.load().selectedAISchema == "rime_ice",
        "opens on the schema being typed with", "got \(BangkeSettings.load().selectedAISchema)")
  NSApp.bangkeAppDelegate.loadSettings(for: "luna_pinyin")
}

print("10. editing one schema leaves the others alone")
do {
  let luna = BangkeSettings.customFile("luna_pinyin")
  let rimeIce = BangkeSettings.customFile("rime_ice")
  func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

  var settings = BangkeSettings.load()
  settings.appearance.fontPoint = 19
  _ = try settings.save()
  check(text(rimeIce) == text(rimeIce) && BangkeSettings.load().aiPredict["rime_ice"]?.targetIndex == 1,
        "a save that touched no AI value left the defaults in place")

  let rimeBefore = text(rimeIce)
  let lunaBefore = text(luna)

  settings = BangkeSettings.load()
  settings.selectedAISchema = "rime_ice"
  settings.aiPredict["rime_ice"]?.targetIndex = 5
  _ = try settings.save()

  check(text(rimeIce) != rimeBefore, "the edited schema was written")
  check(RimePatchFile(contentsOf: rimeIce).scalar(inBlock: "ai_predict", "target_index") == "5",
        "with the new value")
  check(text(luna) == lunaBefore, "the schema not on screen was left untouched")
  check(BangkeSettings.load().aiPredict["luna_pinyin"]?.targetIndex == 1, "luna keeps its own value")
  check(BangkeSettings.load().aiPredict["rime_ice"]?.targetIndex == 5, "rime_ice reads back its own")
}

print("11. a save that changes nothing reports that, so librime is left alone")
do {
  // Settle the files first: the previous sections wrote real changes.
  var settings = BangkeSettings.load()
  _ = try settings.save()

  settings = BangkeSettings.load()
  let untouched = try settings.save()
  check(!untouched.changed, "an unchanged save reports no change")
  check(!untouched.needsFullDeployment, "and no deployment")

  settings = BangkeSettings.load()
  settings.appearance.fontPoint += 1
  let styled = try settings.save()
  check(styled.changed, "a style edit reports a change")
  check(!styled.needsFullDeployment, "but not a schema-affecting one")

  settings = BangkeSettings.load()
  settings.behavior.pageSize += 1
  let paged = try settings.save()
  check(paged.changed && paged.needsFullDeployment,
        "a page-size edit needs a full deployment")
}

print("12. an open settings page follows a schema switch")
do {
  NSApp.bangkeAppDelegate.loadSettings(for: "luna_pinyin")
  let model = BangkeSettingsModel()
  check(model.settings.selectedAISchema == "luna_pinyin", "opens on the active schema",
        "got \(model.settings.selectedAISchema)")

  // The user hits Ctrl+` and switches to 雾凇 while the window is still open.
  NSApp.bangkeAppDelegate.loadSettings(for: "rime_ice")
  check(model.settings.selectedAISchema == "rime_ice",
        "follows the switch instead of showing a stale schema",
        "got \(model.settings.selectedAISchema)")

  // A deliberate pick in the dropdown must not be yanked away afterwards.
  model.schemaSelection.wrappedValue = "luna_pinyin"
  NSApp.bangkeAppDelegate.loadSettings(for: "rime_ice")
  check(model.settings.selectedAISchema == "luna_pinyin",
        "a manual pick sticks", "got \(model.settings.selectedAISchema)")

  NSApp.bangkeAppDelegate.loadSettings(for: "luna_pinyin")
}

print("13. saving re-checks which schemas are AI-wired")
do {
  // rime_ice exists at load time, so it is in the snapshot.
  let settings = BangkeSettings.load()
  check(settings.aiSchemas.contains { $0.id == "rime_ice" }, "rime_ice loaded")

  // Then it goes away before the save, the way a plum uninstall would. Deleting
  // the files is not enough — get_schema_list() reports the deployed state, so
  // the removal needs a redeploy to actually take effect.
  let rimeIce = BangkeSettings.customFile("rime_ice")
  let parkedCustom = try? String(contentsOf: rimeIce, encoding: .utf8)
  let schemaFile = BangkeApp.userDir.appendingPathComponent("rime_ice.schema.yaml")
  let parkedSchema = try? String(contentsOf: schemaFile, encoding: .utf8)
  try? FileManager.default.removeItem(at: rimeIce)
  try? FileManager.default.removeItem(at: schemaFile)
  redeployForHarness()
  let remaining = waitForSchemas(["luna_pinyin"])
  check(remaining == ["luna_pinyin"], "the schema really is gone from librime's list",
        "still got \(remaining)")

  var edited = settings
  edited.aiPredict["rime_ice"]?.targetIndex = 9
  _ = try edited.save()
  check(!FileManager.default.fileExists(atPath: rimeIce.path),
        "no orphan .custom.yaml resurrected for the removed schema")
  // No restoring: each run wipes and rebuilds the harness user dir from scratch.
  _ = parkedSchema
  _ = parkedCustom
}

print("14. forcedDark switches which theme the preview draws with")
do {
  let yaml = baseYAML("  text_orientation: horizontal")
  let light = makeTheme(yaml, dark: false)
  let dark = makeTheme(yaml, dark: true)
  let view = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
  view.apply(light: light, dark: dark)
  guard let bangkeView = bangkeView(in: view) else { exit(1) }

  view.forcedDark = true
  view.apply(light: light, dark: dark)
  check(bangkeView.currentTheme === dark, "forced dark picks the dark theme")

  view.forcedDark = false
  view.apply(light: light, dark: dark)
  check(bangkeView.currentTheme === light, "forced light picks the light theme")

  view.forcedDark = nil
  view.apply(light: light, dark: dark)
  let expectDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  check(bangkeView.currentTheme === (expectDark ? dark : light),
        "nil falls back to the app appearance")
}

print("15. a canvas too small for the panel scales down instead of overflowing")
do {
  let view = canvas(baseYAML("  text_orientation: vertical"))
  let full = view.intrinsicContentSize
  check(full.height > 120, "vertical panel is genuinely tall", "got \(full)")
  view.frame = NSRect(x: 0, y: 0, width: 40, height: 160)
  view.layoutSubtreeIfNeeded()
  check(abs(view.bounds.width - full.width) < 1 && abs(view.bounds.height - full.height) < 1,
        "bounds expand beyond the small frame, scaling the panel to fit",
        "bounds \(view.bounds) vs full \(full)")
}

print("16. style/alpha applies to the preview panel")
do {
  let solid = canvas(baseYAML("  text_orientation: horizontal"))
  check(abs((solid.subviews.first?.alphaValue ?? 0) - 1) < 0.01, "default is opaque")
  let faded = canvas(baseYAML("  text_orientation: horizontal\n  alpha: 0.4"))
  check(abs((faded.subviews.first?.alphaValue ?? 0) - 0.4) < 0.01,
        "alpha sinks onto the panel container",
        "got \(String(describing: faded.subviews.first?.alphaValue))")
}

print("17. flipping text orientation leaves no stale vertical state")
do {
  // 竖排的 -90° 旋转是 content 上的粘性状态; 切回横排若复用旧子树,
  // 图层变换会残留旧角度, 屏幕上呈 90° 旋转。翻转必须重建子树。
  let view = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
  let horizYAML = baseYAML("  text_orientation: horizontal")
  let vertYAML = baseYAML("  text_orientation: vertical")

  view.apply(light: makeTheme(horizYAML, dark: false), dark: makeTheme(horizYAML, dark: true))
  guard let contentAfterH1 = view.subviews.first,
        let bangkeAfterH1 = bangkeView(in: view) else { exit(1) }

  view.apply(light: makeTheme(vertYAML, dark: false), dark: makeTheme(vertYAML, dark: true))
  guard let contentAfterV = view.subviews.first else { exit(1) }
  check(contentAfterV !== contentAfterH1, "vertical flip rebuilds the subtree")
  check(contentAfterV.boundsRotation == -90, "vertical content is rotated", "got \(contentAfterV.boundsRotation)")

  view.apply(light: makeTheme(horizYAML, dark: false), dark: makeTheme(horizYAML, dark: true))
  guard let contentAfterH2 = view.subviews.first,
        let bangkeAfterH2 = bangkeView(in: view) else { exit(1) }
  check(contentAfterH2 !== contentAfterV, "flipping back rebuilds the subtree again")
  check(contentAfterH2.boundsRotation == 0, "rotation starts clean at 0", "got \(contentAfterH2.boundsRotation)")
  check(bangkeAfterH2 !== bangkeAfterH1, "BangkeView is a fresh instance")
  check(bangkeAfterH2.textView.layoutOrientation == .horizontal,
        "text view lays out horizontally")
  check(bangkeAfterH2.textView.superview === bangkeAfterH2.superview,
        "fresh text view is re-attached as BangkeView's sibling")
  check((bangkeAfterH2.textView.textContentStorage?.attributedString?.length ?? 0) > 0,
        "fresh text view holds the sample text")

  // 同形态下重复 apply 不应重建(颜色、字号等滑杆调节走这条路)。
  let contentBefore = view.subviews.first
  view.apply(light: makeTheme(horizYAML, dark: false), dark: makeTheme(horizYAML, dark: true))
  check(view.subviews.first === contentBefore, "same orientation reuses the subtree")
}

print("18. the current-theme preview stays at its original size")
do {
  // 内置方案已降级为纯配色(布局/排版键由设置页全局值决定), 但手写 yaml
  // 给方案加键仍然生效。这里注入一个带 linear+inline_preedit 的临时方案
  // 当浅色, 青天(纯色)当深色、表单设堆叠+显示编码 —— 两块固有形状不同。
  // 曾经共用浅色块的宽高比, 深色块被压成 3×4pt 的点。
  let staged = URL(fileURLWithPath: Bundle.main.sharedSupportPath!)
    .appendingPathComponent("\(Brand.configName).yaml")
  var yaml = try! String(contentsOf: staged, encoding: .utf8)
  // 注入到 app_options: 之前, 保持 preset_color_schemes 的 2/4 空格缩进。
  let injection = """
    zz_test_linear:
      name: 临时横排方案
      back_color: 0xFFFFFF
      text_color: 0x000000
      candidate_list_layout: linear
      inline_preedit: true

  app_options:
  """
  yaml = yaml.replacingOccurrences(of: "\napp_options:\n", with: "\n\(injection)\n")
  try! yaml.write(to: staged, atomically: true, encoding: .utf8)

  let model = BangkeSettingsModel()
  model.settings.appearance.candidateListLayout = "stacked"
  model.settings.appearance.inlinePreedit = false
  model.settings.appearance.colorScheme = "zz_test_linear"
  model.settings.appearance.colorSchemeDark = "azure"

  let hosting = NSHostingView(rootView: BangkePreferencesView(model: model, onClose: {}))
  hosting.frame = NSRect(x: 0, y: 0, width: 1240, height: 840)
  let window = NSWindow(contentRect: hosting.bounds, styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = hosting
  NSApp.setActivationPolicy(.regular)
  NSApp.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  // onPanelSize 走 DispatchQueue.main.async 回流, 泵到收敛。
  for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

  var canvases: [BangkePreviewCanvas] = []
  var queue: [NSView] = [hosting]
  while !queue.isEmpty {
    let v = queue.removeFirst()
    if let c = v as? BangkePreviewCanvas { canvases.append(c) }
    queue.append(contentsOf: v.subviews)
  }
  check(canvases.count == 1, "one preview follows the current system appearance", "got \(canvases.count)")

  for canvas in canvases {
    let half = canvas.forcedDark == true ? "dark" : "light"
    let intrinsic = canvas.intrinsicContentSize
    let frame = canvas.frame.size
    check(frame.width > 30 && frame.height > 15,
          "\(half) panel stays visible", "frame \(frame)")
    let ratio = intrinsic.width / intrinsic.height
    let frameRatio = frame.width / frame.height
    check(abs(ratio - frameRatio) / ratio < 0.15,
          "\(half) panel keeps its own aspect", "intrinsic \(ratio) vs frame \(frameRatio)")
    if canvas.forcedDark != true {
      check(ratio > 2, "hand-written per-scheme layout keys still override (linear wins)",
            "ratio \(ratio)")
    }
  }
  model.settings.appearance.colorScheme = "native"
  model.settings.appearance.colorSchemeDark = "native"
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
    window.appearance = NSAppearance(named: appearance)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bangke-settings-\(name).png")
      try! bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
  }
  window.orderOut(nil)
}

print("19. bundled schemes are pure color: the form owns layout")
do {
  // 冷漠曾是带布局键的方案; 降级后选它, 表单的堆叠/显示编码必须生效。
  let model = BangkeSettingsModel()
  model.settings.appearance.candidateListLayout = "stacked"
  model.settings.appearance.inlinePreedit = false
  model.settings.appearance.colorScheme = "apathy"

  let canvas = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
  canvas.apply(settings: model.settings)
  let size = canvas.intrinsicContentSize
  check(size.height > size.width, "apathy follows the form's stacked layout",
        "got \(size)")
}

print("20. linear layout keeps the highlight at full row height")
do {
  // 单行模式下编码与候选同行; 曾把编码当整行从候选区扣高, outerBox 被
  // 扣成 ≤0, expand() 把高亮顶点夹到同一水平线, 高亮塌成零高度 ——
  // 表现为单行预览不上色、高亮不对。
  var settings = BangkeSettings.load()
  settings.appearance.colorScheme = "mojave_dark"
  settings.appearance.colorSchemeDark = "mojave_dark"
  settings.appearance.candidateListLayout = "linear"
  settings.appearance.inlinePreedit = false
  guard let themes = BangkePreviewTheme.load(settings) else { exit(1) }

  let view = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
  view.apply(light: themes.light, dark: themes.dark)
  view.layoutSubtreeIfNeeded()
  guard let bv = bangkeView(in: view) else { exit(1) }
  bv.display()   // 离线强制 draw(_:), 图层才会生成

  var highlightHeights: [CGFloat] = []
  var panelFound = false
  func walk(_ layer: CALayer) {
    if let shape = layer as? CAShapeLayer, let path = shape.path, shape.fillColor != nil {
      let box = path.boundingBox
      if box.width > 0.9 * bv.bounds.width { panelFound = true }
      else if box.width > 20 && box.height > 15 { highlightHeights.append(box.height) }
    }
    for sub in layer.sublayers ?? [] { walk(sub) }
  }
  walk(bv.layer ?? CALayer())
  check(panelFound, "panel background layer spans the row", "bounds \(bv.bounds.size)")
  check(highlightHeights.contains { $0 > 15 },
        "candidate highlight has real height", "heights \(highlightHeights)")
}

/// Every shape layer in the tree, depth first.
func shapeLayers(in layer: CALayer) -> [CAShapeLayer] {
  var found = layer is CAShapeLayer ? [layer as! CAShapeLayer] : []
  for sub in layer.sublayers ?? [] { found += shapeLayers(in: sub) }
  return found
}

/// The layer the panel background is painted on: first sublayer of the view's
/// own layer, per BangkeView.draw().
func panelLayer(in view: BangkeView) -> CAShapeLayer? {
  view.layer?.sublayers?.first as? CAShapeLayer
}

func subpathCount(_ path: CGPath?) -> Int {
  guard let path else { return 0 }
  var count = 0
  path.applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
  return count
}

print("21. translucency paints the panel colour at 60%, not as authored")
do {
  // 配色方案的 back_color 几乎都是不透明的: 照原样画就把面板自己垫在毛玻璃
  // 之上, 开关看着毫无作用。开了半透明就必须留出透光的余地。
  let solid = makeTheme(baseYAML("  translucency: false"), dark: false)
  let frosted = makeTheme(baseYAML("  translucency: true"), dark: false)
  check(abs(solid.panelBackgroundColor.alphaComponent - 1) < 0.01,
        "opaque panel keeps the scheme colour as authored",
        "got \(solid.panelBackgroundColor.alphaComponent)")
  check(abs(frosted.panelBackgroundColor.alphaComponent - 0.6) < 0.01,
        "frosted panel drops the fill to 60%",
        "got \(frosted.panelBackgroundColor.alphaComponent)")
  check(abs(frosted.backgroundColor.alphaComponent - solid.backgroundColor.alphaComponent) < 0.01,
        "the theme's own background colour is untouched")
}

print("22. shadow_size attaches the shadow to a layer that has content")
do {
  // Core Animation 只给有内容的图层投影。之前影子挂在一个只有 shadowPath、
  // 没有任何路径或填充的空图层上 —— 该图层整个不参与合成, 阴影无处投起。
  let off = canvas(baseYAML("  text_orientation: horizontal\n  shadow_size: 0"))
  guard let offView = bangkeView(in: off) else { exit(1) }
  offView.display()
  check(shapeLayers(in: offView.layer ?? CALayer()).allSatisfy { $0.shadowOpacity == 0 },
        "no shadow when the slider is at zero")

  let on = canvas(baseYAML("  text_orientation: horizontal\n  shadow_size: 12"))
  guard let onView = bangkeView(in: on) else { exit(1) }
  onView.display()
  let casting = shapeLayers(in: onView.layer ?? CALayer()).filter { $0.shadowOpacity > 0 }
  check(casting.count == 1, "exactly one layer casts the highlight shadow",
        "got \(casting.count)")
  check(casting.allSatisfy { $0.path != nil },
        "the caster draws its own path — an empty layer casts nothing")
  check(casting.allSatisfy { abs($0.shadowRadius - 12) < 0.01 },
        "the radius follows the setting",
        "got \(casting.map(\.shadowRadius))")
}

print("23. mutual_exclusive punches the highlight out of the panel fill")
do {
  // 「色不叠加」= 面板底色在高亮处挖空, 高亮色直接压在背板之上。底色近乎
  // 不透明时挖不挖洞看不出差别, 所以这条只有在底色真的半透明时才有意义 ——
  // 与第 21 条是一组。
  func panelSubpaths(_ extra: String) -> Int {
    let view = canvas(baseYAML("  text_orientation: horizontal\n" + extra))
    guard let bv = bangkeView(in: view) else { exit(1) }
    bv.display()
    return subpathCount(panelLayer(in: bv)?.path)
  }
  let stacked = panelSubpaths("  mutual_exclusive: false")
  let exclusive = panelSubpaths("  mutual_exclusive: true")
  check(stacked == 1, "plain panel fill is one shape", "got \(stacked)")
  check(exclusive == 2, "the highlight is cut out of it", "got \(exclusive)")
}

print("24. the transparency slider inverts, the config key does not")
do {
  var settings = BangkeSettings()
  settings.appearance.transparency = 0.25
  check(abs(settings.appearance.alpha - 0.75) < 1e-9,
        "the form reads 0.25 transparent", "got \(settings.appearance.alpha)")
  let written = settings.appearanceEntries().first { $0.0 == "style/alpha" }?.1.yaml
  check(written == "0.75", "style/alpha still stores opacity", "wrote \(written ?? "nil")")

  var loaded = BangkeSettings.Appearance()
  loaded.alpha = 0.1
  check(abs(loaded.transparency - 0.9) < 1e-9,
        "a hand-written alpha shows up as its complement",
        "got \(loaded.transparency)")
}

print("25. system-following candidates use Mist / Paper without a separate dark scheme")
do {
  var settings = BangkeSettings()
  settings.appearance.colorScheme = "native"
  settings.appearance.colorSchemeDark = ""
  let themes = BangkePreviewTheme.load(settings)!
  check(themes.dark.available, "missing dark override still follows the system")
  let light = themes.light.backgroundColor.usingColorSpace(.sRGB)!
  let dark = themes.dark.backgroundColor.usingColorSpace(.sRGB)!
  check(Int((light.redComponent * 255).rounded()) == 0xF6 &&
        Int((light.greenComponent * 255).rounded()) == 0xF3 &&
        Int((light.blueComponent * 255).rounded()) == 0xED,
        "light candidates use the Paper field colour")
  check(Int((dark.redComponent * 255).rounded()) == 0x17 &&
        Int((dark.greenComponent * 255).rounded()) == 0x1C &&
        Int((dark.blueComponent * 255).rounded()) == 0x23,
        "dark candidates use the Mist field colour")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
