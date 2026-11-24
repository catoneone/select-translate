import Cocoa
import ApplicationServices

// MARK: - 读取选中文本

enum SelectionReader {
    static func read(_ completion: @escaping (String?) -> Void) {
        if let s = axSelectedText(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(s); return
        }
        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if ["com.apple.finder", Bundle.main.bundleIdentifier ?? "-"].contains(bid) { completion(nil); return }
        copyViaPasteboard(completion)
    }

    static func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return sel as? String
    }

    /// 回退方案：模拟 ⌘C 读取剪贴板，然后恢复原剪贴板内容
    static func copyViaPasteboard(_ completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postCmdC()
        // 轮询剪贴板变化：有些应用（Chrome/Electron/微信）响应 ⌘C 较慢。
        // 0.6 秒内拿到就弹工具条；即使更晚才写入，也在 1.5 秒内把用户原剪贴板恢复回去，避免被污染。
        var elapsed = 0.0
        var delivered = false
        func poll() {
            if pb.changeCount != before {
                let s = pb.string(forType: .string)
                restore(pb, saved)
                if !delivered { delivered = true; completion(s) }
                return
            }
            elapsed += 0.03
            if elapsed >= 0.6 && !delivered { delivered = true; completion(nil) }
            if elapsed < 1.5 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }

    private static func postCmdC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let kC: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: src, virtualKey: kC, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: kC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let objs: [NSPasteboardItem] = items.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        if !objs.isEmpty { pb.writeObjects(objs) }
    }
}
