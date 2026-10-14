import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey…)
    var modifiers: UInt32
    var keyLabel: String

    static let defaultCapture = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "2")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// 是否和 macOS 內建截圖（⇧⌘3／4／5／6，含 ⌃ 版本）相同
    var conflictsWithSystemScreenshot: Bool {
        let keys = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6].map(UInt32.init)
        let m = modifiers & ~UInt32(controlKey)
        return keys.contains(keyCode) && m == UInt32(cmdKey | shiftKey)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        // 至少要有 ⌘ ⌥ ⌃ 其中一個，避免搶走一般打字
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        let special: [UInt16: String] = [
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        ]
        let label = special[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, keyLabel: label.isEmpty ? "#\(event.keyCode)" : label)
    }
}

enum Theme {
    /// 視窗底色：淺色模式為純白，深色模式為深灰
    static let background = NSColor(name: "PinpixBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1) : .white
    }

    /// 設定分組的底色
    static let groupBackground = NSColor(name: "PinpixGroup") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.975, alpha: 1)
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static var shortcut: Shortcut {
        get {
            guard let data = d.data(forKey: "shortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) else {
                return .defaultCapture
            }
            return s
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    /// 截圖與標註後，自動把結果放進剪貼簿（預設開）
    static var autoCopy: Bool {
        get { d.object(forKey: "autoCopy") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoCopy") }
    }

    /// 自動存檔到「圖片/Pinpix」（預設關）
    static var autoSave: Bool {
        get { d.bool(forKey: "autoSave") }
        set { d.set(newValue, forKey: "autoSave") }
    }

    /// 延伸畫布的底色：0 白色（預設）、1 黑色、2 透明
    static var canvasFill: Int {
        get { d.integer(forKey: "canvasFill") }
        set { d.set(newValue, forKey: "canvasFill") }
    }

    static var canvasFillColor: NSColor? {
        switch canvasFill {
        case 1: return .black
        case 2: return nil
        default: return .white
        }
    }

    /// 外觀：0 跟隨系統、1 淺色、2 深色
    static var appearance: Int {
        get { d.integer(forKey: "appearance") }
        set { d.set(newValue, forKey: "appearance"); applyAppearance() }
    }

    static func applyAppearance() {
        switch appearance {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var hasLaunchedBefore: Bool {
        get { d.bool(forKey: "hasLaunchedBefore") }
        set { d.set(newValue, forKey: "hasLaunchedBefore") }
    }

    static var lastTool: Tool {
        get { Tool(rawValue: d.object(forKey: "lastTool") as? Int ?? Tool.arrow.rawValue) ?? .arrow }
        set { d.set(newValue.rawValue, forKey: "lastTool") }
    }

    static var shapeKind: ShapeKind {
        get { ShapeKind(rawValue: d.integer(forKey: "shapeKind")) ?? .rect }
        set { d.set(newValue.rawValue, forKey: "shapeKind") }
    }

    static var textStyle: TextStyle {
        get { TextStyle(rawValue: d.integer(forKey: "textStyle")) ?? .outline }
        set { d.set(newValue.rawValue, forKey: "textStyle") }
    }

    static var color: NSColor {
        get {
            guard let a = d.array(forKey: "color") as? [Double], a.count == 4 else {
                return EditorWindowController.presetColors[0]
            }
            return NSColor(srgbRed: a[0], green: a[1], blue: a[2], alpha: a[3])
        }
        set {
            guard let c = newValue.usingColorSpace(.sRGB) else { return }
            d.set([c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init), forKey: "color")
        }
    }

    static func size(for tool: Tool) -> CGFloat {
        let v = d.double(forKey: "size.\(tool.rawValue)")
        return CGFloat(v > 0 ? v : tool.sizeRange.initial)
    }

    static func setSize(_ v: CGFloat, for tool: Tool) {
        d.set(Double(v), forKey: "size.\(tool.rawValue)")
    }

    /// 使用者真正的「圖片」資料夾（沙盒內 FileManager 會回傳容器路徑，所以用 getpwuid）
    static var autoSaveFolder: URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Pictures/Pinpix", isDirectory: true)
    }
}
