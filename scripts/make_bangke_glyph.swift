#!/usr/bin/env swift
//
// 用 CoreText 把「蚌」(U+868C) 的字形轮廓取出来，生成：
//   Bangke.icon/Assets/logo.svg  — App 图标（Icon Composer），亮/暗两套由 icon.json 决定填充色
//   resources/bangke.pdf         — 输入法菜单图标，纯黑 + alpha，macOS 按 template 自动适配亮暗
//
// 产出的是 path 而非 <text>：Xcode 构建时不需要字体，换机器/换系统也不担心
// 字体缺失导致图标变豆腐块。
//
// 用法: swift scripts/make_bangke_glyph.swift

import AppKit
import CoreText
import Foundation

let character: UnicodeScalar = "蚌"
let canvas = 1024.0
// Icon Composer 会自己加边距，字形占画布约七成，和原来 Rime logo 的比例一致
let glyphRatio = 0.72
let pdfSide = 16.0

// 优先冬青黑体简体中文 W6（Windows 版脚本的 mac 回退项，三平台观感一致），
// 再退到黑体/宋体黑。都必须真的覆盖「蚌」，否则 CTFontGetGlyphsForCharacters 会返回 false。
let fontCandidates = [
    "HiraginoSansGB-W6",
    "STHeitiSC-Medium",
    "STSongti-SC-Black",
    "PingFangSC-Semibold",
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

func loadFont() -> CTFont {
    var glyph = CGGlyph()
    var utf16 = Array(String(character).utf16)
    for name in fontCandidates {
        let font = CTFontCreateWithName(name as CFString, 100, nil)
        if CTFontGetGlyphsForCharacters(font, &utf16, &glyph, 1) {
            return font
        }
    }
    fail("找不到覆盖「蚌」的字体，试过: \(fontCandidates)")
}

let font = loadFont()
var characters = Array(String(character).utf16)
var glyph = CGGlyph()
_ = CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1)

guard let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else {
    fail("取不到「蚌」的轮廓")
}
let sourceBounds = glyphPath.boundingBoxOfPath

// CoreText 的 y 轴向上、SVG 向下，所以纵向要做一次翻转
func svgPathData(scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> String {
    func point(_ p: CGPoint) -> String {
        String(format: "%.2f %.2f", offsetX + p.x * scale, offsetY + (canvas - p.y * scale))
    }

    var parts: [String] = []
    glyphPath.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            parts.append("M\(point(points[0]))")
        case .addLineToPoint:
            parts.append("L\(point(points[0]))")
        case .addQuadCurveToPoint:
            parts.append("Q\(point(points[0])) \(point(points[1]))")
        case .addCurveToPoint:
            parts.append("C\(point(points[0])) \(point(points[1])) \(point(points[2]))")
        case .closeSubpath:
            parts.append("Z")
        @unknown default:
            break
        }
    }
    return parts.joined(separator: " ")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// ---- App 图标 SVG ----
let iconScale = canvas * glyphRatio / max(sourceBounds.width, sourceBounds.height)
let iconWidth = sourceBounds.width * iconScale
let iconHeight = sourceBounds.height * iconScale
let iconOffsetX = (canvas - iconWidth) / 2 - sourceBounds.minX * iconScale
// 字形顶边落到居中方框的顶边：offsetY 要把「canvas - maxY*scale」这一项抵掉
let iconOffsetY = (canvas - iconHeight) / 2 - canvas + sourceBounds.maxY * iconScale

let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 \(Int(canvas)) \(Int(canvas))">
  <path d="\(svgPathData(scale: iconScale, offsetX: iconOffsetX, offsetY: iconOffsetY))" fill-rule="nonzero"/>
</svg>

"""
let svgURL = root.appendingPathComponent("Bangke.icon/Assets/logo.svg")
try svg.write(to: svgURL, atomically: true, encoding: .utf8)
print("wrote \(svgURL.path)")

// ---- 菜单栏图标 PDF ----
// 纯黑填充 + alpha：macOS 对输入法菜单图标做 template 渲染，会自动反色适配亮暗
let pdfScale = pdfSide * 0.92 / max(sourceBounds.width, sourceBounds.height)
let pdfWidth = sourceBounds.width * pdfScale
let pdfHeight = sourceBounds.height * pdfScale
let pdfURL = root.appendingPathComponent("resources/bangke.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: pdfSide, height: pdfSide)

guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    fail("建不了 PDF context")
}

context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.translateBy(x: (pdfSide - pdfWidth) / 2, y: (pdfSide - pdfHeight) / 2)
context.scaleBy(x: pdfScale, y: pdfScale)
context.translateBy(x: -sourceBounds.minX, y: -sourceBounds.minY)
context.addPath(glyphPath)
context.fillPath()
context.endPDFPage()
context.closePDF()
print("wrote \(pdfURL.path)")
