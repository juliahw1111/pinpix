import AppKit
import UniformTypeIdentifiers

/// 唯一的編輯視窗：每次截圖都重用，並一定出現在目前螢幕、目前桌面的最上層。
/// 版面：畫布滿版；左側浮動工具列；底部浮動動作列（拖曳／複製／儲存）。
final class EditorWindowController: NSWindowController, NSWindowDelegate, CanvasViewDelegate, NSMenuItemValidation {
    static let presetColors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.20, blue: 0.17, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.82, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.75, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.30, blue: 0.87, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.22, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]

    /// 左側工具列上的工具（選取不需要工具：直接點物件即可）
    static let paletteTools: [Tool] = [.arrow, .text, .shape, .pen, .mosaic, .crop]

    private let canvas = CanvasView()
    private(set) var editorDoc: EditorDocument?

    private var tool: Tool = Prefs.lastTool == .select ? .arrow : Prefs.lastTool {
        didSet { Prefs.lastTool = tool; canvas.tool = tool; syncUI() }
    }

    private var toolButtons: [Tool: PaletteButton] = [:]
    private let colorButton = StyleDotButton()
    private let sizeButton = SizeButton()
    private let colorPopover = NSPopover()
    private let sizePopover = NSPopover()
    private let colorVC = ColorPickerController()
    private let sizeVC = SizePickerController()

    private let actionBar = FloatingBar()
    private let normalActions = NSStackView()
    private let cropActions = NSStackView()
    private let dragOut = DragOutView()
    private let dimensionButton = NSButton(title: "", target: nil, action: nil)
    private let cropWidthField = NSTextField()
    private let cropHeightField = NSTextField()
    private let toast = FloatingBar()
    private let toastLabel = NSTextField(labelWithString: "")

    private var outputWork: DispatchWorkItem?
    private var autosaveURL: URL?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Pinpix"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        // 可以出現在目前的桌面，包含其他 App 的全螢幕空間
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.backgroundColor = Theme.background
        super.init(window: window)
        window.delegate = self
        canvas.delegate = self
        canvas.tool = tool
        buildUI()
        syncUI()
        NotificationCenter.default.addObserver(forName: .pinpixCanvasFillChanged, object: nil, queue: .main) { [weak self] _ in
            self?.canvas.needsDisplay = true
            if self?.editorDoc != nil { self?.documentChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 開啟圖片

    func open(image: CGImage, pixelScale: CGFloat, on screen: NSScreen?) {
        flushOutputs()
        closePopovers()
        let doc = EditorDocument(image: image, pixelScale: pixelScale)
        doc.onChange = { [weak self] in self?.documentChanged() }
        editorDoc = doc
        autosaveURL = nil
        canvas.document = doc
        updateDimension()
        fitWindow(on: screen ?? NSScreen.screenWithMouse ?? NSScreen.main)
        show()
        if Prefs.autoCopy {
            doc.copyToPasteboard()
            showToast("已複製到剪貼簿")
        }
        if Prefs.autoSave { autosave() }
    }

    func show() {
        guard let window else { return }
        // 先把視窗放到目前的桌面最上層，再啟用 App（順序相反會被 macOS 拉回別的桌面）
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        captureLog.info("editor shown: onActiveSpace=\(window.isOnActiveSpace) key=\(window.isKeyWindow)")
    }

    private func fitWindow(on screen: NSScreen?) {
        guard let window, let screen, let doc = editorDoc else { return }
        let vis = screen.visibleFrame
        let i = canvas.contentInsets
        let img = doc.contentBounds.size
        let w = min(max(img.width + i.left + i.right, window.minSize.width), vis.width * 0.94)
        let h = min(max(img.height + i.top + i.bottom, window.minSize.height), vis.height * 0.94)
        let frame = NSRect(x: vis.midX - w / 2, y: vis.midY - h / 2, width: w, height: h)
        window.setFrame(frame.integral, display: true)
    }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)

        // 左側工具列
        let palette = FloatingBar()
        let toolStack = NSStackView()
        toolStack.orientation = .vertical
        toolStack.spacing = 4
        toolStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 6)
        for t in Self.paletteTools {
            let b = PaletteButton(symbol: t.symbol, tip: t.title)
            b.hasVariants = t == .shape || t == .text
            b.target = self
            b.action = #selector(paletteToolClicked(_:))
            b.tag = t.rawValue
            toolButtons[t] = b
            toolStack.addArrangedSubview(b)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 26).isActive = true
        toolStack.addArrangedSubview(divider)
        colorButton.target = self
        colorButton.action = #selector(toggleColorPicker)
        colorButton.toolTip = "顏色"
        sizeButton.target = self
        sizeButton.action = #selector(toggleSizePicker)
        sizeButton.toolTip = "粗細／大小"
        toolStack.addArrangedSubview(colorButton)
        toolStack.addArrangedSubview(sizeButton)
        palette.embed(toolStack)

        // 顏色、粗細面板（收起來，點了才出現；選完自動收起）
        colorVC.onColor = { [weak self] c in self?.setColor(c); self?.colorPopover.close() }
        sizeVC.onSize = { [weak self] v in self?.setSize(v); self?.sizePopover.close() }
        for (pop, vc) in [(colorPopover, colorVC as NSViewController), (sizePopover, sizeVC)] {
            pop.contentViewController = vc
            pop.behavior = .transient
            pop.animates = true
        }

        // 視窗上緣：拖曳這裡可以移動視窗
        let dragStrip = WindowDragStrip()
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dragStrip)
        NSLayoutConstraint.activate([
            dragStrip.topAnchor.constraint(equalTo: content.topAnchor),
            dragStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 34),
        ])

        // 底部動作列
        dragOut.imageProvider = { [weak self] in self?.editorDoc }
        normalActions.setViews([
            dragOut, barDivider(),
            barButton("doc.on.doc", "複製", #selector(copy(_:)), tip: "複製到剪貼簿 (⌘C)"),
            barButton("square.and.arrow.down", "儲存", #selector(saveDocumentAs(_:)), tip: "另存新檔 (⌘S)"),
        ], in: .leading)
        for f in [cropWidthField, cropHeightField] {
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.controlSize = .small
            f.bezelStyle = .roundedBezel
            f.target = self
            f.action = #selector(cropSizeEntered)
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            f.toolTip = "輸入像素，按 Enter"
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let cropSize = NSStackView(views: [cropWidthField, times, cropHeightField])
        cropSize.spacing = 4
        cropSize.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        cropActions.setViews([
            cropSize, barDivider(),
            barButton("xmark", "取消", #selector(cancelCrop(_:)), tip: "取消裁切 (Esc)"),
            barButton("checkmark", "套用", #selector(applyCrop(_:)), tip: "套用裁切 (Enter)", prominent: true),
        ], in: .leading)
        for s in [normalActions, cropActions] {
            s.spacing = 2
            s.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        }
        cropActions.isHidden = true
        let actionStack = NSStackView(views: [normalActions, cropActions])
        actionBar.embed(actionStack)

        // 左下角尺寸（點了可以調整大小）
        dimensionButton.isBordered = false
        dimensionButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensionButton.contentTintColor = .secondaryLabelColor
        dimensionButton.target = self
        dimensionButton.action = #selector(resizeImage(_:))
        dimensionButton.toolTip = "調整截圖大小"

        // 提示訊息
        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
        check.contentTintColor = .systemGreen
        let toastStack = NSStackView(views: [check, toastLabel])
        toastStack.spacing = 6
        toastStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
        toast.embed(toastStack)
        toast.alphaValue = 0

        for v in [palette, actionBar, dimensionButton, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            palette.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            palette.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 4),
            palette.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 36),

            actionBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            dimensionButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            dimensionButton.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toast.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
        ])
    }

    private func barButton(_ symbol: String, _ title: String, _ action: Selector, tip: String, prominent: Bool = false) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                         target: self, action: action)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.toolTip = tip
        if prominent {
            b.bezelStyle = .push
            b.keyEquivalent = "\r"
        } else {
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 20).isActive = true
        }
        return b
    }

    private func barDivider() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    /// 選取物件時，樣式顯示該物件的；否則顯示目前工具的
    private var styleTool: Tool { canvas.selected?.tool ?? tool }

    private func syncUI() {
        for (t, b) in toolButtons { b.isActive = t == tool }
        toolButtons[.shape]?.symbol = Self.shapeSymbol(currentShapeKindForUI)

        let st = styleTool
        let color = canvas.selected?.color ?? Prefs.color
        let size = canvas.selected?.size ?? Prefs.size(for: st)
        colorButton.color = color
        sizeButton.configure(tool: st, size: size)
        for b in [colorButton, sizeButton] as [NSButton] {
            b.isEnabled = st.hasStyle
            b.alphaValue = st.hasStyle ? 1 : 0.35
        }
        colorVC.configure(color: color)
        sizeVC.configure(tool: st, color: color, size: size)
        if !st.hasStyle { closePopovers() }
    }

    private var currentShapeKindForUI: ShapeKind {
        if case let .shape(k, _) = canvas.selected?.kind { return k }
        if case .line = canvas.selected?.kind { return .line }
        return Prefs.shapeKind
    }

    static func shapeSymbol(_ k: ShapeKind) -> String {
        switch k {
        case .rect: return "rectangle"
        case .roundedRect: return "app"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        }
    }

    private func updateDimension() {
        guard let doc = editorDoc else { return }
        let px = doc.pixelSize
        dimensionButton.title = "\(Int(px.width)) × \(Int(px.height))"
    }

    private func showToast(_ s: String) {
        toastLabel.stringValue = s
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; toast.animator().alphaValue = 1 }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideToast), object: nil)
        perform(#selector(hideToast), with: nil, afterDelay: 1.8)
    }

    @objc private func hideToast() {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.4; toast.animator().alphaValue = 0 }
    }

    // MARK: 工具 / 樣式

    @objc private func paletteToolClicked(_ sender: PaletteButton) {
        guard let t = Tool(rawValue: sender.tag) else { return }
        // 已選中的圖形／文字工具再點一次：跳出種類選單
        if t == tool && (t == .shape || t == .text) {
            showVariantMenu(for: t, from: sender)
            return
        }
        tool = t
    }

    private func showVariantMenu(for t: Tool, from button: NSView) {
        let menu = NSMenu()
        if t == .shape {
            for k in ShapeKind.allCases {
                let item = NSMenuItem(title: ["矩形", "圓角矩形", "橢圓", "直線"][k.rawValue], action: #selector(variantPicked(_:)), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: Self.shapeSymbol(k), accessibilityDescription: nil)
                item.tag = k.rawValue
                item.state = currentShapeKindForUI == k ? .on : .off
                item.target = self
                menu.addItem(item)
            }
        } else {
            var current = Prefs.textStyle
            if case let .text(_, _, st) = canvas.selected?.kind { current = st }
            for st in TextStyle.allCases {
                let item = NSMenuItem(title: ["描邊", "醒目", "一般"][st.rawValue], action: #selector(variantPicked(_:)), keyEquivalent: "")
                item.tag = 100 + st.rawValue
                item.state = current == st ? .on : .off
                item.target = self
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.maxX + 6, y: button.bounds.maxY), in: button)
    }

    @objc private func variantPicked(_ item: NSMenuItem) {
        if item.tag >= 100 {
            TextStyle(rawValue: item.tag - 100).map(setTextStyle)
        } else {
            ShapeKind(rawValue: item.tag).map(setShape)
        }
    }

    private func closePopovers() {
        colorPopover.close()
        sizePopover.close()
    }

    @objc private func toggleColorPicker() {
        if colorPopover.isShown { colorPopover.close(); return }
        closePopovers()
        syncUI()
        colorPopover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxX)
    }

    @objc private func toggleSizePicker() {
        if sizePopover.isShown { sizePopover.close(); return }
        closePopovers()
        syncUI()
        sizePopover.show(relativeTo: sizeButton.bounds, of: sizeButton, preferredEdge: .maxX)
    }

    private var editingSelection: Bool { canvas.selected != nil || canvas.isEditingText }

    private func setColor(_ c: NSColor) {
        if editingSelection { canvas.applyStyleToSelection(color: c) }
        Prefs.color = c
        syncUI()
        canvas.refreshCursor()
    }

    private func setSize(_ v: CGFloat) {
        Prefs.setSize(v, for: styleTool)
        if editingSelection { canvas.applyStyleToSelection(size: v) }
        syncUI()
    }

    private func setShape(_ k: ShapeKind) {
        switch canvas.selected?.kind {
        case .shape?, .line?: canvas.applyStyleToSelection(shape: k)
        default: Prefs.shapeKind = k
        }
        syncUI()
        canvas.refreshCursor()
    }

    private func setTextStyle(_ s: TextStyle) {
        if case .text = canvas.selected?.kind { canvas.applyStyleToSelection(textStyle: s) } else { Prefs.textStyle = s }
        syncUI()
    }

    // MARK: CanvasViewDelegate

    func currentStyle(for tool: Tool) -> (color: NSColor, size: CGFloat) { (Prefs.color, Prefs.size(for: tool)) }
    var currentShapeKind: ShapeKind { Prefs.shapeKind }
    var currentTextStyle: TextStyle { Prefs.textStyle }
    func canvasSelectionChanged(_ annotation: Annotation?) { syncUI() }
    func canvasRequestsTool(_ tool: Tool) { if tool != .select { self.tool = tool } }
    func canvasDidChange() { updateDimension() }
    func canvasShowMessage(_ message: String) { showToast(message) }

    func canvasCropSizeChanged(_ pixelSize: CGSize) {
        cropWidthField.integerValue = Int(pixelSize.width)
        cropHeightField.integerValue = Int(pixelSize.height)
    }

    @objc private func cropSizeEntered() {
        canvas.setCropPixelSize(width: cropWidthField.integerValue, height: cropHeightField.integerValue)
        window?.makeFirstResponder(canvas)
    }

    func canvasCropChanged(active: Bool) {
        normalActions.isHidden = active
        cropActions.isHidden = !active
    }

    // MARK: 剪貼簿 / 存檔

    private func documentChanged() {
        outputWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeOutputs() }
        outputWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeOutputs() {
        outputWork = nil
        if Prefs.autoCopy { editorDoc?.copyToPasteboard() }
        if Prefs.autoSave { autosave() }
    }

    private func flushOutputs() {
        if outputWork != nil { outputWork?.cancel(); writeOutputs() }
    }

    private func autosave() {
        guard let doc = editorDoc, let folder = Prefs.autoSaveFolder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = autosaveURL ?? folder.appendingPathComponent(Self.defaultFileName())
            autosaveURL = url
            try doc.pngData()?.write(to: url)
        } catch {
            showToast("自動存檔失敗")
        }
    }

    static func defaultFileName(ext: String = "png") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Pinpix \(f.string(from: Date())).\(ext)"
    }

    @objc func copy(_ sender: Any?) {
        guard let doc = editorDoc else { return }
        doc.copyToPasteboard()
        showToast("已複製到剪貼簿")
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = editorDoc, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = Self.defaultFileName()
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            var data: Data?
            if isJPEG, let img = doc.render(background: Prefs.canvasFillColor ?? .white) {
                let rep = NSBitmapImageRep(cgImage: img)
                rep.size = doc.contentBounds.size
                data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            } else {
                data = doc.pngData()
            }
            do {
                try data?.write(to: url)
                self?.showToast("已儲存 \(url.lastPathComponent)")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) { saveDocumentAs(sender) }

    @objc func paste(_ sender: Any?) {
        guard let (img, scale) = NSPasteboard.general.pinpixImage() else { NSSound.beep(); return }
        open(image: img, pixelScale: scale, on: window?.screen)
    }

    @objc func undoEdit(_ sender: Any?) {
        guard let doc = editorDoc, !canvas.isEditingText else { return }
        doc.undo()
        canvas.refreshAfterUndo()
        updateDimension()
    }

    @objc func redoEdit(_ sender: Any?) {
        guard let doc = editorDoc, !canvas.isEditingText else { return }
        doc.redo()
        canvas.refreshAfterUndo()
        updateDimension()
    }

    @objc func delete(_ sender: Any?) { canvas.deleteSelection() }
    @objc func applyCrop(_ sender: Any?) { canvas.applyCrop(); updateDimension() }
    @objc func cancelCrop(_ sender: Any?) { canvas.cancelCrop() }

    @objc func resizeImage(_ sender: Any?) {
        guard let doc = editorDoc, let window else { return }
        let alert = NSAlert()
        alert.messageText = "調整截圖大小"
        alert.informativeText = "標註會一起等比例縮放。"
        alert.addButton(withTitle: "套用")
        alert.addButton(withTitle: "取消")
        let px = doc.imagePixelSize
        let resizer = ResizeAccessory(width: Int(px.width), height: Int(px.height))
        alert.accessoryView = resizer
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            doc.resize(toPixelWidth: resizer.widthValue, height: resizer.heightValue)
            self?.canvas.refreshAfterUndo()
            self?.updateDimension()
        }
        alert.window.initialFirstResponder = resizer.widthField
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEdit(_:)): return editorDoc?.canUndo == true
        case #selector(redoEdit(_:)): return editorDoc?.canRedo == true
        case #selector(copy(_:)), #selector(saveDocumentAs(_:)), #selector(saveDocument(_:)), #selector(resizeImage(_:)):
            return editorDoc != nil
        case #selector(delete(_:)): return canvas.selected != nil
        default: return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        closePopovers()
        flushOutputs()
    }
}

