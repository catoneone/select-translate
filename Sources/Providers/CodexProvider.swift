import Cocoa
import ApplicationServices

// MARK: - Codex app-server 客户端（JSON-RPC over stdio）

typealias CodexEvent = LLMEvent

final class CodexTask: LLMTask {
    fileprivate var threadId: String?
    fileprivate var turnId: String?
    fileprivate(set) var cancelled = false
    fileprivate weak var client: CodexProvider?
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        client?.cancel(self)
    }
}

/// 本机 Codex：常驻 `codex app-server`，JSON-RPC over stdio
final class CodexProvider: LLMProvider {

    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextId = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var handlers: [String: (CodexEvent) -> Void] = [:]   // threadId -> handler
    private var accumulated: [String: String] = [:]
    private var ready = false
    private var starting = false
    private var readyWaiters: [(Error?) -> Void] = []

    struct Err: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    static func findCodex() -> String? {
        let fm = FileManager.default
        let custom = Settings.binaryPath(.codex)
        if !custom.isEmpty { return fm.isExecutableFile(atPath: custom) ? custom : nil }
        // 优先使用桌面版内置的新版 CLI（支持最新模型），其次是 PATH 中的 codex
        let bundled = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        if let b = bundled.first(where: { fm.isExecutableFile(atPath: $0) }) { return b }
        let home = fm.homeDirectoryForCurrentUser.path
        return findExecutable("codex", extra: ["\(home)/.codex/packages/app-server-daemon/current/bin"])
    }

