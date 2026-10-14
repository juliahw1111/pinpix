import AppKit

protocol CanvasViewDelegate: AnyObject {
    /// 目前工具列上的樣式
    func currentStyle(for tool: Tool) -> (color: NSColor, size: CGFloat)
    var currentShapeKind: ShapeKind { get }
    var currentTextStyle: TextStyle { get }
    func canvasSelectionChanged(_ annotation: Annotation?)
    func canvasCropChanged(active: Bool)
    /// 裁切範圍改變（像素尺寸），用來更新寬高欄位
    func canvasCropSizeChanged(_ pixelSize: CGSize)
    func canvasRequestsTool(_ tool: Tool)
    func canvasDidChange()
    func canvasShowMessage(_ message: String)
}

final class CanvasView: NSView, NSTextFieldDelegate {
    weak var delegate: CanvasViewDelegate?

    var document: EditorDocument? {
        didSet {
            endTextEditing()
            selectedIndex = nil
            cropRect = nil
            refreshCanvasBounds()
        }
    }

    var tool: Tool = .arrow {
        didSet {
            if oldValue == .crop && tool != .crop { cropRect = nil; refreshCanvasBounds() }
            if tool == .crop && oldValue != .crop { beginCrop(returningTo: oldValue) }
            refreshCursor()
        }
    }

    private(set) var selectedIndex: Int? {
        didSet {
            delegate?.canvasSelectionChanged(selected)
            needsDisplay = true
        }
    }

    var selected: Annotation? {
        guard let i = selectedIndex, let doc = document, doc.annotations.indices.contains(i) else { return nil }
        return doc.annotations[i]
    }

    private(set) var cropRect: CGRect? {
        didSet {
            if (oldValue == nil) != (cropRect == nil) { delegate?.canvasCropChanged(active: cropRect != nil) }
            if let c = cropRect, let s = document?.pixelScale {
                delegate?.canvasCropSizeChanged(CGSize(width: (c.width * s).rounded(), height: (c.height * s).rounded()))
            }
            needsDisplay = true
        }
    }

    private enum Drag {
        case none
        case creating(Int)
        case moving(Int, start: CGPoint, original: Annotation)
        case handle(Int, handle: Int, original: Annotation)
        case cropHandle(Int, original: CGRect)
    }

    private var drag: Drag = .none
    private var dragCheckpointed = false
    /// 建立圖形時的起點
    private var creationStart: CGPoint?

    private var textField: NSTextField?
    private var editingIndex: Int?
    private var editingIsNew = false

    // 顯示比例：圖片座標 → 視圖座標
    private(set) var zoom: CGFloat = 1
    private var imageOrigin: CGPoint = .zero
    /// 畫布範圍（截圖 + 超出截圖的標註）。拖曳中不更新，放開後才重新置中縮放，避免畫面跳動
    private var canvasBounds: CGRect = .zero
    /// 留給浮動工具列的空間（上：標題列，左：工具列，下：動作列）
    var contentInsets = NSEdgeInsets(top: 40, left: 84, bottom: 72, right: 28) { didSet { updateTransform() } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        updateTransform()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTransform()
    }

    /// 重新計算畫布範圍（標註超出截圖時，畫布跟著延伸、整體縮小顯示）
    func refreshCanvasBounds() {
        canvasBounds = document?.contentBounds ?? .zero
        // 裁切中：畫面要容納整個裁切框（往外延伸時）
        if let c = cropRect { canvasBounds = canvasBounds.union(c) }
        updateTransform()
    }

