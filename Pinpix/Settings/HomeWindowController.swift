import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Pinpix 主面板：打開 App 時看到的畫面，可以截圖與設定
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    var onCapture: (() -> Void)?
    var onOpenImage: (() -> Void)?
    var onPaste: (() -> Void)?
    /// 回傳 false 表示快捷鍵被其他 App 佔用
    var onShortcutChanged: ((Shortcut) -> Bool)?

    static let width: CGFloat = 460

    private let captureButton = PrimaryButton()
    private let recorder = ShortcutRecorderButton()
    private let conflictRow = NSStackView()
    private let autoCopy = NSSwitch()
    private let autoSave = NSSwitch()
    private let launchAtLogin = NSSwitch()
    private let appearance = NSSegmentedControl(labels: ["系統", "淺色", "深色"], trackingMode: .selectOne, target: nil, action: nil)
    private let canvasFill = NSSegmentedControl(labels: ["白色", "黑色", "透明"], trackingMode: .selectOne, target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "前往設定", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Pinpix"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: UI

    private func build() {
        guard let window else { return }
        let root = HeroBackgroundView()
        window.contentView = root

        // 標題區
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: "Pinpix")
        name.font = .systemFont(ofSize: 28, weight: .bold)
        let tagline = NSTextField(labelWithString: "截圖 · 標註 · 直接貼上")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        let hero = NSStackView(views: [icon, name, tagline])
        hero.orientation = .vertical
        hero.spacing = 4
        hero.setCustomSpacing(10, after: icon)

        // 主要動作
        captureButton.target = self
        captureButton.action = #selector(captureClicked)
        captureButton.keyEquivalent = "\r"
        let openButton = SoftButton(title: "開啟圖片", symbol: "photo")
        openButton.target = self
        openButton.action = #selector(openClicked)
        let pasteButton = SoftButton(title: "從剪貼簿貼上", symbol: "doc.on.clipboard")
        pasteButton.target = self
        pasteButton.action = #selector(pasteClicked)
        let secondary = NSStackView(views: [openButton, pasteButton])
        secondary.distribution = .fillEqually
        secondary.spacing = 10

        // 設定
        recorder.onChange = { [weak self] s in
            let ok = self?.onShortcutChanged?(s) ?? false
            self?.refresh()
            return ok
        }
        let conflictText = NSTextField(wrappingLabelWithString: "和 macOS 內建截圖相同，請先關掉系統的這組快捷鍵。")
        conflictText.font = .systemFont(ofSize: 11)
        conflictText.textColor = .systemOrange
        conflictText.preferredMaxLayoutWidth = 270
        let conflictButton = NSButton(title: "鍵盤設定", target: self, action: #selector(openKeyboardSettings))
        conflictButton.bezelStyle = .inline
        conflictButton.controlSize = .small
        conflictRow.setViews([conflictText, conflictButton], in: .leading)
        conflictRow.spacing = 8
        conflictRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)

        for (sw, sel) in [(autoCopy, #selector(toggleAutoCopy)), (autoSave, #selector(toggleAutoSave)),
                          (launchAtLogin, #selector(toggleLaunchAtLogin))] {
            sw.controlSize = .small
            sw.target = self
            sw.action = sel
        }
        appearance.controlSize = .small
        appearance.target = self
        appearance.action = #selector(appearanceChanged)
        canvasFill.controlSize = .small
        canvasFill.target = self
        canvasFill.action = #selector(canvasFillChanged)
        canvasFill.toolTip = "標註超出截圖時，延伸出去的畫布底色" 

        let folderButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "打開資料夾")!,
                                    target: self, action: #selector(openSaveFolder))
        folderButton.isBordered = false
        folderButton.contentTintColor = .secondaryLabelColor
        folderButton.toolTip = "打開資料夾"

        permissionLabel.font = .systemFont(ofSize: 12)
        permissionButton.bezelStyle = .inline
        permissionButton.controlSize = .small
        permissionButton.target = self
        permissionButton.action = #selector(openScreenRecordingSettings)

        let general = SettingsGroup(rows: [
            SettingsGroup.row("keyboard", "截圖快捷鍵", recorder, below: conflictRow),
            SettingsGroup.row("doc.on.clipboard", "截圖後自動複製到剪貼簿", autoCopy),
            SettingsGroup.row("square.and.arrow.down", "同時存檔到「圖片 › Pinpix」", folderButton, autoSave),
            SettingsGroup.row("rectangle.expand.vertical", "延伸畫布底色", canvasFill),
        ])
        let other = SettingsGroup(rows: [
            SettingsGroup.row("circle.lefthalf.filled", "外觀", appearance),
            SettingsGroup.row("power", "登入時自動啟動", launchAtLogin),
            SettingsGroup.row("record.circle", "螢幕錄製權限", permissionLabel, permissionButton),
        ])

        let hint = NSTextField(wrappingLabelWithString: "截圖時：拖曳選取範圍　點一下截取整個視窗　Esc 取消")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        let generalTitle = sectionTitle("一般"), otherTitle = sectionTitle("其他")
        let stack = NSStackView(views: [hero, captureButton, secondary, generalTitle, general, otherTitle, other, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(24, after: hero)
        stack.setCustomSpacing(24, after: secondary)
        stack.setCustomSpacing(6, after: generalTitle)
        stack.setCustomSpacing(18, after: general)
        stack.setCustomSpacing(6, after: otherTitle)
        stack.setCustomSpacing(18, after: other)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let fullWidth: [NSView] = [captureButton, secondary, generalTitle, general, otherTitle, other, hint]
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ] + fullWidth.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func sectionTitle(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        let wrap = NSStackView(views: [l])
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        return wrap
    }

    private func refresh() {
        let s = Prefs.shortcut
        captureButton.shortcut = s.display
        recorder.shortcut = s
        conflictRow.isHidden = !s.conflictsWithSystemScreenshot
        autoCopy.state = Prefs.autoCopy ? .on : .off
        autoSave.state = Prefs.autoSave ? .on : .off
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        appearance.selectedSegment = Prefs.appearance
        canvasFill.selectedSegment = Prefs.canvasFill
        let granted = CGPreflightScreenCaptureAccess()
        permissionLabel.stringValue = granted ? "已允許" : "尚未允許"
        permissionLabel.textColor = granted ? .secondaryLabelColor : .systemOrange
        permissionButton.isHidden = granted
        fitHeight()
    }

    /// 視窗高度貼合內容
    private func fitHeight() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let h = content.fittingSize.height
        guard h > 100, abs(window.contentLayoutRect.height - h) > 1 else { return }
        var f = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: h))
        f.origin.y += f.height - newFrame.height
        f.size = newFrame.size
        window.setFrame(f, display: true)
    }

    // MARK: Actions

    @objc private func captureClicked() {
        // 先把面板收起來再截圖
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.onCapture?() }
    }

    @objc private func openClicked() { onOpenImage?() }
    @objc private func pasteClicked() { onPaste?() }
    @objc private func toggleAutoCopy() { Prefs.autoCopy = autoCopy.state == .on }
    @objc private func toggleAutoSave() { Prefs.autoSave = autoSave.state == .on }
    @objc private func appearanceChanged() { Prefs.appearance = appearance.selectedSegment }
    @objc private func canvasFillChanged() {
        Prefs.canvasFill = canvasFill.selectedSegment
        NotificationCenter.default.post(name: .pinpixCanvasFillChanged, object: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc private func openSaveFolder() {
        guard let folder = Prefs.autoSaveFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openScreenRecordingSettings() { Self.openScreenRecordingSettings() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 元件

/// 面板背景：上方一抹和 App 圖示同色系的柔光
final class HeroBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let a: CGFloat = dark ? 0.32 : 0.18
        let g = NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.36, blue: 1, alpha: a),
                                    NSColor(srgbRed: 0.62, green: 0.25, blue: 0.9, alpha: a * 0.5),
                                    NSColor(srgbRed: 0.62, green: 0.25, blue: 0.9, alpha: 0)])
        g?.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: 260), angle: 90)
    }
}

