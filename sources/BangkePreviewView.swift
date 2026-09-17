//
//  BangkePreviewView.swift
//  Bangke
//

import AppKit
import SwiftUI

/// Sample content for the settings preview. Kept in one place so the preview
/// shows something stable while the user drags sliders.
private let sampleCandidates = ["蚌壳", "半个", "帮客", "棒喝"]
private let sampleComments = ["bang ke", "ban ge", "bang ke", "bang he"]
private let samplePreedit = "bangke"

/// Resolves a `BangkeTheme` from draft settings without going through librime's
/// deployed config.
///
/// The theme is built by loading the bundled base config and applying the draft
/// patch on top, so the preview runs the same `BangkeTheme` code the candidate
/// panel does. Reimplementing colours and fonts here would let the two drift.
enum BangkePreviewTheme {
  static func load(_ settings: BangkeSettings) -> (light: BangkeTheme, dark: BangkeTheme)? {
    guard let config = makeConfig(settings) else { return nil }
    let light = BangkeTheme()
    light.load(config: config, dark: false)
    let dark = BangkeTheme()
    dark.load(config: config, dark: true)
    return (light, dark)
  }

  private static func makeConfig(_ settings: BangkeSettings) -> BangkeConfig? {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
    guard let sharedSupport = Bundle.main.sharedSupportPath else { return nil }
    let base = URL(fileURLWithPath: sharedSupport).appendingPathComponent("\(Brand.configName).yaml")
    guard let yaml = try? String(contentsOf: base, encoding: .utf8) else { return nil }

    var config = RimeConfig()
    guard rimeAPI.config_init(&config), rimeAPI.config_load_string(&config, yaml) else { return nil }
    for (key, value) in settings.appearanceEntries() {
      switch value {
      case .bool(let raw): _ = rimeAPI.config_set_bool(&config, key, raw)
      case .int(let raw): _ = rimeAPI.config_set_int(&config, key, Int32(raw))
      case .double(let raw): _ = rimeAPI.config_set_double(&config, key, raw)
      case .string(let raw): _ = rimeAPI.config_set_string(&config, key, raw)
      }
    }
    return BangkeConfig(adopting: config)
  }
}

/// Renders the candidate bar the way `BangkePanel` does.
///
/// The structure mirrors `BangkePanel.show()` deliberately: `content` stands in
/// for the panel's content view, and `BangkeView`'s text view is added as its
/// *sibling* rather than its child, because `BangkeView` only paints
/// backgrounds, highlights, borders and shadows — the glyphs come from the
/// separate `NSTextView` layered on top.
final class BangkePreviewCanvas: NSView {
  /// Breathing room so a shadow or rounded corner is not clipped at the edges.
  private static let margin: CGFloat = 16
  /// Comfortably wider than the window, so sample candidates stay on one line.
  private static let measureWidth: CGFloat = 800

  private let content = NSView(frame: .zero)
  private let bangkeView = BangkeView(frame: .zero)
  private var theme: BangkeTheme?