    /// 读取 Codex 缓存的可用模型列表（用于设置界面的下拉建议）
    static func cachedModelSlugs() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.filter { ($0["visibility"] as? String ?? "list") == "list" }.compactMap { $0["slug"] as? String }
    }

    // 线程级系统提示词（创建线程时固定）
    private var systemPrompt = Mode.baseInstructions

    private func applyModelParams(_ p: inout [String: Any]) {
        let m = Settings.model(.codex)
        if !m.isEmpty { p["model"] = m }
        let tier = Settings.codexServiceTier
        if !tier.isEmpty { p["serviceTier"] = tier }
    }

    /// 关闭翻译用不到的插件 / MCP / 工具，加快线程启动、减少上下文
    static let extraArgs: [String] = {
        let disabled = ["apps", "plugins", "remote_plugin", "browser_use", "browser_use_external",
                        "computer_use", "memories", "image_generation", "multi_agent", "goals",
                        "hooks", "shell_tool", "shell_snapshot", "skill_search", "tool_suggest",
                        "code_mode_host", "sleep_tool"]
        var a: [String] = []
        for f in disabled { a += ["--disable", f] }
        a += ["-c", "mcp_servers={}", "-c", "notify=[]"]
        return a
    }()

    // 启动并完成 initialize 握手
    func ensureReady(_ cb: @escaping (Error?) -> Void) {
        if ready { cb(nil); return }
        readyWaiters.append(cb)
        if starting { return }
        starting = true

        guard let path = Self.findCodex() else {
            finishStart(Err(msg: "找不到 codex 可执行文件。请安装 Codex CLI 或 ChatGPT/Codex 桌面版，或在设置中指定路径"))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["app-server"] + Self.extraArgs
        p.currentDirectoryURL = Settings.workDir
        var env = childEnvironment()
        env["RUST_LOG"] = env["RUST_LOG"] ?? "warn"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let logURL = Settings.logURL("codex-app-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.processExited() }
        }
        do {
            try p.run()
        } catch {
            finishStart(Err(msg: "启动 codex 失败：\(error.localizedDescription)"))
            return
        }
        proc = p
        stdinHandle = inPipe.fileHandleForWriting

        request("initialize", ["clientInfo": ["name": "select_translate", "title": "划线翻译", "version": "1.0"]]) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success:
                self.notify("initialized", [:])
                self.ready = true
                self.finishStart(nil)
            case .failure(let e):
                self.finishStart(e)
                self.restart()
            }
        }
    }

    private func finishStart(_ e: Error?) {
        starting = false
        let ws = readyWaiters
        readyWaiters = []
        ws.forEach { $0(e) }
    }

    func restart() {
        proc?.terminationHandler = nil
        proc?.terminate()
        processExited()
    }

    func shutdown() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
    }

    private func processExited() {
        proc = nil
        stdinHandle = nil
        ready = false
        buffer = Data()
        let e = Err(msg: "codex 进程已退出，详见日志 ~/Library/Logs/\(Settings.appName)/")
        let ps = pending; pending = [:]
        ps.values.forEach { $0(.failure(e)) }
        let hs = handlers; handlers = [:]
        hs.values.forEach { $0(.failed(e.msg)) }
        pool = []
        creating = 0
        let ws = threadWaiters; threadWaiters = []
        ws.forEach { $0(nil) }
        if starting { finishStart(e) }
    }

    // MARK: 预热线程池
    // 新线程的第一轮要建立 WebSocket、预热、构建上下文（3~8 秒）；之后同一线程的每轮只需 ~1 秒。
    // 所以常驻 2 个已预热的线程轮流复用，每个线程用满 maxTurns 轮后后台换新。

    private final class WarmThread {
        let id: String
        var busy = true
        var ready = false
        var turns = 0
        init(id: String) { self.id = id }
    }
    private var pool: [WarmThread] = []
    private var creating = 0
    private var threadWaiters: [(WarmThread?) -> Void] = []
    private let poolSize = 2
    private let maxTurns = 40

    /// 启动 codex 并预热线程池
    func warmUp() {
        ensureReady { [weak self] err in
            if err == nil { self?.fillPool() }
        }
    }

    /// 等到有一个预热完成的空闲线程（自测用）
    func whenReady(_ cb: @escaping () -> Void) {
        ensureReady { [weak self] _ in
            self?.acquire { wt in
                wt?.busy = false
                cb()
            }
        }
    }

    private func fillPool() {
        while pool.count + creating < poolSize { createThread() }
    }

    private func createThread() {
        creating += 1
        var params: [String: Any] = [
            "ephemeral": true,
            "cwd": Settings.workDir.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": systemPrompt,
        ]
        applyModelParams(&params)
        request("thread/start", params) { [weak self] r in
            guard let self else { return }
            self.creating -= 1
            guard case .success(let res) = r,
                  let tid = (res["thread"] as? [String: Any])?["id"] as? String else {
                if case .failure(let e) = r { appLog("thread/start failed: \(e.localizedDescription)") }
                self.failWaitersIfNoThreads()
                return
            }
            let wt = WarmThread(id: tid)
            self.pool.append(wt)
            // 预热轮：建立连接 + 缓存系统提示词
            self.startTurn(on: wt, prompt: "（连接预热，无需处理）请只回复：OK", task: nil) { _ in }
        }
    }

    private func failWaitersIfNoThreads() {
        guard pool.isEmpty, creating == 0, !threadWaiters.isEmpty else { return }
        let ws = threadWaiters; threadWaiters = []
        ws.forEach { $0(nil) }
    }

    private func acquire(_ cb: @escaping (WarmThread?) -> Void) {
        if let wt = pool.first(where: { $0.ready && !$0.busy }) {
            wt.busy = true
            cb(wt)
            return
        }
        threadWaiters.append(cb)
        // 都在忙（或还在预热）时，额外开一个线程兜底
        if pool.filter({ !$0.busy }).isEmpty && creating == 0 && pool.count < poolSize + 1 { createThread() }
        else { fillPool() }
    }

    private func release(_ tid: String) {
        guard let i = pool.firstIndex(where: { $0.id == tid }) else { return }
        let wt = pool[i]
        wt.busy = false
        wt.ready = true
        wt.turns += 1
        if wt.turns >= maxTurns || pool.count > poolSize {
            pool.remove(at: i)
            request("thread/unsubscribe", ["threadId": tid]) { _ in }
            fillPool()
            return
        }
        if !threadWaiters.isEmpty {
            wt.busy = true
            threadWaiters.removeFirst()(wt)
        }
    }

    private func startTurn(on wt: WarmThread, prompt: String, task: CodexTask?, onEvent: @escaping (CodexEvent) -> Void) {
        wt.busy = true
        handlers[wt.id] = onEvent
        accumulated[wt.id] = ""
        task?.threadId = wt.id
        var turn: [String: Any] = [
            "threadId": wt.id,
            "effort": Settings.codexEffort,
            "input": [["type": "text", "text": prompt]],
        ]
        applyModelParams(&turn)
        request("turn/start", turn) { [weak self] r in
            guard let self else { return }
            switch r {
            case .failure(let e):
                self.finish(wt.id, .failed(e.localizedDescription))
                self.release(wt.id)
            case .success(let res):
                let turnId = (res["turn"] as? [String: Any])?["id"] as? String
                task?.turnId = turnId
                if let task, task.cancelled, let turnId {
                    self.request("turn/interrupt", ["threadId": wt.id, "turnId": turnId]) { _ in }
                }
            }
        }
    }

    // MARK: 对外：执行一次处理
    @discardableResult
    func run(system: String, prompt: String, onEvent: @escaping (LLMEvent) -> Void) -> LLMTask {
        if system != systemPrompt {
            // 系统提示词变化：丢弃空闲线程，按新提示词重建
            systemPrompt = system
            pool.removeAll(where: { !$0.busy })
        }
        let task = CodexTask()
        task.client = self
        ensureReady { [weak self] err in
            guard let self, !task.cancelled else { return }
            if let err { onEvent(.failed(err.localizedDescription)); return }
            self.acquire { wt in
                guard let wt else { onEvent(.failed("无法创建 Codex 会话，详见日志")); return }
                if task.cancelled { self.release(wt.id); return }
                self.startTurn(on: wt, prompt: prompt, task: task, onEvent: onEvent)
            }
        }
        return task
    }

    fileprivate func cancel(_ task: CodexTask) {
        guard let tid = task.threadId else { return }
        handlers[tid] = nil
        accumulated[tid] = nil
        if let turn = task.turnId {
            request("turn/interrupt", ["threadId": tid, "turnId": turn]) { _ in }
        }
        // 线程在收到 turn/completed（interrupted）后自动回到空闲
    }

    private func finish(_ tid: String, _ ev: CodexEvent) {
        guard let h = handlers.removeValue(forKey: tid) else { return }
        accumulated[tid] = nil
        h(ev)
    }

    // MARK: JSON-RPC 底层
    private func write(_ obj: [String: Any]) {
        guard let h = stdinHandle, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { NSLog("SelectTranslate write error: \(error)") }
    }

    private func request(_ method: String, _ params: [String: Any], _ cb: @escaping (Result<[String: Any], Error>) -> Void) {
        guard stdinHandle != nil else { cb(.failure(Err(msg: "codex 未运行"))); return }
        nextId += 1
        pending[nextId] = cb
        write(["id": nextId, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            if line.isEmpty { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ m: [String: Any]) {
        let method = m["method"] as? String
        if let method, let id = m["id"] {
            // 服务端发来的请求（审批等）：一律拒绝
            if method.hasSuffix("requestApproval") || method.contains("Approval") {
                write(["id": id, "result": ["decision": "decline"]])
            } else {
                write(["id": id, "error": ["code": -32601, "message": "not supported by select-translate"]])
            }
            return
        }
        if method == nil, let id = (m["id"] as? NSNumber)?.intValue {
            guard let cb = pending.removeValue(forKey: id) else { return }
            if let err = m["error"] as? [String: Any] {
                cb(.failure(Err(msg: err["message"] as? String ?? "未知错误")))
            } else {
                cb(.success(m["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        guard let method, let params = m["params"] as? [String: Any] else { return }
        let tid = params["threadId"] as? String ?? ""
        switch method {
        case "item/agentMessage/delta":
            if let d = params["delta"] as? String, let h = handlers[tid] {
                accumulated[tid, default: ""] += d
                h(.delta(d))
            }
        case "error":
            let msg = ((params["error"] as? [String: Any])?["message"] as? String) ?? "未知错误"
            if params["willRetry"] as? Bool == true {
                handlers[tid]?(.status("网络波动，重试中…"))
            } else {
                finish(tid, .failed(msg))
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "completed"
            if status == "failed" {
                let msg = ((turn["error"] as? [String: Any])?["message"] as? String) ?? "处理失败"
                finish(tid, .failed(msg))
            } else {
                var text = accumulated[tid] ?? ""
                if let items = turn["items"] as? [[String: Any]] {
                    let msgs = items.filter { $0["type"] as? String == "agentMessage" }.compactMap { $0["text"] as? String }
                    if let last = msgs.last, !last.isEmpty { text = last }
                }
                finish(tid, .done(text))
            }
            release(tid)
        default:
            break
        }
    }
}