/// 主要按鈕：漸層底、白字、右側快捷鍵標籤
final class PrimaryButton: NSButton {
    var shortcut = "" { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = "截圖"
        heightAnchor.constraint(equalToConstant: 50).isActive = true
        setAccessibilityLabel("截圖")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        let g = NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 1, alpha: 1),
                                    NSColor(srgbRed: 0.55, green: 0.24, blue: 0.93, alpha: 1)])
        g?.draw(in: path, angle: 0)
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.15).setFill()
            path.fill()
        }
        let icon = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))?.tinted(.white)
        let title = NSAttributedString(string: "截圖", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let ts = title.size()
        let iconW = icon?.size.width ?? 0
        let total = iconW + 8 + ts.width
        var x = r.midX - total / 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            x += iconW + 8
        }
        title.draw(at: NSPoint(x: x, y: r.midY - ts.height / 2))

        // 快捷鍵標籤
        guard !shortcut.isEmpty else { return }
        let chip = NSAttributedString(string: shortcut, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let cs = chip.size()
        let chipRect = NSRect(x: r.maxX - cs.width - 30, y: r.midY - 12, width: cs.width + 16, height: 24)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 7, yRadius: 7).fill()
        chip.draw(at: NSPoint(x: chipRect.minX + 8, y: chipRect.midY - cs.height / 2))
    }
}

