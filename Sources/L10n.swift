import Foundation

// MARK: - 界面语言（中文 / English）

enum UILanguage: String, CaseIterable {
    case auto, zh, en
    var menuTitle: String {
        switch self {
        case .auto: return L("跟随系统", "System Default")
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum L10n {
    static var setting: UILanguage {
        get { UILanguage(rawValue: UserDefaults.standard.string(forKey: "uiLanguage") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "uiLanguage") }
    }
    /// 是否使用英文界面：自动模式下，系统首选语言不是中文即用英文
    /// 离屏渲染等场景临时指定语言（不写入设置）
    static var override: UILanguage?

    static var isEnglish: Bool {
        switch override ?? setting {
        case .zh: return false
        case .en: return true
        case .auto: return !(Locale.preferredLanguages.first ?? "zh").lowercased().hasPrefix("zh")
        }
    }
}

/// 按当前界面语言返回中文或英文文案
func L(_ zh: String, _ en: String) -> String { L10n.isEnglish ? en : zh }
