import Cocoa

/// 设置窗口：选择模型提供方，配置模型 / Base URL / API Key / 程序路径
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let providerPopup = NSPopUpButton()
    private let grid = NSGridView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let testLabel = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "保存并测试", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)

    private let modelBox = NSComboBox()
    private let baseField = NSTextField()
    private let keyField = NSSecureTextField()
    private let pathField = NSTextField()
    private let tierPopup = NSPopUpButton()
    private let effortPopup = NSPopUpButton()

    private var editingKind: ProviderKind = Settings.provider
    private var testTask: LLMTask?
    private let W: CGFloat = 540

    override init() {
        super.init()
        build()
    }

    func show() {
        editingKind = Settings.provider
        providerPopup.selectItem(at: ProviderKind.allCases.firstIndex(of: editingKind) ?? 0)
        reloadFields()
        setTest("")
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: 界面
    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "划线翻译 · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        providerPopup.addItems(withTitles: ProviderKind.allCases.map { $0.title })
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        for f in [baseField, keyField, pathField] { f.lineBreakMode = .byTruncatingMiddle; f.usesSingleLineMode = true }
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 12
        tierPopup.addItems(withTitles: ["默认", "Fast（priority）", "Ultrafast（部分模型支持）"])
        effortPopup.addItems(withTitles: ["low（最快，推荐）", "medium", "high"])

        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .secondaryLabelColor
        testLabel.font = .systemFont(ofSize: 12)
        testLabel.textColor = .secondaryLabelColor
        testLabel.maximumNumberOfLines = 4

        grid.rowSpacing = 10
        grid.columnSpacing = 10
        for v in [providerPopup, modelBox, baseField, keyField, pathField, tierPopup, effortPopup] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }

        testButton.target = self
        testButton.action = #selector(saveAndTest)
        testButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [testButton, NSView(), saveButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [grid, hintLabel, testLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
            buttons.widthAnchor.constraint(equalToConstant: W - 48),
            hintLabel.widthAnchor.constraint(equalToConstant: W - 48),
            testLabel.widthAnchor.constraint(equalToConstant: W - 48),
        ])
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func reloadFields() {
        let k = editingKind
        // 清空旧行：NSGridView.removeRow 不会移除单元格里的视图，需要手动移除
        for r in (0..<grid.numberOfRows).reversed() {
            let row = grid.row(at: r)
            for c in 0..<row.numberOfCells { row.cell(at: c).contentView?.removeFromSuperview() }
            grid.removeRow(at: r)
        }

        func addRow(_ title: String, _ v: NSView) {
            let r = grid.addRow(with: [label(title), v])
            r.yPlacement = .center
        }
        addRow("提供方", providerPopup)

        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: k.modelSuggestions)
        modelBox.stringValue = Settings.d.string(forKey: "model.\(k.rawValue)") ?? k.defaultModel

        switch k {
        case .codex:
            modelBox.placeholderString = "留空 = 使用 Codex 配置中的默认模型"
            addRow("模型", modelBox)
            tierPopup.selectItem(at: ["", "priority", "ultrafast"].firstIndex(of: Settings.codexServiceTier) ?? 0)
            addRow("速度档", tierPopup)
            effortPopup.selectItem(at: ["low", "medium", "high"].firstIndex(of: Settings.codexEffort) ?? 0)
            addRow("推理强度", effortPopup)
            pathField.stringValue = Settings.binaryPath(.codex)
            pathField.placeholderString = CodexProvider.findCodex().map { "自动：\($0)" } ?? "未找到 codex，请填写路径"
            addRow("程序路径", pathField)
            hintLabel.stringValue = "使用本机 Codex 登录的账号，无需 API Key。应用会常驻 codex app-server 并预热会话，翻译通常 1~2 秒出结果。小模型（如 *-luna / *-mini）更快。"
        case .claudeCode:
            modelBox.placeholderString = "haiku / sonnet / opus 或完整模型名"
            addRow("模型", modelBox)
            pathField.stringValue = Settings.binaryPath(.claudeCode)
            pathField.placeholderString = ClaudeCodeProvider.findClaude().map { "自动：\($0)" } ?? "未找到 claude，请填写路径"
            addRow("程序路径", pathField)
            hintLabel.stringValue = "使用本机 Claude Code 登录的账号（npm i -g @anthropic-ai/claude-code，并先在终端运行一次 claude 完成登录）。会预先启动一个备用进程以减少等待。"
        case .openai, .anthropic:
            baseField.stringValue = Settings.d.string(forKey: "baseURL.\(k.rawValue)") ?? ""
            baseField.placeholderString = k.defaultBaseURL
            addRow("Base URL", baseField)
            keyField.stringValue = Settings.apiKey(k)
            keyField.placeholderString = k == .openai ? "sk-…（本地 Ollama 等可留空）" : "sk-ant-…"
            addRow("API Key", keyField)
            modelBox.placeholderString = k.defaultModel
            addRow("模型", modelBox)
            hintLabel.stringValue = k == .openai
                ? "兼容 OpenAI Chat Completions 接口的服务均可：OpenAI、DeepSeek（https://api.deepseek.com）、Moonshot、通义千问、OpenRouter、本地 Ollama（http://localhost:11434/v1）等。API Key 保存在系统钥匙串中。"
                : "Anthropic Messages API，也可填写兼容的代理地址。API Key 保存在系统钥匙串中。"
        }
        grid.column(at: 0).xPlacement = .trailing
        window.layoutIfNeeded()
        let fit = window.contentView!.fittingSize
        var f = window.frame
        let newH = fit.height + (f.height - window.contentLayoutRect.height)
        f.origin.y += f.height - newH
        f.size.height = newH
        window.setFrame(f, display: true, animate: window.isVisible)
    }

    private func setTest(_ s: String, color: NSColor = .secondaryLabelColor) {
        testLabel.stringValue = s
        testLabel.textColor = color
        testLabel.isHidden = s.isEmpty
    }

    // MARK: 动作
    @objc private func providerChanged() {
        editingKind = ProviderKind.allCases[providerPopup.indexOfSelectedItem]
        setTest("")
        reloadFields()
    }

    private func save() {
        let k = editingKind
        Settings.setModel(modelBox.stringValue.trimmingCharacters(in: .whitespaces), k)
        switch k {
        case .codex:
            Settings.codexServiceTier = ["", "priority", "ultrafast"][max(0, tierPopup.indexOfSelectedItem)]
            Settings.codexEffort = ["low", "medium", "high"][max(0, effortPopup.indexOfSelectedItem)]
            Settings.setBinaryPath(pathField.stringValue, .codex)
        case .claudeCode:
            Settings.setBinaryPath(pathField.stringValue, .claudeCode)
        case .openai, .anthropic:
            Settings.setBaseURL(baseField.stringValue, k)
            Settings.setAPIKey(keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), k)
        }
        Settings.provider = k
        Providers.shared.reload()
        appLog("settings saved: provider=\(k.rawValue) model=\(Settings.model(k))")
    }

    @objc private func saveTapped() {
        save()
        window.close()
    }

    @objc private func saveAndTest() {
        save()
        testTask?.cancel()
        setTest("测试中…（本机 CLI 首次启动可能需要几秒）")
        testButton.isEnabled = false
        let t0 = Date()
        var acc = ""
        testTask = Providers.shared.run(prompt: Mode.zh.prompt(for: "Hello! This is a connection test.")) { [weak self] ev in
            guard let self else { return }
            switch ev {
            case .delta(let d):
                acc += d
            case .status(let s):
                self.setTest(s)
            case .done(let full):
                let text = (full.isEmpty ? acc : full).trimmingCharacters(in: .whitespacesAndNewlines)
                self.setTest(String(format: "✓ 连接成功（%.1f 秒）：", Date().timeIntervalSince(t0)) + text, color: .systemGreen)
                self.testButton.isEnabled = true
            case .failed(let msg):
                self.setTest("✗ 失败：" + msg, color: .systemRed)
                self.testButton.isEnabled = true
            }
        }
    }

    /// 离屏渲染用：显示指定提供方的设置项并返回窗口
    func debugWindow(for k: ProviderKind) -> NSWindow {
        editingKind = k
        providerPopup.selectItem(at: ProviderKind.allCases.firstIndex(of: k) ?? 0)
        reloadFields()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        testTask?.cancel()
        testButton.isEnabled = true
    }
}