    private func updateTransform() {
        guard document != nil, canvasBounds.width > 0, canvasBounds.height > 0 else { return }
        let b = canvasBounds
        let i = contentInsets
        let availW = max(10, bounds.width - i.left - i.right), availH = max(10, bounds.height - i.top - i.bottom)
        zoom = min(1, availW / b.width, availH / b.height)
        imageOrigin = CGPoint(x: (i.left + (availW - b.width * zoom) / 2 - b.minX * zoom).rounded(),
                              y: (i.top + (availH - b.height * zoom) / 2 - b.minY * zoom).rounded())
        repositionTextField()
        needsDisplay = true
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageOrigin.x) / zoom, y: (p.y - imageOrigin.y) / zoom)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + imageOrigin.x, y: p.y * zoom + imageOrigin.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        guard let doc = document, let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        ctx.scaleBy(x: zoom, y: zoom)

        let imageRect = CGRect(origin: .zero, size: doc.imageSize)
        // 畫布（截圖 + 延伸區）：即時依標註範圍延伸，不等放開滑鼠
        let page = doc.contentBounds
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor((Prefs.canvasFillColor ?? .white).cgColor)
        ctx.fill(page)
        ctx.restoreGState()
        if Prefs.canvasFillColor == nil, page != imageRect {
            drawCheckerboard(page, ctx: ctx)
        }

        ctx.interpolationQuality = zoom < 1 ? .high : .none
        Renderer.drawDocument(base: doc.base, imageSize: doc.imageSize, pixelScale: doc.pixelScale,
                              annotations: doc.annotations, mosaic: doc.mosaic, ctx: ctx)

        if let sel = selected, editingIndex == nil { drawSelection(sel, ctx: ctx) }
        // 編輯中的文字：直接顯示最終樣式，只加一條細外框
        if let i = editingIndex, doc.annotations.indices.contains(i) {
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(doc.annotations[i].bounds.insetBy(dx: -2 / zoom, dy: -2 / zoom))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let crop = cropRect { drawCrop(crop, imageRect: imageRect, ctx: ctx) }
        ctx.restoreGState()
    }

    /// 透明延伸區用棋盤格表示
    private func drawCheckerboard(_ r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(r)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        let cell = 8 / zoom
        var y = floor(r.minY / cell) * cell
        var row = 0
        while y < r.maxY {
            var x = floor(r.minX / cell) * cell + (row % 2 == 0 ? 0 : cell)
            while x < r.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell
            row += 1
        }
        ctx.restoreGState()
    }

    private var handleRadius: CGFloat { 5 / zoom }

    private func drawHandles(_ pts: [CGPoint], ctx: CGContext) {
        let r = handleRadius
        ctx.setLineWidth(1.5 / zoom)
        for p in pts {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.strokeEllipse(in: rect)
        }
    }

    private func drawSelection(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let accent = NSColor.controlAccentColor
        switch a.kind {
        case .text:
            // 文字框：實線外框、左右調寬把手、右下縮放點、上方「文字效果」按鈕
            let f = a.bounds
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5 / zoom)
            ctx.stroke(f)
            let hw = 6 / zoom, hh = 16 / zoom
            for x in [f.minX, f.maxX] {
                let cap = CGRect(x: x - hw / 2, y: f.midY - hh / 2, width: hw, height: hh)
                let path = CGPath(roundedRect: cap, cornerWidth: hw / 2, cornerHeight: hw / 2, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.strokePath()
            }
            let r = 5 / zoom
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: CGRect(x: f.maxX - r, y: f.maxY - r, width: r * 2, height: r * 2))
            drawStyleBadge(for: a, ctx: ctx)
        case .pen, .mosaic:
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(a.bounds)
            ctx.setLineDash(phase: 0, lengths: [])
            drawHandles(a.handles, ctx: ctx)
        default:
            drawHandles(a.handles, ctx: ctx)
        }
    }

    /// 文字框上方的「文字效果」按鈕位置（圖片座標）
    private func styleBadgeRect(for a: Annotation) -> CGRect {
        let f = a.bounds
        let d = 24 / zoom
        return CGRect(x: f.midX - d / 2, y: f.minY - d - 8 / zoom, width: d, height: d)
    }

    private func drawStyleBadge(for a: Annotation, ctx: CGContext) {
        guard case let .text(_, _, style) = a.kind else { return }
        let r = styleBadgeRect(for: a)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3 / zoom, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        // 用「a」的樣子預覽目前效果
        let font = NSFont.systemFont(ofSize: 15 / zoom, weight: .bold)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        if style == .outline { attrs[.strokeWidth] = -4; attrs[.strokeColor] = NSColor.black.withAlphaComponent(0.6) }
        let str = NSAttributedString(string: "a", attributes: attrs)
        let size = str.size()
        if style == .highlight {
            let bg = CGRect(x: r.midX - size.width / 2 - 2 / zoom, y: r.midY - size.height / 2 + 2 / zoom,
                            width: size.width + 4 / zoom, height: size.height - 4 / zoom)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 2 / zoom, cornerHeight: 2 / zoom, transform: nil))
            ctx.fillPath()
        }
        str.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
    }

    /// 裁切框的 8 個控制點：0 左上、1 上、2 右上、3 右、4 右下、5 下、6 左下、7 左
    private func cropHandles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func drawCrop(_ r: CGRect, imageRect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        // 往外延伸的部分先預覽底色
        if let fill = Prefs.canvasFillColor {
            ctx.addRect(r)
            ctx.addRect(document?.contentBounds ?? imageRect)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        // 裁掉的部分變暗
        // 只把畫布上要被裁掉的部分變暗，視窗背景保持原樣
        ctx.addRect(r.union(document?.contentBounds ?? imageRect))
        ctx.addRect(r)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        // 黑邊包白線：淺色、深色背景上都看得到
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(3.5 / zoom)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 / zoom)
        ctx.stroke(r)
        // 三分線
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1 / zoom)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
        // 控制點：四角 L 形、四邊短橫條（先畫深色外框再畫白色）
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let l = 16 / zoom
        for (color, width) in [(NSColor.black.withAlphaComponent(0.55), 7.0), (NSColor.white, 4.0)] {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width / zoom)
        for (i, p) in cropHandles(r).enumerated() {
            switch i {
            case 0: ctx.move(to: CGPoint(x: p.x, y: p.y + l)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x + l, y: p.y))
            case 2: ctx.move(to: CGPoint(x: p.x - l, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + l))
            case 4: ctx.move(to: CGPoint(x: p.x, y: p.y - l)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x - l, y: p.y))
            case 6: ctx.move(to: CGPoint(x: p.x + l, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y - l))
            case 1, 5: ctx.move(to: CGPoint(x: p.x - l, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + l, y: p.y))
            default: ctx.move(to: CGPoint(x: p.x, y: p.y - l)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + l))
            }
        }
        ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawBadge(_ s: String, at p: CGPoint, ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: 11 / zoom, weight: .medium)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = str.size()
        var rect = CGRect(x: p.x, y: p.y - size.height - 4 / zoom, width: size.width + 12 / zoom, height: size.height + 4 / zoom)
        if rect.minY < canvasBounds.minY { rect.origin.y = p.y + 16 / zoom }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4 / zoom, cornerHeight: 4 / zoom, transform: nil))
        ctx.fillPath()
        str.draw(at: CGPoint(x: rect.minX + 6 / zoom, y: rect.minY + 2 / zoom))
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    func refreshCursor() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateCursor(at viewPoint: CGPoint) {
        guard bounds.contains(viewPoint) else { return }
        // 滑到浮動工具列等上層元件時，用一般游標
        if let content = window?.contentView, let hit = content.hitTest(content.convert(viewPoint, from: self)), hit !== self {
            if !(hit is NSTextField) { NSCursor.arrow.set() }
            return
        }
        if let field = textField, field.frame.contains(viewPoint) { NSCursor.iBeam.set(); return }
        cursor(at: toImage(viewPoint)).set()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard document != nil else { return .arrow }
        if tool == .crop {
            guard let c = cropRect, let h = cropHandleIndex(at: p, in: c) else { return .arrow }
            switch h {
            case 1, 5: return .resizeUpDown
            case 3, 7: return .resizeLeftRight
            default: return ToolCursors.resize
            }
        }
        if let sel = selected {
            if case .text = sel.kind, styleBadgeRect(for: sel).contains(p) { return .pointingHand }
            if let h = handleIndex(at: p, in: sel.handles) {
                if case .text = sel.kind, h > 0 { return .resizeLeftRight }
                return ToolCursors.resize
            }
        }
        if hitAnnotation(at: p) != nil { return ToolCursors.move }
        let color = delegate?.currentStyle(for: tool).color ?? .systemRed
        return ToolCursors.tool(tool, shape: delegate?.currentShapeKind ?? .rect, color: color)
    }

    // MARK: Hit testing

    private func handleIndex(at p: CGPoint, in pts: [CGPoint]) -> Int? {
        let r = handleRadius * 2
        return pts.firstIndex { $0.distance(to: p) <= r }
    }

    /// 裁切框控制點：靠近四角或四邊（整條邊都可以拖）
    private func cropHandleIndex(at p: CGPoint, in r: CGRect) -> Int? {
        let t = 10 / zoom
        if let i = cropHandles(r).enumerated().first(where: { [0, 2, 4, 6].contains($0.offset) && $0.element.distance(to: p) <= t * 1.6 })?.offset {
            return i
        }
        let inY = p.y > r.minY - t && p.y < r.maxY + t, inX = p.x > r.minX - t && p.x < r.maxX + t
        if inX && abs(p.y - r.minY) <= t { return 1 }
        if inX && abs(p.y - r.maxY) <= t { return 5 }
        if inY && abs(p.x - r.minX) <= t { return 7 }
        if inY && abs(p.x - r.maxX) <= t { return 3 }
        return nil
    }

    private func hitAnnotation(at p: CGPoint) -> Int? {
        guard let doc = document else { return nil }
        let tol = 4 / zoom
        // 由上而下找；馬賽克在最底層
        let order = doc.annotations.indices.reversed().sorted { a, b in
            let am = doc.annotations[a].tool == .mosaic, bm = doc.annotations[b].tool == .mosaic
            return am == bm ? a > b : !am
        }
        return order.first { doc.annotations[$0].hitTest(p, tolerance: tol) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // 若正在打字，先結束文字編輯
        guard let doc = document else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        dragCheckpointed = false
        drag = .none

        if tool == .crop {
            // 只能拖邊或角調整（往內裁、往外延伸），不另外拉新框
            if let c = cropRect, let h = cropHandleIndex(at: p, in: c) { drag = .cropHandle(h, original: c) }
            return
        }

        if let i = selectedIndex, let sel = selected {
            // 文字框上方按鈕：一鍵切換文字效果
            if case let .text(s, o, style) = sel.kind, styleBadgeRect(for: sel).contains(p) {
                let next = TextStyle(rawValue: (style.rawValue + 1) % TextStyle.allCases.count) ?? .outline
                doc.checkpoint()
                doc.annotations[i].kind = .text(s, o, next)
                Prefs.textStyle = next
                delegate?.canvasShowMessage("文字效果：\(["描邊", "醒目", "一般"][next.rawValue])")
                notifyChange()
                return
            }
            if let h = handleIndex(at: p, in: sel.handles) {
                drag = .handle(i, handle: h, original: sel)
                return
            }
        }

        if let hit = hitAnnotation(at: p) {
            if event.clickCount == 2, case .text = doc.annotations[hit].kind {
                beginTextEditing(index: hit, isNew: false)
                return
            }
            selectedIndex = hit
            drag = .moving(hit, start: p, original: doc.annotations[hit])
            return
        }

        selectedIndex = nil
        guard tool.hasStyle else { return }
        let style = delegate?.currentStyle(for: tool) ?? (.systemRed, 6)
        let kind: Annotation.Kind
        switch tool {
        case .arrow: kind = .arrow(p, p)
        case .shape:
            let k = delegate?.currentShapeKind ?? .rect
            kind = k == .line ? .line(p, p) : .shape(k, CGRect(origin: p, size: .zero))
        case .pen: kind = .pen([p])
        case .mosaic: kind = .mosaic(CGRect(origin: p, size: .zero))
        case .text:
            doc.checkpoint()
            doc.annotations.append(Annotation(kind: .text("", p, delegate?.currentTextStyle ?? .outline),
                                              color: style.color, size: style.size))
            beginTextEditing(index: doc.annotations.count - 1, isNew: true)
            return
        case .select, .crop: return
        }
        doc.checkpoint()
        dragCheckpointed = true
        creationStart = p
        doc.annotations.append(Annotation(kind: kind, color: style.color, size: style.size))
        drag = .creating(doc.annotations.count - 1)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let doc = document else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        func checkpointOnce() {
            if !dragCheckpointed { doc.checkpoint(); dragCheckpointed = true }
        }

        switch drag {
        case .none: return
        case let .creating(i):
            guard doc.annotations.indices.contains(i) else { return }
            var a = doc.annotations[i]
            let start = creationStart ?? p
            switch a.kind {
            case let .arrow(s, _): a.kind = .arrow(s, shift ? p.snapped45(from: s) : p)
            case let .line(s, _): a.kind = .line(s, shift ? p.snapped45(from: s) : p)
            case let .shape(k, _): a.kind = .shape(k, CGRect(p1: start, p2: shift ? p.squared(from: start) : p))
            case .mosaic: a.kind = .mosaic(CGRect(p1: start, p2: p))
            case var .pen(pts):
                if let last = pts.last, last.distance(to: p) < 1 / zoom { return }
                pts.append(p)
                a.kind = .pen(pts)
            case .text: break
            }
            doc.annotations[i] = a
        case let .moving(i, start, original):
            checkpointOnce()
            var a = original
            var d = p - start
            if shift { if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 } }
            a.move(by: d)
            doc.annotations[i] = a
        case let .handle(i, h, original):
            checkpointOnce()
            var a = original
            a.drag(handle: h, to: p, from: original, constrain: shift)
            doc.annotations[i] = a
        case let .cropHandle(h, original):
            let minSize: CGFloat = 8
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if [0, 6, 7].contains(h) { minX = min(p.x, maxX - minSize) }
            if [2, 3, 4].contains(h) { maxX = max(p.x, minX + minSize) }
            if [0, 1, 2].contains(h) { minY = min(p.y, maxY - minSize) }
            if [4, 5, 6].contains(h) { maxY = max(p.y, minY + minSize) }
            // 對齊像素格
            let s = doc.pixelScale
            func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
            cropRect = CGRect(x: snap(minX), y: snap(minY), width: snap(maxX) - snap(minX), height: snap(maxY) - snap(minY))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let doc = document else { return }
        defer {
            drag = .none
            creationStart = nil
            needsDisplay = true
            refreshCursor()
        }
        switch drag {
        case let .creating(i):
            guard doc.annotations.indices.contains(i) else { return }
            if doc.annotations[i].isDegenerate {
                doc.annotations.remove(at: i)
                doc.discardLastCheckpoint()
            } else {
                selectedIndex = i
                notifyChange()
            }
        case .moving, .handle:
            if dragCheckpointed { notifyChange() }
        case .cropHandle:
            refreshCanvasBounds()
        case .none: break
        }
    }

    private func notifyChange() {
        refreshCanvasBounds()
        delegate?.canvasDidChange()
        document?.changed()
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117: // delete / forward delete
            deleteSelection(); return
        case 53: // esc
            if cropRect != nil { cancelCrop() } else { selectedIndex = nil }
            return
        case 36, 76: // return
            if cropRect != nil { applyCrop(); return }
            if let i = selectedIndex, case .text = document?.annotations[i].kind { beginTextEditing(index: i, isNew: false); return }
        case 123, 124, 125, 126: // 方向鍵微調
            if mods.isEmpty, let i = selectedIndex, let doc = document {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                                   125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][event.keyCode]!
                doc.checkpoint(coalesceKey: "nudge\(i)")
                doc.annotations[i].move(by: d)
                notifyChange()
                return
            }
        default: break
        }
        if mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased() {
            let map: [String: Tool] = ["a": .arrow, "r": .shape, "t": .text, "p": .pen, "m": .mosaic, "c": .crop]
            if let t = map[c] { delegate?.canvasRequestsTool(t); return }
        }
        super.keyDown(with: event)
    }

    func deleteSelection() {
        guard let i = selectedIndex, let doc = document, doc.annotations.indices.contains(i) else { return }
        doc.checkpoint()
        doc.annotations.remove(at: i)
        selectedIndex = nil
        notifyChange()
    }

    /// 進入裁切：框直接套在目前整張畫布上
    private var toolBeforeCrop: Tool = .arrow

    private func beginCrop(returningTo previous: Tool) {
        guard let doc = document else { return }
        endTextEditing()
        selectedIndex = nil
        toolBeforeCrop = previous == .crop ? .arrow : previous
        cropRect = doc.contentBounds
        refreshCanvasBounds()
    }

    func applyCrop() {
        guard let c = cropRect, let doc = document else { return }
        cropRect = nil
        if c != doc.contentBounds { doc.crop(to: c, fill: Prefs.canvasFillColor) }
        delegate?.canvasRequestsTool(toolBeforeCrop)
        refreshCanvasBounds()
        delegate?.canvasDidChange()
        doc.changed()
    }

    func cancelCrop() {
        cropRect = nil
        delegate?.canvasRequestsTool(toolBeforeCrop)
        refreshCanvasBounds()
    }

    /// 從寬高欄位設定裁切大小（像素），以左上角為基準
    func setCropPixelSize(width: Int, height: Int) {
        guard var c = cropRect, let s = document?.pixelScale, width >= 8, height >= 8 else { return }
        c.size = CGSize(width: CGFloat(width) / s, height: CGFloat(height) / s)
        cropRect = c
        refreshCanvasBounds()
    }

    /// 工具列改變顏色/尺寸/形狀時套用到選取的物件
    func applyStyleToSelection(color: NSColor? = nil, size: CGFloat? = nil, shape: ShapeKind? = nil, textStyle: TextStyle? = nil) {
        guard let doc = document else { return }
        let target = editingIndex ?? selectedIndex
        guard let i = target, doc.annotations.indices.contains(i) else { return }
        var a = doc.annotations[i]
        if let color { a.color = color }
        if let size {
            a.textWidth = a.textWidth.map { $0 * size / a.size }
            a.size = size
        }
        if let shape {
            switch a.kind {
            case let .shape(_, r):
                if shape == .line { a.kind = .line(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)) }
                else { a.kind = .shape(shape, r) }
            case let .line(s, e):
                if shape != .line { a.kind = .shape(shape, CGRect(p1: s, p2: e)) }
            default: break
            }
        }
        if let textStyle, case let .text(s, o, _) = a.kind { a.kind = .text(s, o, textStyle) }
        doc.checkpoint(coalesceKey: "style\(i)")
        doc.annotations[i] = a
        if editingIndex != nil { styleTextField() }
        notifyChange()
    }

    func refreshAfterUndo() {
        endTextEditing(commit: false)
        if let i = selectedIndex, let doc = document, !doc.annotations.indices.contains(i) { selectedIndex = nil }
        cropRect = nil
        refreshCanvasBounds()
        delegate?.canvasSelectionChanged(selected)
    }

    // MARK: Text editing

    private func beginTextEditing(index: Int, isNew: Bool) {
        guard let doc = document, case let .text(s, _, _) = doc.annotations[index].kind else { return }
        endTextEditing()
        selectedIndex = nil
        editingIndex = index
        editingIsNew = isNew
        if !isNew { doc.checkpoint() }

        // 在截圖外點一下就立刻延伸畫布
        refreshCanvasBounds()

        let field = NSTextField(string: s)
        // 透明輸入框：文字本身由畫布用最終樣式畫出，輸入框只負責游標與輸入
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.isScrollable = false
        field.delegate = self
        addSubview(field)
        textField = field
        styleTextField()
        window?.makeFirstResponder(field)
        styleTextField()
        field.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)
        needsDisplay = true
    }

    private func styleTextField() {
        guard let field = textField, let i = editingIndex, let doc = document else { return }
        let a = doc.annotations[i]
        field.font = NSFont.systemFont(ofSize: a.size * zoom, weight: .bold)
        field.textColor = .clear
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.enclosingScrollView?.drawsBackground = false
            editor.insertionPointColor = a.color.contrastingColor == .white ? a.color : .black
            // 選取文字時只用淡淡的底色，不要整塊反白
            editor.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.2)]
        }
        field.cell?.wraps = a.textWidth != nil
        repositionTextField()
    }

    private func repositionTextField() {
        guard let field = textField, let i = editingIndex, let doc = document,
              doc.annotations.indices.contains(i), case let .text(_, o, _) = doc.annotations[i].kind else { return }
        var a = doc.annotations[i]
        a.kind = .text(field.stringValue, o, .plain)
        let r = TextLayout(a).textRect
        let origin = toView(r.origin)
        let extra: CGFloat = a.textWidth == nil ? 24 : 6
        field.frame = CGRect(x: origin.x - 3, y: origin.y - 2,
                             width: max(r.width * zoom + extra, 40), height: r.height * zoom + 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        // 打字時同步內容，畫布跟著即時延伸
        if let field = textField, let i = editingIndex, let doc = document, doc.annotations.indices.contains(i),
           case let .text(_, o, st) = doc.annotations[i].kind {
            doc.annotations[i].kind = .text(field.stringValue, o, st)
            let b = doc.contentBounds
            if !canvasBounds.contains(b) { refreshCanvasBounds() }
        }
        repositionTextField()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        if sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditing()
    }

    var isEditingText: Bool { textField != nil }

    private func endTextEditing(commit: Bool = true) {
        guard let field = textField else { return }
        textField = nil
        let i = editingIndex
        editingIndex = nil
        field.delegate = nil
        field.removeFromSuperview()
        guard commit, let i, let doc = document, doc.annotations.indices.contains(i),
              case let .text(_, o, st) = doc.annotations[i].kind else { needsDisplay = true; return }
        doc.annotations[i].kind = .text(field.stringValue, o, st)
        if doc.annotations[i].isDegenerate {
            doc.annotations.remove(at: i)
            if editingIsNew { doc.discardLastCheckpoint() }
        } else {
            selectedIndex = i
        }
        notifyChange()
    }
}

