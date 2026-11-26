import Cocoa

// MARK: - 统一的大模型提供方接口

enum LLMEvent {
    case delta(String)      // 流式增量文本
    case status(String)     // 状态提示（如重试中）
    case done(String)       // 完成，附完整文本（可为空，则使用累计的增量）
    case failed(String)     // 失败
}

protocol LLMTask: AnyObject {
    func cancel()
}

protocol LLMProvider: AnyObject {
    /// 预热（启动常驻进程 / 建立连接），可选
    func warmUp()
    /// 执行一次请求：system 为系统提示词，prompt 为用户消息；回调总在主线程。
    /// session 标识「一段划选文字」的会话：有状态的提供方（Codex）据此隔离上下文，nil 表示一次性请求。
    @discardableResult
    func run(system: String, prompt: String, session: UUID?, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask
    /// 会话结束（弹窗关闭 / 划选新文字），释放与之相关的上下文
    func endSession(_ session: UUID)
    /// 释放资源（切换提供方或退出时）
    func shutdown()
    /// 自测用：等到可以立即处理请求
    func whenReady(_ cb: @escaping () -> Void)
}

extension LLMProvider {
    func warmUp() {}
    func endSession(_ session: UUID) {}
    func shutdown() {}
    func whenReady(_ cb: @escaping () -> Void) { cb() }
}

/// 简单的可取消任务
final class BasicTask: LLMTask {
    private(set) var cancelled = false
    var onCancel: (() -> Void)?
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onCancel?()
        onCancel = nil
    }
}

// MARK: - 当前提供方

extension Notification.Name {
    /// 模型提供方被切换或重建（旧会话应当失效）
    static let providerChanged = Notification.Name("SelectTranslate.providerChanged")
}

final class Providers {
    static let shared = Providers()
    private(set) var kind: ProviderKind = Settings.provider
    private var instance: LLMProvider?
    /// 每次切换 / 重建提供方都会递增；结果窗用它判断自己的会话是否仍属于当前提供方
    private(set) var generation = 0

    var current: LLMProvider {
        if let i = instance, kind == Settings.provider { return i }
        if instance != nil { generation += 1; NotificationCenter.default.post(name: .providerChanged, object: nil) }
        instance?.shutdown()
        kind = Settings.provider
        let p = Self.make(kind)
        instance = p
        return p
    }

    static func make(_ k: ProviderKind) -> LLMProvider {
        switch k {
        case .codex: return CodexProvider()
        case .claudeCode: return ClaudeCodeProvider()
        case .openai: return OpenAICompatibleProvider()
        case .anthropic: return AnthropicProvider()
        }
    }

    /// 设置变化后调用：重建提供方并预热
    func reload() {
        instance?.shutdown()
        instance = nil
        generation += 1
        NotificationCenter.default.post(name: .providerChanged, object: nil)
        current.warmUp()
    }

    func shutdown() {
        instance?.shutdown()
        instance = nil
    }

    @discardableResult
    func run(prompt: String, session: UUID? = nil, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        current.run(system: Mode.baseInstructions, prompt: prompt, session: session, onEvent: onEvent)
    }

    func endSession(_ session: UUID) { instance?.endSession(session) }
}
