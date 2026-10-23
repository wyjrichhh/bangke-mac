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

  private var content = NSView(frame: .zero)
  private var bangkeView = BangkeView(frame: .zero)
  private var theme: BangkeTheme?
  /// 横竖翻转时子树整体重建: 竖排的 -90° 旋转是 content 上的粘性状态,
  /// 复用旧子树切回横排时, 图层变换与位图会残留上一形态, 屏幕上呈
  /// 90° 旋转 —— 换一套新视图从零构建最干净。
  private var isVerticalLayout = false

  /// Origin at the top left, so the panel anchors to the corner of whatever
  /// frame SwiftUI hands us instead of floating in the bottom-left with dead
  /// space above it.
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    installSubtree()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func installSubtree() {
    content.removeFromSuperview()
    content = NSView(frame: .zero)
    bangkeView = BangkeView(frame: .zero)
    addSubview(content)
    content.addSubview(bangkeView)
    content.addSubview(bangkeView.textView)
  }

  /// When set, the preview renders this appearance instead of the app's own —
  /// the settings page shows a forced-light and a forced-dark panel side by side.
  var forcedDark: Bool?
  var longSample = false

  /// How many sample candidates to draw. Follows the real `menu/page_size` so
  /// the stacked preview shows as many rows as the actual panel would.
  /// Harness callers that go through `apply(light:dark:)` keep the default.
  private var sampleCount = 5

  func apply(settings: BangkeSettings) {
    sampleCount = max(1, settings.behavior.pageSize)
    guard let themes = BangkePreviewTheme.load(settings) else { return }
    apply(light: themes.light, dark: themes.dark)
  }

  func apply(light: BangkeTheme, dark: BangkeTheme) {
    // text_orientation 全局唯一, 亮暗两套主题的 vertical 恒同值, 取一套判断即可。
    if light.vertical != isVerticalLayout {
      installSubtree()
      isVerticalLayout = light.vertical
    }
    bangkeView.isDarkOverride = forcedDark
    bangkeView.lightTheme = light
    bangkeView.darkTheme = dark

    let theme = bangkeView.currentTheme
    self.theme = theme
    // 真实面板把 style/alpha 应用在窗口上(BangkePanel.show: alphaValue);
    // 预览没有窗口, 等价地下沉到面板容器, 背板颜色得以透出来。
    content.alphaValue = theme.alpha
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
    // 样例数跟随每页候选数(循环取词), 堆叠时行数才和真实面板一致;
    // 竖排面板是单列从上往下、天然很高, 只取前两个控制高度。
    let count = vertical ? min(2, sampleCount) : sampleCount
    let pool = longSample ? ["让每一次输入都恰到好处", "今天的表达更自然一些", "把想法写下来"] : sampleCandidates
    let candidates = (0..<count).map { pool[$0 % pool.count] }
    let comments = (0..<count).map { sampleComments[$0 % sampleComments.count] }

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
    for (index, candidate) in candidates.enumerated() {
      let highlighted = index == 0
      let attrs = highlighted ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = highlighted ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = highlighted ? theme.commentHighlightedAttrs : theme.commentAttrs

      // Same separator policy as BangkePanel: stacked (and vertical) put every
      // candidate on its own line; linear joins them with spaces.
      let separator = (index == 0 && text.length == 0) ? "" : (linear ? "  " : "\n")
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
      line.mutableString.replaceOccurrences(of: "[comment]", with: comments[index],
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

    // 横排面板可以很宽、竖排面板可以很高(单列从上往下, 500pt 上下)。当
    // SwiftUI 给的 frame 装不下完整面板时, 把 bounds 放大到超过 frame,
    // 借 bounds/frame 错位把整体等比缩小 —— 完整可见优先于原始尺寸。
    let full = CGSize(width: panel.width + Self.margin * 2, height: panel.height + Self.margin * 2)
    if abs(bounds.width - full.width) > 0.5 || abs(bounds.height - full.height) > 0.5 {
      bounds = NSRect(origin: .zero, size: full)
    }

    // 旋转参与 frame/bounds 的坐标映射。竖排切回横排时若带着 -90° 的旧
    // 角度直接赋新 frame/bounds, 视图属性虽然收敛, 图层变换却停在旧角度,
    // 屏幕上呈 90° 旋转 —— 先把旋转归零再赋几何。
    if content.boundsRotation != 0 {
      content.boundsRotation = 0
      content.setBoundsOrigin(.zero)
    }
    content.frame = NSRect(x: Self.margin, y: Self.margin, width: panel.width, height: panel.height)
    content.bounds = NSRect(origin: .zero, size: panel)

    // Vertical panels are drawn rotated, matching BangkePanel.show().
    if theme.vertical {
      content.boundsRotation = -90
      content.setBoundsOrigin(NSPoint(x: 0, y: panel.width))
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
  var dark: Bool?
  var longSample = false
  /// Reports the freshly measured panel size after each apply. The hosting
  /// view does not reliably re-query `sizeThatFits` when an NSViewRepresentable
  /// invalidates its intrinsic content mid-update, so the measured size has to
  /// travel back through SwiftUI state to drive the next layout pass.
  var onPanelSize: ((CGSize) -> Void)?

  func makeNSView(context: Context) -> BangkePreviewCanvas {
    let view = BangkePreviewCanvas(frame: .zero)
    view.forcedDark = dark
    view.longSample = longSample
    view.apply(settings: settings)
    reportSize(of: view)
    return view
  }

  func updateNSView(_ nsView: BangkePreviewCanvas, context: Context) {
    nsView.forcedDark = dark
    nsView.longSample = longSample
    nsView.apply(settings: settings)
    reportSize(of: nsView)
  }

  private func reportSize(of view: BangkePreviewCanvas) {
    let size = view.intrinsicContentSize
    // Async: this runs inside a view update; setting state synchronously is
    // not allowed. A same-value report is a no-op, so the loop converges.
    DispatchQueue.main.async { onPanelSize?(size) }
  }

  /// Without this SwiftUI stretches the canvas to fill the row, and the panel
  /// ends up as a small box in a mostly empty strip. Proposals smaller than
  /// the panel (a tall vertical panel under a capped strip height) are answered
  /// with an aspect-fitting size instead — the canvas then scales to match.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: BangkePreviewCanvas, context: Context) -> CGSize? {
    let size = nsView.intrinsicContentSize
    guard size.width > 0, size.height > 0 else { return size }
    let width = proposal.width ?? size.width
    let height = proposal.height ?? size.height
    guard width > 0, height > 0 else { return size }
    let scale = min(1, width / size.width, height / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
  }
}
