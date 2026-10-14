import AppKit
import Carbon.HIToolbox
import OSLog
import ScreenCaptureKit

let captureLog = Logger(subsystem: "app.pinpix.mac", category: "capture")

/// 按下快捷鍵 → 凍結所有螢幕畫面 → 拖曳選取範圍（或點選視窗）
final class ScreenCapturer {
    var onCapture: ((CGImage, CGFloat, NSScreen) -> Void)?
    private var overlays: [SelectionOverlayWindow] = []
    private var isStarting = false

    func start() {
        // 選取中再按一次快捷鍵 = 取消
        captureLog.info("start: overlays=\(self.overlays.count) starting=\(self.isStarting) screens=\(NSScreen.screens.count)")
        if !overlays.isEmpty { cancel(); return }
        guard !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            requestPermission()
            return
        }
        isStarting = true
        // 先記下視窗位置（由前到後），讓使用者可以點選單一視窗
        let windowRects = Self.onScreenWindowRects()
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let shots = try await captureAllScreens()
                guard !shots.isEmpty else { return }
                showOverlays(shots, windowRects: windowRects)
            } catch {
                captureLog.error("capture failed: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "無法截圖"
                alert.informativeText = "請確認已在「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許 Pinpix。\n\n(\(error.localizedDescription))"
                alert.addButton(withTitle: "打開系統設定")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { HomeWindowController.openScreenRecordingSettings() }
            }
        }
    }

    @MainActor
    private func captureAllScreens() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append((screen, image))
        }
        return result
    }

    private func showOverlays(_ shots: [(NSScreen, CGImage)], windowRects: [CGRect]) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (screen, image) in shots {
            // Quartz 全域座標（左上原點）→ 這個螢幕的本地座標（左上原點）
            let sx = screen.frame.minX, sy = primaryHeight - screen.frame.maxY
            let local = windowRects.map { $0.offsetBy(dx: -sx, dy: -sy) }
                .filter { $0.intersects(CGRect(origin: .zero, size: screen.frame.size)) }
            let w = SelectionOverlayWindow(screen: screen, image: image, windowRects: local) { [weak self] rect in
                self?.finish(screen: screen, image: image, rect: rect)
            }
            overlays.append(w)
        }
        // 選取畫面是「不啟用 App」的浮動面板：不會觸發 macOS 切換桌面，
        // 也能蓋在其他 App 的全螢幕空間上。
        for w in overlays { w.orderFrontRegardless() }
        captureLog.info("overlays shown: \(self.overlays.map { $0.isOnActiveSpace })")
        (overlays.first { $0.screen == NSScreen.screenWithMouse } ?? overlays.first)?.makeKey()
        // Esc 用全域快捷鍵攔截，不依賴鍵盤焦點
        HotKeyManager.shared.register(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, keyLabel: "Esc"),
                                      slot: .cancel) { [weak self] in self?.cancel() }
    }

    func cancel() {
        guard !overlays.isEmpty else { return }
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
        HotKeyManager.shared.unregister(.cancel)
    }

    private func finish(screen: NSScreen, image: CGImage, rect: CGRect?) {
        cancel()
        guard let rect else { return }
        let scale = CGFloat(image.width) / screen.frame.width
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = image.cropping(to: px) else { return }
        onCapture?(cropped, scale, screen)
    }

    private static func onScreenWindowRects() -> [CGRect] {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 40, r.height > 40 else { return nil }
            return r
        }
    }

    private func requestPermission() {
        // 第一次會跳出系統詢問視窗
        let asked = CGRequestScreenCaptureAccess()
        if asked { return }
        let alert = NSAlert()
        alert.messageText = "需要「螢幕錄製」權限才能截圖"
        alert.informativeText = "請到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」打開 Pinpix，然後重新啟動 Pinpix。"
        alert.addButton(withTitle: "打開系統設定")
        alert.addButton(withTitle: "稍後")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { HomeWindowController.openScreenRecordingSettings() }
    }
}

// MARK: - 選取畫面

final class SelectionOverlayWindow: NSPanel {
    init(screen: NSScreen, image: CGImage, windowRects: [CGRect], completion: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = SelectionView(image: image, windowRects: windowRects, completion: completion)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    private let image: NSImage
    private let windowRects: [CGRect]
    private let completion: (CGRect?) -> Void
    private var start: CGPoint?
    private var current: CGPoint?
    private var mouse: CGPoint?
    private var finished = false

    init(image: CGImage, windowRects: [CGRect], completion: @escaping (CGRect?) -> Void) {
        self.image = NSImage(cgImage: image, size: .zero)
        self.windowRects = windowRects
        self.completion = completion
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(p1: s, p2: c).intersection(bounds)
    }

    private var hoveredWindow: CGRect? {
        guard start == nil, let m = mouse else { return nil }
        return windowRects.first { $0.contains(m) }?.intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let highlight = selection ?? hoveredWindow
        ctx.addRect(bounds)
        if let h = highlight { ctx.addRect(h) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let sel = selection {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            drawLabel("\(Int(sel.width)) × \(Int(sel.height))", near: sel)
        } else if let h = hoveredWindow {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(h.insetBy(dx: 1.5, dy: 1.5))
            drawLabel("點一下截取這個視窗", near: h)
        }

        // 十字準線
        if start == nil, let m = mouse {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: m.y.rounded() + 0.5))
            ctx.move(to: CGPoint(x: m.x.rounded() + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: m.x.rounded() + 0.5, y: bounds.maxY))
            ctx.strokePath()
        }
    }

    private func drawLabel(_ s: String, near r: CGRect) {
        let str = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = str.size()
        var box = CGRect(x: r.minX, y: r.maxY + 6, width: size.width + 14, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = r.minY - box.height - 6 }
        if box.minY < 0 { box.origin.y = r.minY + 6; box.origin.x = r.minX + 6 }
        box.origin.x = min(max(0, box.minX), bounds.maxX - box.width)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        str.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        mouse = point(event)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = point(event)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = point(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = point(event)
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            finish(sel)
            return
        }
        // 只點一下：截取滑鼠下的視窗，沒有視窗就整個螢幕
        let p = point(event)
        start = nil
        finish(windowRects.first { $0.contains(p) }?.intersection(bounds) ?? bounds)
    }

    override func rightMouseDown(with event: NSEvent) { finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        completion(rect)
    }
}
