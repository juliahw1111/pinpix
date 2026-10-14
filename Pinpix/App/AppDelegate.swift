import AppKit
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let editor = EditorWindowController()
    private let capturer = ScreenCapturer()
    private let home = HomeWindowController()
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 開機自動啟動時不要跳出面板
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.applyAppearance()
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()

        capturer.onCapture = { [weak self] image, scale, screen in
            self?.editor.open(image: image, pixelScale: scale, on: screen)
        }
        home.onCapture = { [weak self] in self?.capture(nil) }
        home.onOpenImage = { [weak self] in self?.openDocument(nil) }
        home.onPaste = { [weak self] in self?.openFromClipboard(nil) }
        home.onShortcutChanged = { [weak self] shortcut in
            guard self?.registerCaptureHotKey(shortcut) == true else { return false }
            Prefs.shortcut = shortcut
            self?.rebuildStatusMenu()
            return true
        }

        let ok = registerCaptureHotKey(Prefs.shortcut)
        if !launchedAsLoginItem || !ok { home.show() }
        if !Prefs.hasLaunchedBefore {
            Prefs.hasLaunchedBefore = true
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        }
    }

    private func registerCaptureHotKey(_ s: Shortcut) -> Bool {
        HotKeyManager.shared.register(s, slot: .capture) { [weak self] in self?.capture(nil) }
    }

    /// 點 Dock 圖示或再次從「應用程式」打開
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { home.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 選單列圖示

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Pinpix")
        image?.isTemplate = true
        statusItem.button?.image = image
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "截圖  \(Prefs.shortcut.display)", action: #selector(capture(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "顯示上一張截圖", action: #selector(showEditor(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打開 Pinpix 面板…", action: #selector(showHome(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "結束 Pinpix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    // MARK: 主選單

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "關於 Pinpix", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "設定…", action: #selector(showHome(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隱藏 Pinpix", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "結束 Pinpix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(appMenu, title: "Pinpix"))

        let file = NSMenu()
        file.addItem(withTitle: "截圖", action: #selector(capture(_:)), keyEquivalent: "n").target = self
        file.addItem(withTitle: "開啟圖片…", action: #selector(openDocument(_:)), keyEquivalent: "o").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "另存新檔…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        main.addItem(submenu(file, title: "檔案"))

        let edit = NSMenu()
        edit.addItem(withTitle: "復原", action: #selector(EditorWindowController.undoEdit(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: #selector(EditorWindowController.redoEdit(_:)), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "刪除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "調整截圖大小…", action: #selector(EditorWindowController.resizeImage(_:)), keyEquivalent: "")
        main.addItem(submenu(edit, title: "編輯"))

        let window = NSMenu()
        window.addItem(withTitle: "縮到最小", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Pinpix 面板", action: #selector(showHome(_:)), keyEquivalent: "0").target = self
        main.addItem(submenu(window, title: "視窗"))
        NSApp.windowsMenu = window
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    // MARK: Actions

    @objc func capture(_ sender: Any?) { capturer.start() }
    @objc func showHome(_ sender: Any?) { home.show() }

    @objc func showEditor(_ sender: Any?) {
        if editor.editorDoc == nil { home.show() } else { editor.show() }
    }

    @objc func openFromClipboard(_ sender: Any?) {
        guard let (img, scale) = NSPasteboard.general.pinpixImage() else {
            let alert = NSAlert()
            alert.messageText = "剪貼簿裡沒有圖片"
            alert.informativeText = "按 \(Prefs.shortcut.display) 開始截圖。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        editor.open(image: img, pixelScale: scale, on: NSScreen.screenWithMouse)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        // 依 DPI 判斷是否為 Retina 截圖
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
        editor.open(image: img, pixelScale: max(1, (dpi / 72).rounded()), on: NSScreen.screenWithMouse)
    }
}
