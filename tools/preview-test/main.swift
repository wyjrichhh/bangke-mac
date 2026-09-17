import AppKit

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
  var seen = BangkeSettings.load().aiSchemas
  while seen != expected, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    seen = BangkeSettings.load().aiSchemas
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
  check(settings.aiSchemas.contains("rime_ice"), "rime_ice loaded")

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

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
