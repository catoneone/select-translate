// 划线翻译 Select Translate — 入口与命令行自测
import Cocoa
import ApplicationServices

// MARK: - 命令行自测：SelectTranslate --selftest [文本] [模式]

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
        Providers.shared.run(prompt: m.prompt(for: text)) { ev in
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
        Providers.shared.run(prompt: Mode.followUpPrompt(source: src, mode: .explain, result: result, history: history, question: q)) { ev in
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
        Providers.shared.run(prompt: Mode.explain.prompt(for: src)) { ev in
            switch ev {
            case .delta(let d): result += d
            case .done(let f): if !f.isEmpty { result = f }; print(result); print(String(format: "[解释 %.1fs]", Date().timeIntervalSince(t0))); ask()
            case .failed(let e): print("[失败] \(e)"); exit(1)
            default: break
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
    renderPreviews(to: CommandLine.arguments[2])
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
