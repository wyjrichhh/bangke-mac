import AppKit

// 离线 dump: 用给定 style 配置跑真实预览画布, 把各个 CAShapeLayer 的路径
// 打成文本。用来给 Windows 侧 QML 预览对账 —— 高亮块的位置/尺寸/圆角
// 在像素级上唯一确定, 不必靠肉眼看截图。
//
// 用法: bash tools/preview-test/run-dump.sh <linear|stacked|vertical> <yaml 覆盖行, 逗号分隔>
//   例: run-dump.sh linear "inline_preedit: true,hilited_corner_radius: 7"

let argv = CommandLine.arguments
let layout = argv.count > 1 ? argv[1] : "linear"
let overrides = argv.count > 2
  ? argv[2].split(separator: ",").map { "  " + $0.trimmingCharacters(in: .whitespaces) + "\n" }.joined()
  : ""

func styleYAML(layout: String) -> String {
  """
  config_version: "1.0"
  style:
    color_scheme: aqua
    candidate_list_layout: \(layout)
    text_orientation: horizontal
    inline_preedit: false
    corner_radius: 7
    hilited_corner_radius: 0
    border_height: -2
    border_width: -2
    line_spacing: 5
    spacing: 8
    font_face: 'Helvetica'
    font_point: 16
  \(overrides)
  preset_color_schemes:
    aqua:
      name: aqua
      text_color: 0x606060
      back_color: 0xeeeceeee
      candidate_text_color: 0x000000
      hilited_text_color: 0x000000
      hilited_candidate_text_color: 0xffffff
      hilited_candidate_back_color: 0xeefa3a0a
      comment_text_color: 0x5a5a5a
      hilited_comment_text_color: 0xfcac9d
  """
}

func loadTheme(_ yaml: String) -> BangkeTheme? {
  let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  var config = RimeConfig()
  guard rimeAPI.config_init(&config) else {
    print("config_init failed")
    return nil
  }
  guard rimeAPI.config_load_string(&config, yaml) else {
    print("config_load_string failed")
    return nil
  }
  let theme = BangkeTheme()
  theme.load(config: BangkeConfig(adopting: config), dark: false)
  return theme
}

func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }

func describe(_ path: CGPath?) -> String {
  guard let path else { return "  (nil)" }
  var out = "  bounds=\(rectString(path.boundingBoxOfPath))\n"
  var i = 0
  path.applyWithBlock { element in
    let e = element.pointee
    switch e.type {
    case .moveToPoint:
      out += "    [\(i)] move (\(f(e.points[0].x)), \(f(e.points[0].y)))\n"
    case .addLineToPoint:
      out += "    [\(i)] line (\(f(e.points[0].x)), \(f(e.points[0].y)))\n"
    case .addQuadCurveToPoint:
      out += "    [\(i)] quad c(\(f(e.points[0].x)), \(f(e.points[0].y))) -> (\(f(e.points[1].x)), \(f(e.points[1].y)))\n"
    case .addCurveToPoint:
      out += "    [\(i)] curve c1(\(f(e.points[0].x)), \(f(e.points[0].y))) c2(\(f(e.points[1].x)), \(f(e.points[1].y))) -> (\(f(e.points[2].x)), \(f(e.points[2].y)))\n"
    case .closeSubpath:
      out += "    [\(i)] close\n"
    @unknown default:
      out += "    [\(i)] unknown\n"
    }
    i += 1
  }
  return out
}

