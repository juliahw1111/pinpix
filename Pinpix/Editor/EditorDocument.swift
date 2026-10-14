import AppKit
import UniformTypeIdentifiers

/// 一張截圖與其上的所有標註，含復原/重做
final class EditorDocument {
    private struct Snapshot {
        var base: CGImage
        var annotations: [Annotation]
    }

    private(set) var base: CGImage {
        didSet { mosaic = MosaicCache(base: base) }
    }
    let pixelScale: CGFloat
    var annotations: [Annotation] = []
    private(set) var mosaic: MosaicCache

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastCoalesceKey: String?
    private var lastCheckpointTime = Date.distantPast

    /// 內容有變動時呼叫（用來更新剪貼簿、自動存檔）
    var onChange: (() -> Void)?

    init(image: CGImage, pixelScale: CGFloat) {
        base = image
        self.pixelScale = max(1, pixelScale)
        mosaic = MosaicCache(base: image)
    }

    var imageSize: CGSize {
        CGSize(width: CGFloat(base.width) / pixelScale, height: CGFloat(base.height) / pixelScale)
    }

    /// 畫布範圍（圖片座標）：截圖本身，加上超出截圖的標註；對齊像素格
    var contentBounds: CGRect {
        var r = CGRect(origin: .zero, size: imageSize)
        for a in annotations { r = r.union(a.renderBounds) }
        let s = pixelScale
        let minX = floor(r.minX * s) / s, minY = floor(r.minY * s) / s
        let maxX = ceil(r.maxX * s) / s, maxY = ceil(r.maxY * s) / s
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 輸出的像素尺寸（含延伸出去的畫布）
    var pixelSize: CGSize {
        let b = contentBounds
        return CGSize(width: (b.width * pixelScale).rounded(), height: (b.height * pixelScale).rounded())
    }

    /// 截圖本身的像素尺寸
    var imagePixelSize: CGSize { CGSize(width: base.width, height: base.height) }

    // MARK: Undo

    /// 修改前呼叫；同一個 coalesceKey 在短時間內只記一次（例如拖動滑桿）
    func checkpoint(coalesceKey: String? = nil) {
        let now = Date()
        if let key = coalesceKey, key == lastCoalesceKey, now.timeIntervalSince(lastCheckpointTime) < 1.5 {
            lastCheckpointTime = now
            return
        }
        lastCoalesceKey = coalesceKey
        lastCheckpointTime = now
        undoStack.append(Snapshot(base: base, annotations: annotations))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// 取消最後一次 checkpoint（例如誤點產生的空物件）
    func discardLastCheckpoint() {
        _ = undoStack.popLast()
        lastCoalesceKey = nil
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, annotations: annotations))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, annotations: annotations))
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        if s.base !== base { base = s.base }
        annotations = s.annotations
        lastCoalesceKey = nil
        changed()
    }

    func changed() { onChange?() }

    // MARK: 裁切 / 調整尺寸

    /// 裁切／延伸：rect 可以小於截圖（裁掉）或超出截圖（延伸，用 fill 補底色；nil 為透明）
    func crop(to rect: CGRect, fill: NSColor?) {
        let s = pixelScale
        let px = CGRect(x: (rect.minX * s).rounded(), y: (rect.minY * s).rounded(),
                        width: (rect.width * s).rounded(), height: (rect.height * s).rounded())
        let w = Int(px.width), h = Int(px.height)
        guard w >= 2, h >= 2, w <= 30000, h <= 30000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CG 原點在左下：原圖左上角位於 (-px.minX, -px.minY)
        ctx.draw(base, in: CGRect(x: -px.minX, y: CGFloat(h) + px.minY - CGFloat(base.height),
                                  width: CGFloat(base.width), height: CGFloat(base.height)))
        guard let img = ctx.makeImage() else { return }
        checkpoint()
        base = img
        let d = CGVector(dx: -px.minX / s, dy: -px.minY / s)
        for i in annotations.indices { annotations[i].move(by: d) }
        // 完全被裁掉的標註一併移除
        let bounds = CGRect(origin: .zero, size: imageSize)
        annotations.removeAll { !$0.bounds.intersects(bounds) }
        changed()
    }

    func resize(toPixelWidth w: Int, height h: Int) {
        guard w >= 1, h >= 1, w <= 16000, h <= 16000, w != base.width || h != base.height else { return }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return }
        let s = CGFloat(w) / CGFloat(base.width)
        checkpoint()
        base = img
        for i in annotations.indices { annotations[i].scale(by: s) }
        changed()
    }

    // MARK: 輸出

    /// 以原始解析度輸出含標註的圖；標註超出截圖時畫布會跟著延伸（延伸處的底色見偏好設定）
    /// - Parameter background: 延伸處的底色；nil 為透明
    func render(background: NSColor? = Prefs.canvasFillColor) -> CGImage? {
        let bounds = contentBounds
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: pixelScale, y: -pixelScale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        Renderer.drawDocument(base: base, imageSize: imageSize, pixelScale: pixelScale,
                              annotations: annotations, mosaic: mosaic, ctx: ctx)
        return ctx.makeImage()
    }

    func pngData() -> Data? {
        guard let img = render() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = contentBounds.size // 保留 Retina DPI，貼到其他 App 時尺寸正確
        return rep.representation(using: .png, properties: [:])
    }

    func copyToPasteboard() {
        guard let png = pngData() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }
}
