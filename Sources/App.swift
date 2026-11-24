import Cocoa
import ApplicationServices

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let toolbar = Toolbar()
    private let result = ResultPanel()
    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    private var pendingText = ""
    private var trustTimer: Timer?
    private let notice = NoticePanel()
    private lazy var settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        toolbar.onPick = { [weak self] mode, p in
            guard let self else { return }
            self.result.show(text: self.pendingText, mode: mode, at: p)
        }
        installMonitors()
        notice.onAction = { [weak self] in self?.openAXSettings() }
        let trusted = AXIsProcessTrusted()
        appLog("launched, accessibility trusted=\(trusted), bundle=\(Bundle.main.bundlePath)")
        if trusted {
            showReadyNotice()
        } else {
            notice.show(symbol: "hand.raised.fill", tint: .systemOrange,
                        title: "划线翻译需要「辅助功能」权限",
                        subtitle: "用于读取你选中的文字。授权后此提示会自动消失。",
                        action: "去授权", autoHide: nil)
            checkAccessibility(prompt: true)
        }
        chooseInitialProvider()
        Providers.shared.current.warmUp()   // 启动本机 CLI / 预连接 API
    }

    /// 首次启动：自动选择可用的本机提供方；都没有则打开设置
    private func chooseInitialProvider() {
        guard !Settings.hasChosenProvider else { return }
        if CodexProvider.findCodex() != nil {
            Settings.provider = .codex
        } else if ClaudeCodeProvider.findClaude() != nil {
            Settings.provider = .claudeCode
        } else {
            Settings.provider = .openai
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openSettings() }
        }
        appLog("initial provider: \(Settings.provider.rawValue)")
    }

    private func showReadyNotice() {
        notice.show(symbol: "checkmark.circle.fill", tint: .systemGreen,
                    title: "划线翻译已启动",
                    subtitle: "在任意应用中选中文字即可翻译 / 润色。菜单栏图标可设置或退出。",
                    action: nil, autoHide: 4)
    }

    func applicationWillTerminate(_ n: Notification) {
        Providers.shared.shutdown()
    }

    // MARK: 辅助功能权限
    private func checkAccessibility(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { return }
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() {
                t.invalidate()
                appLog("accessibility granted")
                self?.installMonitors()   // 授权后重新挂载（键盘监听需要权限）
                self?.showReadyNotice()
            }
        }
    }

    // MARK: 全局鼠标 / 键盘监听
    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            guard let self else { return }
            self.downPoint = NSEvent.mouseLocation
            self.toolbar.hide()
            self.result.hideIfNotPinned()
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            self?.mouseUp(e)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel], handler: { [weak self] e in
            guard let self else { return }
            self.toolbar.hide()
            if e.type == .keyDown && e.keyCode == 53 { self.result.hide() }   // Esc
        }) { monitors.append(m) }

        // 结果窗口获得焦点时，Esc 也能关闭
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 && (self.result.panel.isKeyWindow || NSApp.keyWindow == nil) {
                self.result.hide(); return nil
            }
            // 菜单栏应用没有「编辑」菜单，⌘C / ⌘V 等需要自己处理
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = e.charactersIgnoringModifiers?.lowercased()
            let editingField = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
            if editingField && flags.contains(.command) {
                // 在输入框里（追问框 / 设置窗口）：⌘X/C/V/A/Z 交给输入框
                let sel: Selector?
                switch (key, flags.contains(.shift)) {
                case ("x", false): sel = #selector(NSText.cut(_:))
                case ("c", false): sel = #selector(NSText.copy(_:))
                case ("v", false): sel = #selector(NSText.paste(_:))
                case ("a", false): sel = #selector(NSText.selectAll(_:))
                case ("z", false): sel = Selector(("undo:"))
                case ("z", true): sel = Selector(("redo:"))
                default: sel = nil
                }
                if let sel { NSApp.sendAction(sel, to: nil, from: nil); return nil }
                return e
            }
            if flags == .command && self.result.panel.isKeyWindow {
                switch key {
                case "c": self.result.handleCopyShortcut(); return nil
                case "a": self.result.handleSelectAll(); return nil
                default: break
                }
            }
            return e
        }) { monitors.append(m) }
    }

    private func mouseUp(_ e: NSEvent) {
        guard Settings.enabled else { return }
        let up = NSEvent.mouseLocation
        let dist = hypot(up.x - downPoint.x, up.y - downPoint.y)
        let isSelectGesture = dist > 6 || e.clickCount >= 2 || e.modifierFlags.contains(.shift)
        guard isSelectGesture else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            SelectionReader.read { text in
                guard let self, let text else { return }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                self.pendingText = String(t.prefix(8000))
                self.toolbar.show(at: up)
            }
        }
    }

    // MARK: 菜单栏
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "划线翻译")
            b.image?.isTemplate = true
            if b.image == nil { b.title = "译" }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "划线翻译 · \(Settings.provider.shortName) · \(Settings.currentDisplayName)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠️ 需要辅助功能权限，点此打开设置…", #selector(openAXSettings)))
        }
        menu.addItem(.separator())
        let en = item("启用划词", #selector(toggleEnabled))
        en.state = Settings.enabled ? .on : .off
        menu.addItem(en)

        let provItem = NSMenuItem(title: "模型提供方", action: nil, keyEquivalent: "")
        let provMenu = NSMenu()
        for k in ProviderKind.allCases {
            let it = item(k.title, #selector(setProvider(_:)))
            it.representedObject = k.rawValue
            it.state = Settings.provider == k ? .on : .off
            provMenu.addItem(it)
        }
        provItem.submenu = provMenu
        menu.addItem(provItem)
        menu.addItem(item("设置…", #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item("重新连接", #selector(reconnect)))
        menu.addItem(item("打开日志文件夹", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ t: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() { Settings.enabled.toggle(); if !Settings.enabled { toolbar.hide() } }
    @objc private func setProvider(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String, let k = ProviderKind(rawValue: v) else { return }
        Settings.provider = k
        Providers.shared.reload()
    }
    @objc func openSettings() { settingsWindow.show() }
    @objc private func reconnect() { Providers.shared.reload() }
    @objc private func openLog() { NSWorkspace.shared.open(Settings.logDir) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAXSettings() {
        checkAccessibility(prompt: true)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
}
