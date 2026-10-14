import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, shape, text, pen, mosaic, crop

    var title: String {
        switch self {
        case .select: return "選取 (V)"
        case .arrow: return "箭頭 (A)"
        case .shape: return "圖形 (R)"
        case .text: return "文字 (T)"
        case .pen: return "畫筆 (P)"
        case .mosaic: return "馬賽克 (M)"
        case .crop: return "裁切 (C)"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .shape: return "square.on.circle"
        case .text: return "textformat"
        case .pen: return "pencil.tip"
        case .mosaic: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    /// 尺寸滑桿的範圍與預設值
    var sizeRange: (min: Double, max: Double, initial: Double) {
        switch self {
        case .arrow: return (2, 30, 8)
        case .shape: return (2, 20, 5)
        case .text: return (12, 96, 28)
        case .pen: return (1, 20, 4)
        case .mosaic: return (4, 40, 12)
        case .select, .crop: return (1, 1, 1)
        }
    }

    var hasStyle: Bool { self != .select && self != .crop }

    /// 粗細面板的五種預設大小
    var sizePresets: [CGFloat] {
        switch self {
        case .arrow: return [3, 5, 8, 12, 18]
        case .shape: return [2, 3, 5, 8, 12]
        case .pen: return [2, 4, 6, 10, 16]
        case .mosaic: return [6, 10, 16, 24, 32]
        case .text: return [16, 22, 28, 40, 56]
        case .select, .crop: return [1]
        }
    }
}

enum ShapeKind: Int, CaseIterable {
    case rect, roundedRect, ellipse, line
}

enum TextStyle: Int, CaseIterable {
    case outline, highlight, plain
}

struct Annotation {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case shape(ShapeKind, CGRect)
        case text(String, CGPoint, TextStyle)
        case pen([CGPoint])
        case mosaic(CGRect)
    }

    var kind: Kind
    var color: NSColor
    /// 箭頭/圖形/畫筆 = 線寬，文字 = 字級，馬賽克 = 格子大小
    var size: CGFloat
    /// 文字框寬度（nil = 依內容自動延伸，不換行）
    var textWidth: CGFloat? = nil

    var tool: Tool {
        switch kind {
        case .arrow: return .arrow
        case .line, .shape: return .shape
        case .text: return .text
        case .pen: return .pen
        case .mosaic: return .mosaic
        }
    }

    // MARK: Geometry

    var bounds: CGRect {
        switch kind {
        case let .arrow(a, b):
            return CGRect(p1: a, p2: b).insetBy(dx: -size * 1.6, dy: -size * 1.6)
        case let .line(a, b):
            return CGRect(p1: a, p2: b).insetBy(dx: -size / 2, dy: -size / 2)
        case let .shape(_, r):
            return r.insetBy(dx: -size / 2, dy: -size / 2)
        case .text:
            return TextLayout(self).frame
        case let .pen(pts):
            guard let first = pts.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -size / 2, dy: -size / 2)
        case let .mosaic(r):
            return r
        }
    }

    /// 實際畫出來的範圍（含陰影），用來決定畫布要延伸到哪裡
    var renderBounds: CGRect {
        switch kind {
        case .mosaic: return bounds
        default:
            let m = min(10, max(3, size * 0.6)) + 2
            return bounds.insetBy(dx: -m, dy: -m)
        }
    }

    /// 控制點（用來縮放）
    var handles: [CGPoint] {
        switch kind {
        case let .arrow(a, b), let .line(a, b): return [a, b]
        case let .shape(_, r), let .mosaic(r): return r.corners
        case .text:
            // 0 = 右下（縮放字級），1 = 左側、2 = 右側（調整文字框寬度）
            let f = TextLayout(self).frame
            return [CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.maxX, y: f.midY)]
        case .pen: return bounds.corners
        }
    }

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case let .arrow(a, b):
            return p.distance(toSegment: a, b) <= max(size * 1.2, t)
        case let .line(a, b):
            return p.distance(toSegment: a, b) <= max(size / 2 + t, t)
        case let .shape(k, r):
            let tol = max(size / 2 + t, t)
            switch k {
            case .rect, .roundedRect, .line:
                return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
            case .ellipse:
                guard r.width > 0, r.height > 0 else { return r.insetBy(dx: -tol, dy: -tol).contains(p) }
                let rx = r.width / 2, ry = r.height / 2
                let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
                let d = sqrt(nx * nx + ny * ny)
                return abs(d - 1) * min(rx, ry) <= tol
            }
        case .text, .mosaic:
            return bounds.contains(p)
        case let .pen(pts):
            if pts.count == 1 { return p.distance(to: pts[0]) <= size / 2 + t }
            for i in 1..<pts.count where p.distance(toSegment: pts[i - 1], pts[i]) <= size / 2 + t { return true }
            return false
        }
    }

    mutating func move(by d: CGVector) {
        switch kind {
        case let .arrow(a, b): kind = .arrow(a + d, b + d)
        case let .line(a, b): kind = .line(a + d, b + d)
        case let .shape(k, r): kind = .shape(k, r.offsetBy(dx: d.dx, dy: d.dy))
        case let .text(s, o, st): kind = .text(s, o + d, st)
        case let .pen(pts): kind = .pen(pts.map { $0 + d })
        case let .mosaic(r): kind = .mosaic(r.offsetBy(dx: d.dx, dy: d.dy))
        }
    }

    /// 拖曳控制點 index 到 p；original 為開始拖曳前的狀態
    mutating func drag(handle index: Int, to p: CGPoint, from original: Annotation, constrain: Bool) {
        switch original.kind {
        case let .arrow(a, b):
            if index == 0 { kind = .arrow(constrain ? p.snapped45(from: b) : p, b) }
            else { kind = .arrow(a, constrain ? p.snapped45(from: a) : p) }
        case let .line(a, b):
            if index == 0 { kind = .line(constrain ? p.snapped45(from: b) : p, b) }
            else { kind = .line(a, constrain ? p.snapped45(from: a) : p) }
        case let .shape(k, r):
            let fixed = r.corners[(index + 2) % 4]
            kind = .shape(k, CGRect(p1: fixed, p2: constrain ? p.squared(from: fixed) : p))
        case let .mosaic(r):
            kind = .mosaic(CGRect(p1: r.corners[(index + 2) % 4], p2: p))
        case let .text(s, o, st):
            let layout = TextLayout(original)
            if index == 0 {
                let f = layout.frame
                let oldDiag = max(1, hypot(f.width, f.height))
                let newDiag = hypot(p.x - f.minX, p.y - f.minY)
                let ratio = newDiag / oldDiag
                size = min(300, max(8, original.size * ratio))
                textWidth = original.textWidth.map { $0 * size / original.size }
                kind = .text(s, o, st)
            } else {
                let minW = original.size * 1.2
                let right = o.x + layout.textRect.width
                if index == 1 {
                    let w = max(minW, right - (p.x + layout.padding))
                    textWidth = w
                    kind = .text(s, CGPoint(x: right - w, y: o.y), st)
                } else {
                    textWidth = max(minW, p.x - layout.padding - o.x)
                    kind = .text(s, o, st)
                }
            }
        case let .pen(pts):
            let r = original.bounds.insetBy(dx: original.size / 2, dy: original.size / 2)
            let fixed = r.corners[(index + 2) % 4]
            let nr = CGRect(p1: fixed, p2: p)
            let sx = r.width > 0.5 ? nr.width / r.width : 1
            let sy = r.height > 0.5 ? nr.height / r.height : 1
            kind = .pen(pts.map { CGPoint(x: nr.minX + ($0.x - r.minX) * sx, y: nr.minY + ($0.y - r.minY) * sy) })
        }
    }

    mutating func scale(by s: CGFloat) {
        let m: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * s, y: $0.y * s) }
        let mr: (CGRect) -> CGRect = { CGRect(x: $0.minX * s, y: $0.minY * s, width: $0.width * s, height: $0.height * s) }
        switch kind {
        case let .arrow(a, b): kind = .arrow(m(a), m(b))
        case let .line(a, b): kind = .line(m(a), m(b))
        case let .shape(k, r): kind = .shape(k, mr(r))
        case let .text(t, o, st): kind = .text(t, m(o), st)
        case let .pen(pts): kind = .pen(pts.map(m))
        case let .mosaic(r): kind = .mosaic(mr(r))
        }
        size = max(1, size * s)
        textWidth = textWidth.map { $0 * s }
    }

    /// 太小的物件（誤點）不保留
    var isDegenerate: Bool {
        switch kind {
        case let .arrow(a, b), let .line(a, b): return a.distance(to: b) < 4
        case let .shape(_, r), let .mosaic(r): return r.width < 3 || r.height < 3
        case let .text(s, _, _): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .pen(pts): return pts.isEmpty
        }
    }
}