func rectString(_ r: CGRect) -> String {
  "(x=\(f(r.minX)) y=\(f(r.minY)) w=\(f(r.width)) h=\(f(r.height)))"
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let theme = loadTheme(styleYAML(layout: layout)) else {
  exit(1)
}

print("== theme (\(layout)) ==")
print("linear=\(theme.linear) vertical=\(theme.vertical) inlinePreedit=\(theme.inlinePreedit)")
print("cornerRadius=\(f(theme.cornerRadius)) hilitedCornerRadius=\(f(theme.hilitedCornerRadius)) borderLineWidth=\(f(theme.borderLineWidth))")
print("edgeInset=\(f(theme.edgeInset.width))x\(f(theme.edgeInset.height)) linespace=\(f(theme.linespace)) preeditLinespace=\(f(theme.preeditLinespace))")
print("pagingOffset=\(f(theme.pagingOffset)) alpha=\(f(theme.alpha))")

let canvas = BangkePreviewCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
canvas.apply(light: theme, dark: theme)

guard let content = canvas.subviews.first,
      let bangkeView = content.subviews.first(where: { $0 is BangkeView }) as? BangkeView else {
  print("view tree unexpected: \(canvas.subviews)")
  exit(1)
}

print("== canvas ==")
print("intrinsic=\(rectString(CGRect(origin: .zero, size: canvas.intrinsicContentSize)))")
print("canvas.bounds=\(rectString(canvas.bounds)) content.frame=\(rectString(content.frame))")
print("bangkeView.frame=\(rectString(bangkeView.frame))")
print("textContainer.size=\(rectString(CGRect(origin: .zero, size: bangkeView.textContainer.size)))")
print("contentRect=\(rectString(bangkeView.contentRect))")
print("separatorWidth=\(f(bangkeView.separatorWidth))")
print("text=\(String(describing: bangkeView.textView.string))")
print("candidateRanges=\(bangkeView.candidateRanges) preeditRange=\(bangkeView.preeditRange)")

// draw() 把背景/高亮/边框各挂成一个 sublayer
bangkeView.display()
let sublayers = bangkeView.layer?.sublayers ?? []
/// 递归打印一层图层: 填充/描边/阴影/遮罩都摊平, 遮罩连路径一起打出来 ——
/// 阴影"看不见"往往是遮罩把它挖空了, 光看有没有 shadowPath 判断不出来.
func describeLayer(_ layer: CALayer, depth: Int) {
  let pad = String(repeating: "  ", count: depth)
  let kind = layer is CAShapeLayer ? "CAShapeLayer" : "\(type(of: layer))"
  var line = "\(pad)\(kind)"
  if let shape = layer as? CAShapeLayer {
    let fill = shape.fillColor.flatMap { NSColor(cgColor: $0) }.map { "\($0)" } ?? "nil"
    line += " fill=\(fill) lineWidth=\(f(shape.lineWidth))"
  }
  line += " opacity=\(f(CGFloat(layer.opacity))) masksToBounds=\(layer.masksToBounds)"
  print(line)
  if let shape = layer as? CAShapeLayer, shape.path != nil {
    print("\(pad)  path \(describe(shape.path).trimmingCharacters(in: .whitespaces))")
  }
  if layer.shadowOpacity > 0 || layer.shadowPath != nil {
    print("\(pad)  shadow opacity=\(f(CGFloat(layer.shadowOpacity))) radius=\(f(layer.shadowRadius)) "
          + "offset=(\(f(layer.shadowOffset.width)), \(f(layer.shadowOffset.height))) "
          + "color=\(layer.shadowColor.flatMap { NSColor(cgColor: $0) }.map { "\($0)" } ?? "nil")")
    print("\(pad)  shadowPath \(describe(layer.shadowPath).trimmingCharacters(in: .whitespaces))")
  }
  if let mask = layer.mask {
    print("\(pad)  mask:")
    describeLayer(mask, depth: depth + 2)
  }
  for sub in layer.sublayers ?? [] {
    describeLayer(sub, depth: depth + 1)
  }
}

print("== layer tree (\(sublayers.count)) ==")
for (index, layer) in sublayers.enumerated() {
  print("[\(index)]")
  describeLayer(layer, depth: 1)
}
print("== shape.path ==")
print(describe(bangkeView.shape.path))

// 像素探针: 把图层树离屏渲染成一张字符画。阴影、半透明这类"合成之后才看得见"
// 的效果, 图层树只能证明结构、证明不了观感 —— 而它们的失败方式恰恰是结构看着
// 对、屏幕上什么都没有。背板涂成洋红: 面板若真的半透明, 洋红会从底色里透出来。
if ProcessInfo.processInfo.environment["DUMP_PIXELS"] == "1" {
  let scale: CGFloat = 2
  let width = Int(bangkeView.bounds.width * scale)
  let height = Int(bangkeView.bounds.height * scale)
  let ramp = Array(" .:-=+*#%@")
  guard width > 0, height > 0,
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("pixel probe: no context")
    exit(1)
  }
  context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.scaleBy(x: scale, y: scale)
  bangkeView.layer?.render(in: context)
  guard let data = context.data else {
    print("pixel probe: no backing store")
    exit(1)
  }
  let pixels = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
  print("== pixels (\(width)x\(height), magenta backdrop) ==")
  for y in stride(from: height - 2, through: 0, by: -2) {
    var line = ""
    for x in stride(from: 0, to: width, by: 2) {
      let offset = y * context.bytesPerRow + x * 4
      let luminance = (Int(pixels[offset]) * 30 + Int(pixels[offset + 1]) * 59
                       + Int(pixels[offset + 2]) * 11) / 100
      line.append(ramp[min(9, luminance * 10 / 256)])
    }
    print(line)
  }
  // 背板是纯洋红(1,0,1), 面板底色的 alpha 可以直接从透出来的量反推: 绿通道
  // 只可能来自面板本身, 值 = 面板绿 × alpha。
  let probe = 8 * context.bytesPerRow + (width / 2) * 4
  print("panel rgba at mid-column: r=\(pixels[probe]) g=\(pixels[probe + 1]) "
        + "b=\(pixels[probe + 2]) a=\(pixels[probe + 3])")

  // 字符画的灰度档太粗, 阴影这种渐变在它上面只剩一两级台阶。补一条中轴扫描线。
  let scanX = width / 2
  var scan = "scan x=\(scanX): "
  for y in stride(from: height - 2, through: 0, by: -2) {
    let offset = y * context.bytesPerRow + scanX * 4
    let luminance = (Int(pixels[offset]) * 30 + Int(pixels[offset + 1]) * 59
                     + Int(pixels[offset + 2]) * 11) / 100
    scan += "\(luminance) "
  }
  print(scan)
}