/// 次要按鈕：淡色圓角底
final class SoftButton: NSButton {
    private let symbol: String

    init(title: String, symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        self.title = title
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
        path.fill()
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))?.tinted(.labelColor)
        let t = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        let ts = t.size()
        let iconW = icon?.size.width ?? 0
        var x = r.midX - (iconW + 6 + ts.width) / 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            x += iconW + 6
        }
        t.draw(at: NSPoint(x: x, y: r.midY - ts.height / 2))
    }
}

/// 類似「系統設定」的圓角分組
final class SettingsGroup: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.groupBackground.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// 一列：左邊圖示＋文字、右邊控制項；below 為列下方的附加內容
    static func row(_ symbol: String, _ title: String, _ controls: NSView..., below: NSView? = nil) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [icon, label, spacer] + controls)
        line.spacing = 8
        line.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        guard let below else { return line }
        let v = NSStackView(views: [line, below])
        v.orientation = .vertical
        v.spacing = 0
        line.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        below.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        return v
    }
}

/// 點一下後按下新的組合鍵
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut = .defaultCapture { didSet { updateTitle() } }
    /// 回傳 false 表示註冊失敗（被佔用）
    var onChange: ((Shortcut) -> Bool)?
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(startRecording)
        toolTip = "點一下，然後按下新的組合鍵"
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = monitor == nil ? shortcut.display : "請按下組合鍵…"
    }

    @objc private func startRecording() {
        guard monitor == nil else { return stopRecording(restore: true) }
        HotKeyManager.shared.unregister(.capture)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stopRecording(restore: true); return nil }
            guard let s = Shortcut(event: event) else { NSSound.beep(); return nil }
            self.stopRecording(restore: false)
            if self.onChange?(s) == true {
                self.shortcut = s
            } else {
                _ = self.onChange?(self.shortcut)
                let alert = NSAlert()
                alert.messageText = "\(s.display) 已被其他 App 使用"
                alert.informativeText = "請換一組快捷鍵。"
                alert.runModal()
            }
            return nil
        }
        updateTitle()
    }

    private func stopRecording(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
        if restore { _ = onChange?(shortcut) }
    }
}

extension Notification.Name {
    static let pinpixCanvasFillChanged = Notification.Name("pinpixCanvasFillChanged")
}