  /// Origin at the top left, so the panel anchors to the corner of whatever
  /// frame SwiftUI hands us instead of floating in the bottom-left with dead
  /// space above it.
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(content)
    content.addSubview(bangkeView)
    content.addSubview(bangkeView.textView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(settings: BangkeSettings) {
    guard let themes = BangkePreviewTheme.load(settings) else { return }
    apply(light: themes.light, dark: themes.dark)
  }

  func apply(light: BangkeTheme, dark: BangkeTheme) {
    bangkeView.lightTheme = light
    bangkeView.darkTheme = dark

    let theme = bangkeView.currentTheme
    self.theme = theme
    bangkeView.textView.textContainerInset = theme.edgeInset
    bangkeView.textView.textContentStorage?.attributedString = attributedText(theme: theme)

    bangkeView.textView.setLayoutOrientation(theme.vertical ? .vertical : .horizontal)
    bangkeView.textContainer.widthTracksTextView = false
    bangkeView.textContainer.heightTracksTextView = false
    bangkeView.textContainer.size = NSSize(width: Self.measureWidth, height: CGFloat.greatestFiniteMagnitude)
    bangkeView.textLayoutManager.ensureLayout(for: bangkeView.textLayoutManager.documentRange)

    bangkeView.drawView(candidateRanges: lineRanges, hilightedIndex: 0,
                        preeditRange: preeditRange, highlightedPreeditRange: .empty,
                        canPageUp: false, canPageDown: true)

    needsLayout = true
    layoutSubtreeIfNeeded()
    invalidateIntrinsicContentSize()
  }

  private var lineRanges: [NSRange] = []
  private var preeditRange: NSRange = .empty

  private func attributedText(theme: BangkeTheme) -> NSAttributedString {
    let text = NSMutableAttributedString()
    let vertical = theme.vertical
    let linear = theme.linear
    let rows = vertical ? sampleCandidates.count : (linear ? 1 : 2)
    let perRow = max(1, Int(ceil(Double(sampleCandidates.count) / Double(rows))))

    // Inline preedit keeps the pinyin in the client's marked text, and
    // BangkeInputController duly passes the panel an empty preedit
    // (showPanel(preedit: inlinePreedit ? "" : preedit, ...)). Mirror that,
    // otherwise this toggle changes nothing on screen.
    let showsPreedit = !theme.inlinePreedit
    preeditRange = .empty
    if showsPreedit {
      preeditRange = NSRange(location: 0, length: samplePreedit.utf16.count)
      text.append(NSAttributedString(string: samplePreedit, attributes: theme.preeditAttrs))
      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle,
                        range: NSRange(location: 0, length: text.length))
    }

    lineRanges = []
    for (index, candidate) in sampleCandidates.enumerated() {
      let highlighted = index == 0
      let attrs = highlighted ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = highlighted ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = highlighted ? theme.commentHighlightedAttrs : theme.commentAttrs

      // A new row starts after the preedit, then every `perRow` candidates.
      // With no preedit the first candidate must not be preceded by a break.
      let startsRow = index == 0 || (!linear && index % perRow == 0)
      let separator = (index == 0 && text.length == 0) ? "" : (startsRow ? "\n" : "  ")
      text.append(NSAttributedString(string: separator, attributes: attrs))

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        line.addAttributes(attrs, range: NSRange(range, in: line.string))
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: NSRange(range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: "\(index + 1)",
                                            range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate,
                                            range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: sampleComments[index],
                                            range: NSRange(location: 0, length: line.length))
      line.addAttribute(.paragraphStyle, value: theme.paragraphStyle,
                        range: NSRange(location: 0, length: line.length))

      lineRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }
    return text
  }

  override func layout() {
    super.layout()
    guard let theme = theme else { return }
    let panel = panelSize(theme: theme)
    content.frame = NSRect(x: Self.margin, y: Self.margin, width: panel.width, height: panel.height)
    content.bounds = NSRect(origin: .zero, size: panel)

    // Vertical panels are drawn rotated, matching BangkePanel.show().
    if theme.vertical {
      content.boundsRotation = -90
      content.setBoundsOrigin(NSPoint(x: 0, y: panel.width))
    } else {
      content.boundsRotation = 0
      content.setBoundsOrigin(.zero)
    }

    bangkeView.textView.boundsRotation = 0
    bangkeView.textView.setBoundsOrigin(.zero)

    let subviewFrame = content.bounds
    bangkeView.frame = subviewFrame

    var textFrame = subviewFrame
    textFrame.size.width -= theme.pagingOffset
    textFrame.origin.x += theme.pagingOffset
    bangkeView.textView.frame = textFrame
  }

  /// Natural panel size, mirroring the `naturalPanelSize` computation in
  /// `BangkePanel.show()`. Vertical swaps the axes because the content rotates.
  private func panelSize(theme: BangkeTheme) -> NSSize {
    let contentRect = bangkeView.contentRect
    if theme.vertical {
      return NSSize(width: contentRect.height + theme.edgeInset.height * 2,
                    height: contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset)
    }
    return NSSize(width: contentRect.width + theme.edgeInset.width * 2 + theme.pagingOffset,
                  height: contentRect.height + theme.edgeInset.height * 2)
  }

  override var intrinsicContentSize: NSSize {
    guard let theme = theme else {
      return NSSize(width: NSView.noIntrinsicMetric, height: 96)
    }
    let panel = panelSize(theme: theme)
    return NSSize(width: panel.width + Self.margin * 2, height: panel.height + Self.margin * 2)
  }
}

struct BangkePreviewRepresentable: NSViewRepresentable {
  let settings: BangkeSettings

  func makeNSView(context: Context) -> BangkePreviewCanvas {
    let view = BangkePreviewCanvas(frame: .zero)
    view.apply(settings: settings)
    return view
  }

  func updateNSView(_ nsView: BangkePreviewCanvas, context: Context) {
    nsView.apply(settings: settings)
  }

  /// Without this SwiftUI stretches the canvas to fill the row, and the panel
  /// ends up as a small box in a mostly empty strip.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: BangkePreviewCanvas, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
}
