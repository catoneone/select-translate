import Foundation

// MARK: - 通用 SSE 流式请求

private final class StreamTask: LLMTask {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
}

/// 解析一条 SSE data 的结果
private struct SSEParse {
    var delta: String? = nil
    var done = false
    var error: String? = nil
}

private func streamSSE(_ req: URLRequest,
                       onEvent: @escaping (LLMEvent) -> Void,
                       parse: @escaping (_ event: String?, _ data: String) -> SSEParse) -> LLMTask {
    let st = StreamTask()
    st.task = Task {
        func emit(_ e: LLMEvent) async { await MainActor.run { onEvent(e) } }
        var acc = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                var body = ""
                for try await line in bytes.lines { body += line + "\n"; if body.count > 8000 { break } }
                await emit(.failed("HTTP \(code)：\(apiErrorMessage(body))"))
                return
            }
            var eventName: String?
            for try await line in bytes.lines {
                if Task.isCancelled { return }
                if line.hasPrefix("event:") {
                    eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let r = parse(eventName, data)
                if let e = r.error { await emit(.failed(e)); return }
                if let d = r.delta, !d.isEmpty { acc += d; await emit(.delta(d)) }
                if r.done { break }
            }
            if !Task.isCancelled { await emit(.done(acc)) }
        } catch {
            if !Task.isCancelled { await emit(.failed(error.localizedDescription)) }
        }
    }
    return st
}

/// 从错误响应体中提取可读信息
private func apiErrorMessage(_ body: String) -> String {
    if let d = body.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        if let m = obj["message"] as? String { return m }
    }
    let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? L("无响应内容", "Empty response") : String(t.prefix(300))
}

private func jsonObject(_ s: String) -> [String: Any]? {
    guard let d = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

private func endpoint(_ base: String, suffix: String, alt: [(String, String)] = []) -> URL? {
    var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while b.hasSuffix("/") { b.removeLast() }
    if b.hasSuffix(suffix) { return URL(string: b) }
    for (end, add) in alt where b.hasSuffix(end) { return URL(string: b + add) }
    return URL(string: b + suffix)
}

/// 预先建立 TLS 连接（URLSession 会复用），降低首个请求延迟
private func preconnect(_ url: URL?) {
    guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    comps.path = "/"
    comps.query = nil
    guard let u = comps.url else { return }
    var r = URLRequest(url: u)
    r.httpMethod = "HEAD"
    r.timeoutInterval = 10
    URLSession.shared.dataTask(with: r) { _, _, _ in }.resume()
}

// MARK: - OpenAI 兼容（OpenAI / DeepSeek / Moonshot / 通义 / OpenRouter / Ollama 等）

final class OpenAICompatibleProvider: LLMProvider {
    private var url: URL? { endpoint(Settings.baseURL(.openai), suffix: "/chat/completions") }

    func warmUp() { preconnect(url) }

    @discardableResult
    func run(system: String, prompt: String, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        guard let url else { onEvent(.failed(L("Base URL 无效", "Invalid Base URL"))); return BasicTask() }
        let model = Settings.model(.openai)
        guard !model.isEmpty else { onEvent(.failed(L("请先在设置中填写模型名称", "Please set a model name in Settings"))); return BasicTask() }
        let key = Settings.apiKey(.openai)
        if key.isEmpty && url.host?.contains("openai.com") == true {
            onEvent(.failed(L("请先在设置中填写 API Key", "Please set an API key in Settings"))); return BasicTask()
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return streamSSE(req, onEvent: onEvent) { _, data in
            if data == "[DONE]" { return SSEParse(done: true) }
            guard let obj = jsonObject(data) else { return SSEParse() }
            if let e = obj["error"] as? [String: Any] { return SSEParse(error: e["message"] as? String ?? L("未知错误", "Unknown error")) }
            let choice = (obj["choices"] as? [[String: Any]])?.first
            let delta = (choice?["delta"] as? [String: Any])?["content"] as? String
            return SSEParse(delta: delta)
        }
    }
}

// MARK: - Anthropic Messages API

final class AnthropicProvider: LLMProvider {
    private var url: URL? {
        endpoint(Settings.baseURL(.anthropic), suffix: "/v1/messages", alt: [("/v1", "/messages")])
    }

    func warmUp() { preconnect(url) }

    @discardableResult
    func run(system: String, prompt: String, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        guard let url else { onEvent(.failed(L("Base URL 无效", "Invalid Base URL"))); return BasicTask() }
        let model = Settings.model(.anthropic)
        guard !model.isEmpty else { onEvent(.failed(L("请先在设置中填写模型名称", "Please set a model name in Settings"))); return BasicTask() }
        let key = Settings.apiKey(.anthropic)
        guard !key.isEmpty else { onEvent(.failed(L("请先在设置中填写 API Key", "Please set an API key in Settings"))); return BasicTask() }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return streamSSE(req, onEvent: onEvent) { event, data in
            guard let obj = jsonObject(data) else { return SSEParse() }
            let type = (obj["type"] as? String) ?? event ?? ""
            switch type {
            case "content_block_delta":
                let d = obj["delta"] as? [String: Any]
                return SSEParse(delta: d?["type"] as? String == "text_delta" ? d?["text"] as? String : nil)
            case "message_stop":
                return SSEParse(done: true)
            case "error":
                let e = obj["error"] as? [String: Any]
                return SSEParse(error: e?["message"] as? String ?? L("未知错误", "Unknown error"))
            default:
                return SSEParse()
            }
        }
    }
}