// MARK: - Text layout

struct TextLayout {
    let string: NSAttributedString
    let textRect: CGRect
    let frame: CGRect
    let style: TextStyle
    let padding: CGFloat

    static let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    init(_ a: Annotation) {
        guard case let .text(s, origin, style) = a.kind else {
            string = NSAttributedString(); textRect = .zero; frame = .zero; self.style = .plain; padding = 0
            return
        }
        self.style = style
        let font = NSFont.systemFont(ofSize: a.size, weight: .bold)
        string = NSAttributedString(string: s.isEmpty ? " " : s, attributes: [.font: font])
        let maxW = a.textWidth ?? 100_000
        let size = string.boundingRect(with: CGSize(width: maxW, height: 100_000), options: Self.drawOptions).size
        textRect = CGRect(origin: origin, size: CGSize(width: a.textWidth ?? ceil(size.width), height: ceil(size.height)))
        switch style {
        case .highlight: padding = a.size * 0.35
        case .outline: padding = a.size * 0.2
        case .plain: padding = 0
        }
        frame = textRect.insetBy(dx: -padding, dy: -padding)
    }
}

// MARK: - Rendering

/// 預先算好整張圖的馬賽克版本，畫的時候只要裁切區域即可
final class MosaicCache {
    private let base: CGImage
    private var cache: [Int: CGImage] = [:]