// MARK: - 游標

/// 十字游標右下角帶一個工具小圖示（顏色 = 目前顏色），讓使用者一眼知道現在是什麼工具
enum ToolCursors {
    private static var cache: [String: NSCursor] = [:]

    static func tool(_ tool: Tool, shape: ShapeKind = .rect, color: NSColor) -> NSCursor {
        let symbol = tool == .shape ? EditorWindowController.shapeSymbol(shape) : tool.symbol
        let key = "\(symbol)-\(color.hexKey)"
        if let c = cache[key] { return c }
        let size = NSSize(width: 34, height: 34)
        let hot = CGPoint(x: 10, y: 10)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            if tool == .text {
                // 文字工具：I 形游標
                drawOutlined(ctx) { ctx in
                    ctx.move(to: CGPoint(x: hot.x, y: hot.y - 8)); ctx.addLine(to: CGPoint(x: hot.x, y: hot.y + 8))
                    ctx.move(to: CGPoint(x: hot.x - 4, y: hot.y - 8)); ctx.addLine(to: CGPoint(x: hot.x + 4, y: hot.y - 8))
                    ctx.move(to: CGPoint(x: hot.x - 4, y: hot.y + 8)); ctx.addLine(to: CGPoint(x: hot.x + 4, y: hot.y + 8))
                }
            } else {
                drawOutlined(ctx) { ctx in
                    ctx.move(to: CGPoint(x: hot.x - 9, y: hot.y)); ctx.addLine(to: CGPoint(x: hot.x - 2, y: hot.y))
                    ctx.move(to: CGPoint(x: hot.x + 2, y: hot.y)); ctx.addLine(to: CGPoint(x: hot.x + 9, y: hot.y))
                    ctx.move(to: CGPoint(x: hot.x, y: hot.y - 9)); ctx.addLine(to: CGPoint(x: hot.x, y: hot.y - 2))
                    ctx.move(to: CGPoint(x: hot.x, y: hot.y + 2)); ctx.addLine(to: CGPoint(x: hot.x, y: hot.y + 9))
                }
            }
            // 工具徽章
            let badge = CGRect(x: 16, y: 16, width: 17, height: 17)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: badge)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: badge.insetBy(dx: 1.5, dy: 1.5))
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = sym.size
                sym.tinted(color.contrastingColor).draw(in: CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2,
                                                                   width: s.width, height: s.height))
            }
            return true
        }
        let c = NSCursor(image: img, hotSpot: hot)
        cache[key] = c
        return c
    }

    static let move: NSCursor = symbolCursor("arrow.up.and.down.and.arrow.left.and.right")
    static let resize: NSCursor = symbolCursor("arrow.up.left.and.arrow.down.right")

    private static func symbolCursor(_ name: String) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return .openHand
        }
        let size = NSSize(width: sym.size.width + 6, height: sym.size.height + 6)
        let img = NSImage(size: size, flipped: false) { rect in
            let white = sym.tinted(.white)
            let base = CGRect(x: 3, y: 3, width: sym.size.width, height: sym.size.height)
            // 白色描邊，深色背景上也看得到
            for dx in [-1.5, 0, 1.5] { for dy in [-1.5, 0, 1.5] { white.draw(in: base.offsetBy(dx: dx, dy: dy)) } }
            sym.tinted(.black).draw(in: base)
            return true
        }
        return NSCursor(image: img, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private static func drawOutlined(_ ctx: CGContext, _ path: (CGContext) -> Void) {
        ctx.setLineCap(.round)
        path(ctx)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3.5)
        ctx.strokePath()
        path(ctx)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }
}

private extension NSColor {
    var hexKey: String {
        guard let c = usingColorSpace(.sRGB) else { return "x" }
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
