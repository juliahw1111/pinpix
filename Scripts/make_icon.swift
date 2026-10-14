// 產生 App 圖示：swift Scripts/make_icon.swift <輸出資料夾>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a).cgColor
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS 圖示格線：824×824 圓角方形
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // 底板陰影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0x3B2FD6))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    // 背景：靛藍 → 紫 斜向漸層
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x5B6CFF), rgb(0x6B3CF0), rgb(0x9B2FD8)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    // 上半部柔光
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 340, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 340, y: 860), endRadius: 560, options: [])

    // 截圖卡片（微微傾斜）
    ctx.saveGState()
    ctx.translateBy(x: 500, y: 520)
    ctx.rotate(by: -0.10)
    let card = CGRect(x: -250, y: -190, width: 500, height: 380)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x1A0B5C, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // 卡片內容：視窗標題列圓點 + 幾行灰色內容
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(rgb(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: -210 + CGFloat(i) * 42, y: 120, width: 26, height: 26))
    }
    ctx.setFillColor(rgb(0xE6E8F0))
    for (y, w) in [(50.0, 330.0), (-10.0, 400.0), (-70.0, 260.0), (-130.0, 340.0)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: -210, y: y, width: w, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.fillPath()
    }
    // 標註：珊瑚色圓角框
    ctx.setStrokeColor(rgb(0xFF4D5A))
    ctx.setLineWidth(22)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -40, y: -105, width: 250, height: 120), cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // 標註箭頭（黃 → 橘），從右下指向卡片
    let s = CGPoint(x: 820, y: 210), e = CGPoint(x: 600, y: 400)
    let w: CGFloat = 50
    let len = hypot(e.x - s.x, e.y - s.y)
    let headLen: CGFloat = 150, headW: CGFloat = 180
    let pts = [CGPoint(x: 0, y: -w * 0.28), CGPoint(x: len - headLen * 0.85, y: -w / 2), CGPoint(x: len - headLen, y: -headW / 2),
               CGPoint(x: len, y: 0), CGPoint(x: len - headLen, y: headW / 2), CGPoint(x: len - headLen * 0.85, y: w / 2),
               CGPoint(x: 0, y: w * 0.28)]
    let t = CGAffineTransform(translationX: s.x, y: s.y).rotated(by: atan2(e.y - s.y, e.x - s.x))
    let arrow = CGMutablePath()
    arrow.addLines(between: pts, transform: t)
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x1A0B5C, 0.5))
    ctx.addPath(arrow)
    ctx.setFillColor(rgb(0xFFB020))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    let ag = CGGradient(colorsSpace: space, colors: [rgb(0xFFD23F), rgb(0xFF8A1F)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ag, start: e, end: s, options: [])
    ctx.restoreGState()
    // 白色細邊讓箭頭更立體
    ctx.addPath(arrow)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(8)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // 底板內緣細光
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! render(pt * scale).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: out).appendingPathComponent("Contents.json"))
print("icons written to \(out)")