    init(base: CGImage) { self.base = base }

    func pixellated(block: CGFloat, pixelScale: CGFloat) -> CGImage? {
        let px = max(2, Int((block * pixelScale).rounded()))
        if let c = cache[px] { return c }
        let w = max(1, base.width / px), h = max(1, base.height / px)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()
        cache[px] = img
        return img
    }
}

enum Renderer {
    /// 在「左上角為原點」的 context 中畫 CGImage
    static func drawImage(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static func drawDocument(base: CGImage, imageSize: CGSize, pixelScale: CGFloat, annotations: [Annotation],
                             mosaic: MosaicCache, hiding hidden: Int? = nil, ctx: CGContext) {
        let imageRect = CGRect(origin: .zero, size: imageSize)
        drawImage(base, in: imageRect, ctx: ctx)
        // 馬賽克永遠在最底層，只打碼原始截圖
        for (i, a) in annotations.enumerated() where i != hidden {
            if case let .mosaic(r) = a.kind, let pix = mosaic.pixellated(block: a.size, pixelScale: pixelScale) {
                ctx.saveGState()
                ctx.clip(to: r.intersection(imageRect))
                ctx.interpolationQuality = .none
                drawImage(pix, in: imageRect, ctx: ctx)
                ctx.restoreGState()
            }
        }
        for (i, a) in annotations.enumerated() where i != hidden {
            draw(a, ctx: ctx)
        }
    }

    static func setShadow(_ ctx: CGContext, size: CGFloat) {
        let blur = min(8, max(2, size * 0.6))
        ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
    }

    static func draw(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.kind {
        case let .arrow(s, e):
            guard let path = arrowPath(from: s, to: e, width: a.size) else { return }
            setShadow(ctx, size: a.size)
            ctx.addPath(path)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()

        case let .line(s, e):
            setShadow(ctx, size: a.size)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.size)
            ctx.setLineCap(.round)
            ctx.move(to: s)
            ctx.addLine(to: e)
            ctx.strokePath()

        case let .shape(k, r):
            setShadow(ctx, size: a.size)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.size)
            ctx.setLineJoin(.round)
            switch k {
            case .rect: ctx.addRect(r)
            case .roundedRect:
                let radius = min(max(a.size * 2.5, 8), min(r.width, r.height) / 2)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            case .ellipse: ctx.addEllipse(in: r)
            case .line: break
            }
            ctx.strokePath()

        case let .pen(pts):
            setShadow(ctx, size: a.size)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineWidth(a.size)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - a.size / 2, y: pts[0].y - a.size / 2, width: a.size, height: a.size))
                return
            }
            ctx.move(to: pts[0])
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                ctx.addQuadCurve(to: mid, control: pts[i - 1])
            }
            ctx.addLine(to: pts[pts.count - 1])
            ctx.strokePath()

        case .text:
            drawText(a, ctx: ctx)

        case .mosaic:
            break // 已在 drawDocument 處理
        }
    }

    private static func drawText(_ a: Annotation, ctx: CGContext) {
        let layout = TextLayout(a)
        let contrast = a.color.contrastingColor
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        func attributed(_ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
            let m = NSMutableAttributedString(attributedString: layout.string)
            m.addAttributes(attrs, range: NSRange(location: 0, length: m.length))
            return m
        }

        switch layout.style {
        case .highlight:
            setShadow(ctx, size: a.size * 0.5)
            let radius = min(a.size * 0.4, layout.frame.height / 2)
            ctx.addPath(CGPath(roundedRect: layout.frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            attributed([.foregroundColor: contrast]).draw(with: layout.textRect, options: TextLayout.drawOptions)
        case .outline:
            ctx.saveGState()
            setShadow(ctx, size: a.size * 0.4)
            // 圓角描邊，避免 A、M 等尖角出現尖刺
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            attributed([.strokeColor: contrast, .strokeWidth: 22, .foregroundColor: contrast])
                .draw(with: layout.textRect, options: TextLayout.drawOptions)
            ctx.restoreGState()
            attributed([.foregroundColor: a.color]).draw(with: layout.textRect, options: TextLayout.drawOptions)
        case .plain:
            attributed([.foregroundColor: a.color]).draw(with: layout.textRect, options: TextLayout.drawOptions)
        }
    }

    /// Skitch 風格：尾端細、往前漸粗的實心箭頭
    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath? {
        let len = s.distance(to: e)
        guard len >= 1 else { return nil }
        let headLen = min(len * 0.7, max(w * 3.2, 12))
        let headW = max(w * 3.2, 12)
        let shaftW = w
        let tailW = w * 0.3
        let local: [CGPoint] = [
            CGPoint(x: 0, y: -tailW / 2),
            CGPoint(x: len - headLen * 0.85, y: -shaftW / 2),
            CGPoint(x: len - headLen, y: -headW / 2),
            CGPoint(x: len, y: 0),
            CGPoint(x: len - headLen, y: headW / 2),
            CGPoint(x: len - headLen * 0.85, y: shaftW / 2),
            CGPoint(x: 0, y: tailW / 2),
        ]
        let t = CGAffineTransform(translationX: s.x, y: s.y).rotated(by: atan2(e.y - s.y, e.x - s.x))
        let path = CGMutablePath()
        path.addLines(between: local, transform: t)
        path.closeSubpath()
        return path
    }
}

// MARK: - Helpers

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    /// 左上、右上、右下、左下
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

extension CGPoint {
    static func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
    static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }

    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }

    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / l2))
        return distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// 按住 Shift：鎖定 45° 角
    func snapped45(from o: CGPoint) -> CGPoint {
        let len = distance(to: o)
        let angle = (atan2(y - o.y, x - o.x) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: o.x + cos(angle) * len, y: o.y + sin(angle) * len)
    }

    /// 按住 Shift：正方形/正圓
    func squared(from o: CGPoint) -> CGPoint {
        let d = max(abs(x - o.x), abs(y - o.y))
        return CGPoint(x: o.x + (x >= o.x ? d : -d), y: o.y + (y >= o.y ? d : -d))
    }
}

extension NSColor {
    var contrastingColor: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.7 ? .black : .white
    }
}
