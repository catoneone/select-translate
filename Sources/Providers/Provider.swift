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
    /// 执行一次请求：system 为系统提示词，prompt 为用户消息；回调总在主线程
    @discardableResult
    func run(system: String, prompt: String, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask
    /// 释放资源（切换提供方或退出时）
    func shutdown()
    /// 自测用：等到可以立即处理请求
    func whenReady(_ cb: @escaping () -> Void)
}

extension LLMProvider {
    func warmUp() {}
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

final class Providers {
    static let shared = Providers()
    private(set) var kind: ProviderKind = Settings.provider
    private var instance: LLMProvider?

    var current: LLMProvider {
        if let i = instance, kind == Settings.provider { return i }
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
        current.warmUp()
    }

    func shutdown() {
        instance?.shutdown()
        instance = nil
    }

    @discardableResult
    func run(prompt: String, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        current.run(system: Mode.baseInstructions, prompt: prompt, onEvent: onEvent)
    }
}
