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
  _ = try settings.save(writeAI: false)
  var text = try String(contentsOf: path, encoding: .utf8)
  check(text.contains("style/inline_preedit: false"), "written as false", text)
  check(text.contains("# 用户自己的注释"), "comment preserved")
  check(text.contains("accent_text_color: 0xff8c5a"), "unmanaged key preserved")
  check(!BangkeSettings.load().appearance.inlinePreedit, "reads back as false")

  settings.appearance.inlinePreedit = true
  _ = try settings.save(writeAI: false)
  text = try String(contentsOf: path, encoding: .utf8)
  check(text.contains("style/inline_preedit: true"), "flips back to true", text)
  check(BangkeSettings.load().appearance.inlinePreedit, "reads back as true")
}

print("9. the AI page reads the first wired schema and writes all of them")
do {
  let schemas = BangkeSettings.aiWiredSchemas()
  check(schemas == ["luna_pinyin", "rime_ice"], "both schemas detected as AI-wired", "got \(schemas)")
  check(BangkeSettings.load().aiPredict.targetIndex == 1, "reads luna_pinyin's value")
}

print("10. saving with the AI page untouched leaves a diverged schema alone")
do {
  let rimeIce = BangkeSettings.customFile("rime_ice")
  var file = RimePatchFile(contentsOf: rimeIce)
  file.setScalar(inBlock: "ai_predict", "target_index", to: "7")
  try file.write(to: rimeIce)
  let before = try String(contentsOf: rimeIce, encoding: .utf8)

  var settings = BangkeSettings.load()
  settings.appearance.fontPoint = 19
  _ = try settings.save(writeAI: false)

  check(try String(contentsOf: rimeIce, encoding: .utf8) == before,
        "rime_ice's ai_predict survives a save that did not touch AI")
  check(RimePatchFile(contentsOf: rimeIce).scalar(inBlock: "ai_predict", "target_index") == "7",
        "its own value is still 7")
  check(BangkeSettings.divergentAISchemas() == ["rime_ice"],
        "divergence is reported", "got \(BangkeSettings.divergentAISchemas())")

  // Now an actual AI edit must fan out and unify.
  settings.aiPredict.targetIndex = 2
  _ = try settings.save(writeAI: true)
  check(RimePatchFile(contentsOf: rimeIce).scalar(inBlock: "ai_predict", "target_index") == "2",
        "an explicit AI change does unify the diverged schema")
  check(BangkeSettings.divergentAISchemas().isEmpty, "no divergence left")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
