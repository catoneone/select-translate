import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var toolbar = Toolbar()
    private var result = ResultPanel()
    private var monitors: [Any] = []
    private var downPoint = NSPoint.zero
    private var pendingText = ""
    private var trustTimer: Timer?
    private var notice = NoticePanel()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        wireUI()
        installMonitors()
        // 切换 / 重建模型提供方时关闭结果窗，旧对话不会被发给新的提供方
        NotificationCenter.default.addObserver(forName: .providerChanged, object: nil, queue: .main) { [weak self] _ in
            self?.result.hide()
        }
        let trusted = AXIsProcessTrusted()
        appLog("launched, accessibility trusted=\(trusted), bundle=\(Bundle.main.bundlePath)")
        if trusted {
            showReadyNotice()
        } else {
            notice.show(symbol: "hand.raised.fill", tint: .systemOrange,
                        title: L("划线翻译需要「辅助功能」权限", "Select Translate needs Accessibility access"),
                        subtitle: L("用于读取你选中的文字。授权后此提示会自动消失。", "Used to read the text you select. This notice disappears once granted."),
                        action: L("去授权", "Grant"), autoHide: nil)
            checkAccessibility(prompt: true)
        }
        chooseInitialProvider()
        Providers.shared.current.warmUp()   // 启动本机 CLI / 预连接 API
    }

    private func wireUI() {
        toolbar.onPick = { [weak self] mode, p in
            guard let self else { return }
            self.result.show(text: self.pendingText, mode: mode, at: p)
        }
        notice.onAction = { [weak self] in self?.openAXSettings() }
    }

    /// 切换界面语言：重建所有界面（按钮文字在创建时确定）
    private func rebuildUI() {
        toolbar.hide(); result.hide(); notice.hide()
        settingsWindow?.close()
        toolbar = Toolbar()
        result = ResultPanel()
        notice = NoticePanel()
        settingsWindow = nil
        wireUI()
        Providers.shared.reload()   // 系统提示词随语言变化，重建会话
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
        notice.show(symbol: "@app", tint: .systemGreen,
                    title: L("划线翻译已启动", "Select Translate is running"),
                    subtitle: L("在任意应用中选中文字即可翻译 / 润色。菜单栏图标可设置或退出。", "Select text in any app to translate, polish or explain. Use the menu bar icon for settings."),
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
            b.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: L("划线翻译", "Select Translate"))
            b.image?.isTemplate = true
            if b.image == nil { b.title = "译" }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: L("划线翻译", "Select Translate") + " · \(Settings.provider.shortName) · \(Settings.currentDisplayName)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !AXIsProcessTrusted() {
            menu.addItem(item(L("⚠️ 需要辅助功能权限，点此打开设置…", "⚠️ Accessibility access required — open Settings…"), #selector(openAXSettings)))
        }
        menu.addItem(.separator())
        let en = item(L("启用划词", "Enable Selection Popup"), #selector(toggleEnabled))
        en.state = Settings.enabled ? .on : .off
        menu.addItem(en)
        let login = item(L("开机自动启动", "Launch at Login"), #selector(toggleLaunchAtLogin))
        switch LoginItem.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed; login.toolTip = L("需要在系统设置中允许", "Needs approval in System Settings")
        default: login.state = .off
        }
        menu.addItem(login)

        let provItem = NSMenuItem(title: L("模型提供方", "Model Provider"), action: nil, keyEquivalent: "")
        let provMenu = NSMenu()
        for k in ProviderKind.allCases {
            let it = item(k.title, #selector(setProvider(_:)))
            it.representedObject = k.rawValue
            it.state = Settings.provider == k ? .on : .off
            provMenu.addItem(it)
        }
        provItem.submenu = provMenu
        menu.addItem(provItem)
        let langItem = NSMenuItem(title: L("界面语言", "Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in UILanguage.allCases {
            let it = item(lang.menuTitle, #selector(setLanguage(_:)))
            it.representedObject = lang.rawValue
            it.state = L10n.setting == lang ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(item(L("设置…", "Settings…"), #selector(openSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item(L("重新连接", "Reconnect"), #selector(reconnect)))
        menu.addItem(item(L("打开日志文件夹", "Open Logs Folder"), #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item(L("退出", "Quit"), #selector(quit), key: "q"))
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
    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.show()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.toggle()
        } catch {
            appLog("launch at login error: \(error)")
            let a = NSAlert()
            a.messageText = L("无法设置开机自动启动", "Couldn't change Launch at Login")
            a.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        if LoginItem.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func setLanguage(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String, let lang = UILanguage(rawValue: v), lang != L10n.setting else { return }
        L10n.setting = lang
        rebuildUI()
        appLog("ui language: \(lang.rawValue) → english=\(L10n.isEnglish)")
    }
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
