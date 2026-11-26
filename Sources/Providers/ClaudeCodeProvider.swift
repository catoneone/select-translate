import Cocoa

/// 本机 Claude Code CLI：`claude --print --input-format stream-json --output-format stream-json`
///
/// CLI 每次冷启动需要 1~2 秒，所以始终预先启动一个「备用进程」等待输入；
/// 请求到来时直接把消息写给备用进程，同时在后台再准备下一个。
final class ClaudeCodeProvider: LLMProvider {

    private final class Session {
        let process = Process()
        var stdin: FileHandle?
        var buffer = Data()
        var stderrTail = ""
        var handler: ((LLMEvent) -> Void)?
        var accumulated = ""
        var lastAssistant = ""
        var finished = false
        let system: String
        let model: String
        init(system: String, model: String) { self.system = system; self.model = model }
    }

    private var spare: Session?
    private var active: [ObjectIdentifier: Session] = [:]

    struct Err: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    static func findClaude() -> String? {
        let fm = FileManager.default
        let custom = Settings.binaryPath(.claudeCode)
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? custom : nil }
        let home = fm.homeDirectoryForCurrentUser.path
        return findExecutable("claude", extra: ["\(home)/.claude/local", "\(home)/.npm-global/bin"])
    }

    static func arguments(system: String, model: String) -> [String] {
        var a = ["--print", "--verbose",
                 "--input-format", "stream-json",
                 "--output-format", "stream-json",
                 "--include-partial-messages",
                 "--no-session-persistence",
                 "--strict-mcp-config",          // 不加载 MCP 服务器，加快启动
                 "--disable-slash-commands",
                 "--tools", "",                  // 不提供任何工具：纯文本问答
                 "--system-prompt", system]
        if !model.isEmpty { a += ["--model", model] }
        return a
    }

    // MARK: LLMProvider

    func warmUp() { prepareSpare(system: Mode.baseInstructions) }

    func whenReady(_ cb: @escaping () -> Void) {
        prepareSpare(system: Mode.baseInstructions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: cb)
    }

    @discardableResult
    func run(system: String, prompt: String, session: UUID?, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        // 每个请求都是独立进程（--no-session-persistence），天然不跨会话共享上下文
        let task = BasicTask()
        let model = Settings.model(.claudeCode)
        var s: Session
        if let sp = spare, sp.process.isRunning, sp.system == system, sp.model == model {
            s = sp
        } else {
            spare.map(kill)
            do { s = try spawn(system: system, model: model) } catch {
                onEvent(.failed(error.localizedDescription))
                return task
            }
        }
        spare = nil
        active[ObjectIdentifier(s)] = s
        s.handler = onEvent
        task.onCancel = { [weak self, weak s] in
            guard let self, let s else { return }
            s.handler = nil
            self.kill(s)
        }
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
        ]
        if var data = try? JSONSerialization.data(withJSONObject: msg) {
            data.append(0x0A)
            do { try s.stdin?.write(contentsOf: data) } catch {
                finish(s, .failed(L("无法写入 Claude Code：", "Cannot write to Claude Code: ") + error.localizedDescription))
            }
        }
        // 为下一次请求准备备用进程
        DispatchQueue.main.async { [weak self] in
            self?.prepareSpare(system: system)
        }
        return task
    }

    func shutdown() {
        spare.map(kill)
        spare = nil
        active.values.forEach(kill)
        active = [:]
    }

    // MARK: 进程管理

    private func prepareSpare(system: String) {
        let model = Settings.model(.claudeCode)
        if let sp = spare, sp.process.isRunning, sp.system == system, sp.model == model { return }
        spare.map(kill)
        spare = try? spawn(system: system, model: model)
    }

    private func spawn(system: String, model: String) throws -> Session {
        guard let path = Self.findClaude() else {
            throw Err(msg: L("找不到 claude 可执行文件。请先安装 Claude Code（npm i -g @anthropic-ai/claude-code）并登录，或在设置中指定路径", "claude executable not found. Install Claude Code (npm i -g @anthropic-ai/claude-code) and sign in, or set its path in Settings."))
        }
        let s = Session(system: system, model: model)
        let p = s.process
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = Self.arguments(system: system, model: model)
        p.currentDirectoryURL = Settings.workDir
        p.environment = childEnvironment()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak s] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { if let s { self?.ingest(s, d) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak s] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let str = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async {
                guard let s else { return }
                s.stderrTail = String((s.stderrTail + str).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self, weak s] proc in
            DispatchQueue.main.async {
                guard let self, let s else { return }
                if self.spare === s { self.spare = nil }
                if !s.finished {
                    let tail = s.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finish(s, .failed(L("Claude Code 已退出", "Claude Code exited") + " (\(proc.terminationStatus))" + (tail.isEmpty ? "" : ": \(tail.suffix(300))")))
                }
                self.active[ObjectIdentifier(s)] = nil
            }
        }
        try p.run()
        s.stdin = inPipe.fileHandleForWriting
        return s
    }

    private func kill(_ s: Session) {
        s.finished = true
        try? s.stdin?.close()
        if s.process.isRunning { s.process.terminate() }
        active[ObjectIdentifier(s)] = nil
    }

    private func finish(_ s: Session, _ ev: LLMEvent) {
        guard !s.finished else { return }
        s.finished = true
        let h = s.handler
        s.handler = nil
        h?(ev)
        try? s.stdin?.close()   // 关闭输入，CLI 处理完即退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if s.process.isRunning { s.process.terminate() } }
    }

    // MARK: 解析 stream-json 输出

    private func ingest(_ s: Session, _ data: Data) {
        s.buffer.append(data)
        while let nl = s.buffer.firstIndex(of: 0x0A) {
            let line = s.buffer.subdata(in: s.buffer.startIndex..<nl)
            s.buffer = s.buffer.subdata(in: s.buffer.index(after: nl)..<s.buffer.endIndex)
            guard !line.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(s, obj)
        }
    }

    private func handle(_ s: Session, _ m: [String: Any]) {
        switch m["type"] as? String {
        case "stream_event":
            guard let ev = m["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            s.accumulated += text
            s.handler?(.delta(text))
        case "assistant":
            // 完整消息（与增量重复），仅作兜底
            if let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { s.lastAssistant = text }
            }
        case "result":
            let isError = (m["is_error"] as? Bool) == true || (m["subtype"] as? String).map { $0 != "success" } == true
            let result = m["result"] as? String ?? ""
            if isError {
                finish(s, .failed(result.isEmpty ? (m["subtype"] as? String ?? L("未知错误", "Unknown error")) : result))
            } else {
                let full = !result.isEmpty ? result : (!s.lastAssistant.isEmpty ? s.lastAssistant : s.accumulated)
                finish(s, .done(full))
            }
        default:
            break
        }
    }
}