// MARK: - 浮動面板

/// 半透明圓角浮動列
final class FloatingBar: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // 拖曳浮動列的空白處可以移動視窗
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    func embed(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// 工具列按鈕：選中時有底色
final class PaletteButton: NSButton {
    var isActive = false { didSet { needsDisplay = true } }
    var symbol: String { didSet { needsDisplay = true } }
    /// 右下角小三角形：代表可以選種類
    var hasVariants = false

    init(symbol: String, tip: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        isBordered = false
        title = ""
        toolTip = tip
        setAccessibilityLabel(tip)
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let r = NSRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2,
                       width: img.size.width, height: img.size.height)
        img.tinted(isActive ? .white : .labelColor).draw(in: r)
        if hasVariants {
            let tri = NSBezierPath()
            // 按鈕座標是上下翻轉的：右下角 = maxY
            tri.move(to: NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4))
            tri.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 10))
            tri.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.maxY - 4))
            tri.close()
            (isActive ? NSColor.white : NSColor.secondaryLabelColor).setFill()
            tri.fill()
        }
    }
}

/// 色點：顯示目前顏色，點了展開樣式面板
final class StyleDotButton: NSButton {
    var color: NSColor = .red { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 8, dy: 8)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// 粗細按鈕：圓圈中一條斜線，線的粗細代表目前大小（同 Skitch）
final class SizeButton: NSButton {
    private var tool: Tool = .arrow
    private var size: CGFloat = 4

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(tool: Tool, size: CGFloat) {
        self.tool = tool
        self.size = size
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 8, dy: 8)
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 1.5
        ring.stroke()
        if tool == .text {
            let t = NSAttributedString(string: "\(Int(size.rounded()))", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ])
            let ts = t.size()
            t.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2))
            return
        }
        // 依預設粗細的級距畫斜線
        let presets = tool.sizePresets
        let level = presets.lastIndex { $0 <= size + 0.01 } ?? 0
        let line = NSBezierPath()
        line.move(to: NSPoint(x: r.minX + 3, y: r.minY + 3))
        line.line(to: NSPoint(x: r.maxX - 3, y: r.maxY - 3))
        line.lineWidth = 1.5 + CGFloat(level) * 1.4
        line.lineCapStyle = .round
        NSColor.labelColor.setStroke()
        line.stroke()
    }
}

