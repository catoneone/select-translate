// 划线翻译 Select Translate — 入口与命令行自测
import Cocoa
import ApplicationServices

// MARK: - 命令行自测：SelectTranslate --selftest [文本] [模式]

let selftestSession = UUID()   // 同一段文字的多个模式共用一个会话（与界面行为一致）

func runSelfTest(_ args: [String]) {
    let text = args.count > 2 ? args[2] : "Large language models are transforming how people read and write across languages."
    // 可选第 3 个参数：只测某个模式，例如 --selftest "文本" 解释
    let only = args.count > 3 ? Mode.allCases.filter { $0.title == args[3] } : []
    var modes = (only.isEmpty ? Mode.allCases + Mode.allCases : only)[...]
    func next() {
        guard let m = modes.popFirst() else { Providers.shared.shutdown(); exit(0) }
        let t0 = Date()
        var first: TimeInterval?
        print("\n== \(m.title) ==", terminator: "\n")
        Providers.shared.run(prompt: m.prompt(for: text), session: selftestSession) { ev in
            switch ev {
            case .delta(let d):
                if first == nil { first = Date().timeIntervalSince(t0) }
                FileHandle.standardOutput.write(d.data(using: .utf8)!)
            case .status(let s): print("[status] \(s)")
            case .done:
                print(String(format: "\n[首字 %.1fs，总计 %.1fs]", first ?? -1, Date().timeIntervalSince(t0)))
                next()
            case .failed(let e):
                print("\n[失败] \(e)")
                next()
            }
        }
    }
    let t = Date()
    Providers.shared.current.warmUp()
    Providers.shared.current.whenReady {
        print(String(format: "[就绪 %.2fs] provider=%@ model=%@", Date().timeIntervalSince(t), Settings.provider.rawValue, Settings.currentDisplayName))
        next()
    }
    RunLoop.main.run()
}

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--selftest" {
    runSelfTest(CommandLine.arguments)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--chattest" {
    // 自测追问：先「解释」，再连续追问两次
    let src = "We adopt a mixture-of-experts architecture in which a learned router dispatches each token to the top-2 experts, keeping per-token compute constant while scaling total parameters."
    var result = ""
    var history: [(String, String)] = []
    var questions = ["top-2 是什么意思？为什么不是只选 1 个？", "那这样做有什么缺点吗？用一句话说"]
    func ask() {
        guard !questions.isEmpty else { exit(0) }
        let q = questions.removeFirst()
        let t0 = Date(); var ans = ""
        print("\n问：\(q)")
        Providers.shared.run(prompt: Mode.followUpPrompt(source: src, mode: .explain, result: result, history: history, question: q), session: selftestSession) { ev in
            switch ev {
            case .delta(let d): ans += d; FileHandle.standardOutput.write(d.data(using: .utf8)!)
            case .done(let f): print(String(format: "\n[%.1fs]", Date().timeIntervalSince(t0))); history.append((q, f.isEmpty ? ans : f)); ask()
            case .failed(let e): print("\n[失败] \(e)"); exit(1)
            default: break
            }
        }
    }
    Providers.shared.current.warmUp()
    Providers.shared.current.whenReady {
        let t0 = Date()
        Providers.shared.run(prompt: Mode.explain.prompt(for: src), session: selftestSession) { ev in
            switch ev {
            case .delta(let d): result += d
            case .done(let f): if !f.isEmpty { result = f }; print(result); print(String(format: "[解释 %.1fs]", Date().timeIntervalSince(t0))); ask()
            case .failed(let e): print("[失败] \(e)"); exit(1)
            default: break
            }
        }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--login-item" {
    // 自测开机启动：--login-item [toggle]
    if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "toggle" {
        do { try LoginItem.toggle() } catch { print("error:", error) }
    }
    print("launch at login:", LoginItem.statusName)
    exit(0)
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--sessionbench" {
    // 模拟连续多次「新划选」（每次新会话，间隔 4 秒），测每次耗时
    let texts = ["The weather is nice today.", "Please review the pull request before Friday.",
                 "Latency matters more than throughput here.", "She sells seashells by the seashore.",
                 "Can you send me the slides after the meeting?"]
    var i = 0
    func next() {
        guard i < texts.count else { exit(0) }
        let text = texts[i]; i += 1
        let s = UUID(), t0 = Date(); var acc = ""
        Providers.shared.run(prompt: Mode.zh.prompt(for: text), session: s) { ev in
            switch ev {
            case .delta(let d): acc += d
            case .done(let f):
                print(String(format: "[新划选 %d  %.1fs] %@", i, Date().timeIntervalSince(t0), (f.isEmpty ? acc : f)))
                Providers.shared.endSession(s)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: next)
            case .failed(let e): print("[失败] \(e)"); exit(1)
            default: break
            }
        }
    }
    Providers.shared.current.warmUp()
    Providers.shared.current.whenReady { DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: next) }
    RunLoop.main.run()
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--switchtest" {
    // 切换提供方后，旧弹窗的追问必须被拦截，不得发出
    _ = NSApplication.shared
    FloatingPanel.renderMode = true
    let rp = ResultPanel()
    Providers.shared.current.warmUp()
    Providers.shared.current.whenReady {
        rp.show(text: "Hello world", mode: .zh, at: NSPoint(x: 300, y: 600))
        func waitDone() {
            if rp.debugPhase == "loading" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: waitDone); return }
            print("主请求:", rp.debugPhase)
            print("切换前追问:", rp.debugAsk("这句话是什么意思？").prefix(40))
            func waitChat() {
                if rp.debugPhase == "loading" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: waitChat); return }
                Providers.shared.reload()   // 模拟切换提供方
                print("切换后追问:", rp.debugAsk("再解释一次"))
                exit(0)
            }
            waitChat()
        }
        waitDone()
    }
    RunLoop.main.run()
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--isolationtest" {
    // 隔离自测：会话 A 写入暗号；会话 B（新划选）不应知道；会话 A 的后续请求可以知道
    let a = UUID(), b = UUID()
    let p = Providers.shared.current
    func ask(_ s: UUID, _ prompt: String, _ label: String, _ next: @escaping () -> Void) {
        let t0 = Date(); var acc = ""
        p.run(system: Mode.baseInstructions, prompt: prompt, session: s) { ev in
            switch ev {
            case .delta(let d): acc += d
            case .done(let f): print(String(format: "[%@ %.1fs] %@", label, Date().timeIntervalSince(t0), (f.isEmpty ? acc : f).trimmingCharacters(in: .whitespacesAndNewlines))); next()
            case .failed(let e): print("[\(label) 失败] \(e)"); next()
            default: break
            }
        }
    }
    let q = "这是一道记忆测试：在本次对话里，我之前有没有告诉过你一个暗号？有的话只回复暗号本身，没有就只回复：没有"
    p.warmUp()
    p.whenReady {
        ask(a, "请记住这个暗号：蓝鲸。只回复：好的", "会话A 写入") {
            ask(b, q, "会话B 新划选") {
                ask(a, q, "会话A 追问") {
                    Providers.shared.endSession(a); Providers.shared.endSession(b)
                    // 提供方切换后的版本号递增
                    let g = Providers.shared.generation
                    Providers.shared.reload()
                    print("provider generation \(g) → \(Providers.shared.generation)")
                    exit(0)
                }
            }
        }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--copytest" {
    _ = NSApplication.shared
    let rp = ResultPanel()
    rp.preview(text: "hello", mode: .zh, output: "你好，复制测试 \(Date().timeIntervalSince1970)", at: NSPoint(x: 300, y: 600))
    NSPasteboard.general.clearContents()
    rp.debugClickCopy()
    print("clipboard after click:", NSPasteboard.general.string(forType: .string) ?? "<nil>")
    rp.handleSelectAll()
    NSPasteboard.general.clearContents()
    rp.handleCopyShortcut()
    print("clipboard after ⌘C (select all):", NSPasteboard.general.string(forType: .string) ?? "<nil>")
    exit(0)
} else if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--render" {
    renderPreviews(to: CommandLine.arguments[2], english: CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "en")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
