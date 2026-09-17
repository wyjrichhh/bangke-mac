import AppKit

// Offscreen tests for BangkePreviewCanvas, the candidate-bar preview in the
// settings window.
//
// These exist because the preview's failure mode is invisible to the compiler:
// BangkeView paints backgrounds and highlights but not glyphs — the text comes
// from a separate NSTextView that BangkePanel adds as a *sibling*. Forget that
// one addSubview and the preview still compiles, still builds, and renders an
// empty box. Only asserting on the view tree catches it.

_ = NSApplication.shared

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

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