/// 顏色面板
final class ColorPickerController: NSViewController {
    var onColor: ((NSColor) -> Void)?
    private var swatches: [ColorSwatchButton] = []
    private let colorWell = NSColorWell(style: .minimal)

    override func loadView() {
        // 兩排色點（第二排最後是自訂顏色）
        let rows = [NSStackView(), NSStackView()]
        for (i, c) in EditorWindowController.presetColors.enumerated() {
            let b = ColorSwatchButton(color: c)
            b.target = self
            b.action = #selector(swatchClicked(_:))
            swatches.append(b)
            rows[i < 5 ? 0 : 1].addArrangedSubview(b)
        }
        colorWell.target = self
        colorWell.action = #selector(wellChanged)
        colorWell.toolTip = "其他顏色"
        colorWell.widthAnchor.constraint(equalToConstant: 26).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        rows[1].addArrangedSubview(colorWell)
        for r in rows { r.spacing = 6 }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        grid.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = grid
    }

    func configure(color: NSColor) {
        _ = view
        for s in swatches { s.isSelectedSwatch = s.color.isClose(to: color) }
        colorWell.color = color
    }

    @objc private func swatchClicked(_ b: ColorSwatchButton) { onColor?(b.color) }
    @objc private func wellChanged() { onColor?(colorWell.color) }
}

