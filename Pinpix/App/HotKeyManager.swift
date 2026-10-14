import AppKit
import Carbon.HIToolbox

/// 全域快捷鍵（Carbon RegisterEventHotKey：不需要「輔助使用」權限，可在沙盒內使用）
final class HotKeyManager {
    static let shared = HotKeyManager()

    enum Slot: UInt32 {
        case capture = 1
        /// 截圖選取時暫時註冊的 Esc，確保不論鍵盤焦點在哪都能取消
        case cancel = 2
    }

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var handlers: [Slot: () -> Void] = [:]
    private var handlerInstalled = false

    /// 註冊成功回傳 true；false 代表已被其他 App 佔用
    @discardableResult
    func register(_ s: Shortcut, slot: Slot = .capture, handler: (() -> Void)? = nil) -> Bool {
        unregister(slot)
        installHandlerIfNeeded()
        if let handler { handlers[slot] = handler }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5049_5850), id: slot.rawValue) // "PIXP"
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot] = ref }
        return status == noErr
    }

    func unregister(_ slot: Slot = .capture) {
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                if let slot = Slot(rawValue: id.id) { HotKeyManager.shared.handlers[slot]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
