import Cocoa
import Security

// MARK: - 模型提供方

enum ProviderKind: String, CaseIterable {
    case codex, claudeCode, openai, anthropic

    var title: String {
        switch self {
        case .codex: return "Codex（本机）"
        case .claudeCode: return "Claude Code（本机）"
        case .openai: return "OpenAI 兼容 API"
        case .anthropic: return "Anthropic API"
        }
    }
    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .openai: return "OpenAI API"
        case .anthropic: return "Anthropic API"
        }
    }
    var defaultModel: String {
        switch self {
        case .codex: return ""                 // 空 = 使用 ~/.codex/config.toml 中的默认模型
        case .claudeCode: return "haiku"
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        default: return ""
        }
    }
    var modelSuggestions: [String] {
        switch self {
        case .codex: return CodexProvider.cachedModelSlugs()
        case .claudeCode: return ["haiku", "sonnet", "opus"]
        case .openai: return ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1", "deepseek-chat", "qwen-plus", "moonshot-v1-8k"]
        case .anthropic: return ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-1"]
        }
    }
    var isLocal: Bool { self == .codex || self == .claudeCode }
}

// MARK: - 设置

enum Settings {
    static let d = UserDefaults.standard
    static let appName = "SelectTranslate"

    static var provider: ProviderKind {
        get { ProviderKind(rawValue: d.string(forKey: "provider") ?? "") ?? .codex }
        set { d.set(newValue.rawValue, forKey: "provider") }
    }
    static var hasChosenProvider: Bool { d.string(forKey: "provider") != nil }

    static func model(_ k: ProviderKind) -> String {
        let v = d.string(forKey: "model.\(k.rawValue)") ?? k.defaultModel
        return v.trimmingCharacters(in: .whitespaces)
    }
    static func setModel(_ v: String, _ k: ProviderKind) { d.set(v, forKey: "model.\(k.rawValue)") }

    static func baseURL(_ k: ProviderKind) -> String {
        let v = (d.string(forKey: "baseURL.\(k.rawValue)") ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? k.defaultBaseURL : v
    }
    static func setBaseURL(_ v: String, _ k: ProviderKind) { d.set(v, forKey: "baseURL.\(k.rawValue)") }

    /// 自定义可执行文件路径（codex / claude），空 = 自动查找
    static func binaryPath(_ k: ProviderKind) -> String {
        (d.string(forKey: "binPath.\(k.rawValue)") ?? "").trimmingCharacters(in: .whitespaces)
    }
    static func setBinaryPath(_ v: String, _ k: ProviderKind) { d.set(v, forKey: "binPath.\(k.rawValue)") }

    /// API Key 存在钥匙串；也可用环境变量 SELECT_TRANSLATE_API_KEY 覆盖（便于命令行测试）
    static func apiKey(_ k: ProviderKind) -> String {
        if let env = ProcessInfo.processInfo.environment["SELECT_TRANSLATE_API_KEY"], !env.isEmpty { return env }
        return Keychain.get(account: k.rawValue) ?? ""
    }
    static func setAPIKey(_ v: String, _ k: ProviderKind) { Keychain.set(v, account: k.rawValue) }

    /// Codex 推理强度
    static var codexEffort: String {
        get { d.string(forKey: "codex.effort") ?? "low" }
        set { d.set(newValue, forKey: "codex.effort") }
    }
    /// Codex 速度档：""（默认）/ priority（Fast）/ ultrafast（Ultrafast，部分模型支持）
    static var codexServiceTier: String {
        get { d.string(forKey: "codex.serviceTier") ?? "" }
        set { d.set(newValue, forKey: "codex.serviceTier") }
    }

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// 结果窗底部显示的模型名
    static var currentDisplayName: String {
        let k = provider
        let m = model(k)
        return m.isEmpty ? k.shortName : m
    }

    static let supportDir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let workDir: URL = {
        let u = supportDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let logDir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func logURL(_ name: String) -> URL { logDir.appendingPathComponent(name) }
}

// MARK: - 钥匙串（保存 API Key）

enum Keychain {
    static let service = "io.github.catoneone.select-translate"

    static func get(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// 在常见位置和 PATH 中查找可执行文件
func findExecutable(_ name: String, extra: [String] = []) -> String? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var dirs = extra
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "/usr/bin"]
    dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for d in dirs {
        let p = d.hasSuffix("/" + name) ? d : (d as NSString).appendingPathComponent(name)
        if fm.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// 子进程环境：补全 PATH（从 Finder 启动时 PATH 很短，npm 安装的 CLI 需要 node）
func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin", "/bin"]
    env["PATH"] = ((env["PATH"] ?? "").split(separator: ":").map(String.init) + extra).joined(separator: ":")
    return env
}