/// 粗細面板：依工具列出五種大小的實際樣子
final class SizePickerController: NSViewController {
    var onSize: ((CGFloat) -> Void)?
    private let stack = NSStackView()
    private var tool: Tool = .arrow
    private var color: NSColor = .red
    private var size: CGFloat = 4

    override func loadView() {
        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view = stack
    }

    func configure(tool: Tool, color: NSColor, size: CGFloat) {
        _ = view
        self.tool = tool
        self.color = color
        self.size = size
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let presets = tool.sizePresets
        // 最接近目前大小的那一個標為選取
        let nearest = presets.enumerated().min { abs($0.element - size) < abs($1.element - size) }?.offset
        for (i, v) in presets.enumerated() {
            let row = SizeRowButton(tool: tool, value: v, color: color, selected: i == nearest)
            row.target = self
            row.action = #selector(rowClicked(_:))
            stack.addArrangedSubview(row)
        }
    }

    @objc private func rowClicked(_ row: SizeRowButton) { onSize?(row.value) }
}

final class SizeRowButton: NSButton {
    let value: CGFloat
    private let tool: Tool
    private let color: NSColor
    private let selectedRow: Bool

    init(tool: Tool, value: CGFloat, color: NSColor, selected: Bool) {
        self.tool = tool
        self.value = value
        self.color = color
        self.selectedRow = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 34))
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: tool == .text ? 40 : 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if selectedRow || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(selectedRow ? 0.18 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let sample = NSRect(x: 12, y: 0, width: bounds.width - 52, height: bounds.height)
        switch tool {
        case .text:
            let t = NSAttributedString(string: "Aa", attributes: [
                .font: NSFont.systemFont(ofSize: min(30, 9 + value * 0.32), weight: .bold), .foregroundColor: color,
            ])
            let ts = t.size()
            t.draw(at: NSPoint(x: sample.minX, y: bounds.midY - ts.height / 2))
        case .mosaic:
            let cell = max(3, value * 0.45)
            var x = sample.minX
            var i = 0
            while x < sample.maxX - cell {
                for row in 0..<2 {
                    NSColor(white: (i + row) % 2 == 0 ? 0.45 : 0.75, alpha: 1).setFill()
                    NSRect(x: x, y: bounds.midY - cell + CGFloat(row) * cell, width: cell, height: cell).fill()
                }
                x += cell
                i += 1
            }
        default:
            let line = NSBezierPath()
            line.move(to: NSPoint(x: sample.minX, y: bounds.midY))
            line.line(to: NSPoint(x: sample.maxX, y: bounds.midY))
            line.lineWidth = min(value, 20)
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
        let label = NSAttributedString(string: "\(Int(value))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let ls = label.size()
        label.draw(at: NSPoint(x: bounds.maxX - ls.width - 10, y: bounds.midY - ls.height / 2))
    }
}

/// 視窗上緣的拖曳區：按住可以移動視窗，雙擊放大／還原
final class WindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

final class ColorSwatchButton: NSButton {
    let color: NSColor
    var isSelectedSwatch = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        isBordered = false
        title = ""
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if isSelectedSwatch {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// 「拖曳」：直接把標註好的圖拖到其他 App 或 Finder
final class DragOutView: NSView, NSDraggingSource {
    var imageProvider: (() -> EditorDocument?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "按住拖曳到其他 App 或桌面"
        let icon = NSImageView(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖曳")!)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: "拖曳")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard let doc = imageProvider?(), let png = doc.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(EditorWindowController.defaultFileName())
        do { try png.write(to: url) } catch { return }

        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(png, forType: .png)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let thumb = NSImage(data: png) ?? NSImage()
        let s = doc.imageSize
        let scale = min(1, 160 / max(s.width, s.height))
        let p = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - s.width * scale / 2, y: p.y - s.height * scale / 2,
                                         width: s.width * scale, height: s.height * scale), contents: thumb)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

final class ResizeAccessory: NSView, NSTextFieldDelegate {
    let widthField = NSTextField()
    let heightField = NSTextField()
    private let keepRatio = NSButton(checkboxWithTitle: "維持比例", target: nil, action: nil)
    private let ratio: Double

    init(width: Int, height: Int) {
        ratio = Double(width) / Double(max(1, height))
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        widthField.integerValue = width
        heightField.integerValue = height
        keepRatio.state = .on
        for f in [widthField, heightField] {
            f.delegate = self
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let row = NSStackView(views: [NSTextField(labelWithString: "寬"), widthField, NSTextField(labelWithString: "高"),
                                      heightField, NSTextField(labelWithString: "px")])
        let stack = NSStackView(views: [row, keepRatio])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = bounds
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    var widthValue: Int { max(1, widthField.integerValue) }
    var heightValue: Int { max(1, heightField.integerValue) }

    func controlTextDidChange(_ obj: Notification) {
        guard keepRatio.state == .on, let f = obj.object as? NSTextField else { return }
        if f === widthField { heightField.integerValue = Int((Double(widthField.integerValue) / ratio).rounded()) }
        else { widthField.integerValue = Int((Double(heightField.integerValue) * ratio).rounded()) }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension NSPasteboard {
    /// 從剪貼簿讀圖，並推算 Retina 倍率
    func pinpixImage() -> (CGImage, CGFloat)? {
        guard let image = NSImage(pasteboard: self) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let scale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        return (cg, max(1, scale.rounded()))
    }
}
