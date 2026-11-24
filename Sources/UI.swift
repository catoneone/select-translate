// 划线翻译 — 界面组件
import Cocoa
import QuartzCore

// MARK: - 主题

extension NSColor {
    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

enum Theme {
    static let border  = NSColor.dyn(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.13))
    static let hover   = NSColor.dyn(NSColor(white: 0, alpha: 0.065), NSColor(white: 1, alpha: 0.10))
    static let track   = NSColor.dyn(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.07))
    static let knob    = NSColor.dyn(.white, NSColor(white: 1, alpha: 0.18))
    static let quoteBG = NSColor.dyn(NSColor(white: 0, alpha: 0.035), NSColor(white: 1, alpha: 0.05))
    static let divider = NSColor.dyn(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.08))
    static let solidBG = NSColor.dyn(NSColor(white: 0.97, alpha: 1), NSColor(white: 0.17, alpha: 1))
}

extension Mode {
    var symbol: String {
        switch self {
        case .zh: return "character.zh"
        case .en: return "character"
        case .polish: return "wand.and.sparkles"
        case .explain: return "lightbulb"
        }
    }
}

func screenFor(_ p: NSPoint) -> NSScreen {
    NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: - 基础视图

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 用 draw 绘制的圆角色块（动态颜色自动适配深浅色）
final class FillView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    convenience init(color: NSColor, radius: CGFloat = 0) {
        self.init(frame: .zero)
        self.color = color
        self.radius = radius
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BorderView: NSView {
    var radius: CGFloat = 12
    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        p.lineWidth = 1
        p.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class HoverButton: FirstMouseButton {
    var radius: CGFloat = 6
    var baseTint: NSColor = .secondaryLabelColor { didSet { refresh() } }
    var hoverTint: NSColor = .labelColor
    private var hovering = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    func refresh() {
        wantsLayer = true
        layer?.cornerRadius = radius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = (self.hovering ? Theme.hover : NSColor.clear).cgColor
        }
        contentTintColor = hovering ? hoverTint : baseTint
    }

    static func make(_ title: String = "", symbol: String? = nil, size: CGFloat = 13,
                     weight: NSFont.Weight = .medium, target: AnyObject?, action: Selector?) -> HoverButton {
        let t = (symbol != nil && !title.isEmpty) ? " " + title : title
        let b = HoverButton(title: t, target: target, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: size, weight: weight)
        if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: title) {
            b.image = img.withSymbolConfiguration(.init(pointSize: size - 0.5, weight: weight))
            b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            b.imageHugsTitle = true
        }
        b.toolTip = title.isEmpty ? nil : title
        b.refresh()
        return b
    }

    func set(title: String, symbol: String) {
        self.title = " " + title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: (font?.pointSize ?? 12) - 0.5, weight: .medium))
    }
}

/// 带滑块的分段选择器
final class Segmented: NSView {
    var onChange: ((Int) -> Void)?
    private let track = FillView(color: Theme.track, radius: 8)
    private let knob = FillView(color: Theme.knob, radius: 6)
    private var buttons: [NSButton] = []
    private(set) var selected = 0
    private let segW: CGFloat, h: CGFloat = 28, pad: CGFloat = 2

    init(titles: [String]) {
        // 段宽按最长标题自适应（英文标题更长）
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let maxW = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 30
        segW = max(52, ceil(maxW) + 22)
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(titles.count) * segW + 4, height: 28))
        track.frame = bounds
        track.autoresizingMask = [.width, .height]
        knob.wantsLayer = true
        let sh = NSShadow()
        sh.shadowBlurRadius = 2
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.16)
        knob.shadow = sh
        addSubview(track)
        addSubview(knob)
        for (i, t) in titles.enumerated() {
            let b = FirstMouseButton(title: t, target: self, action: #selector(tap(_:)))
            b.isBordered = false
            b.tag = i
            b.font = .systemFont(ofSize: 12.5, weight: .medium)
            b.frame = segRect(i)
            addSubview(b)
            buttons.append(b)
        }
        select(0, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func segRect(_ i: Int) -> NSRect {
        NSRect(x: pad + CGFloat(i) * segW, y: pad, width: segW, height: h - pad * 2)
    }

    func select(_ i: Int, animated: Bool) {
        selected = i
        let r = segRect(i)
        if animated {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.2
                c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                knob.animator().frame = r
            }
        } else {
            knob.frame = r
        }
        for b in buttons { b.contentTintColor = b.tag == i ? .labelColor : .secondaryLabelColor }
    }

    @objc private func tap(_ b: NSButton) {
        if b.tag != selected { select(b.tag, animated: true) }
        onChange?(b.tag)   // 点已选中的项 = 重新生成
    }
}

/// 加载中的三点跳动动画
final class TypingDots: NSView {
    private var dots: [CALayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for i in 0..<3 {
            let l = CALayer()
            l.frame = NSRect(x: CGFloat(i) * 12, y: (frame.height - 7) / 2, width: 7, height: 7)
            l.cornerRadius = 3.5
            layer?.addSublayer(l)
            dots.append(l)
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for l in self.dots { l.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        }
    }
    func start() {
        let now = CACurrentMediaTime()
        for (i, l) in dots.enumerated() {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.2
            a.toValue = 1
            a.duration = 0.45
            a.autoreverses = true
            a.repeatCount = .infinity
            a.beginTime = now + Double(i) * 0.15
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .backwards
            l.opacity = 0.2
            l.add(a, forKey: "pulse")
        }
    }
    func stop() { dots.forEach { $0.removeAllAnimations() } }
}

// MARK: - 浮动面板（毛玻璃 + 圆角 + 细描边）

final class FloatingPanel: NSPanel {
    static var renderMode = false   // 离屏渲染预览时用纯色背景
    private let keyable: Bool
    let container = FlippedView()

    init(size: NSSize, radius: CGFloat, keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let bg: NSView
        if Self.renderMode {
            bg = FillView(color: Theme.solidBG, radius: radius)
        } else {
            let fx = NSVisualEffectView()
            fx.material = .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.maskImage = Self.mask(radius)
            bg = fx
        }
        for v in [bg, container] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        let border = BorderView(frame: root.bounds)
        border.radius = radius
        border.autoresizingMask = [.width, .height]
        root.addSubview(border)
        contentView = root
    }
    required init?(coder: NSCoder) { fatalError() }
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    static func mask(_ r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    func fadeIn(to frame: NSRect) {
        alphaValue = 0
        setFrame(frame.offsetBy(dx: 0, dy: 5), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - 划词后弹出的胶囊工具条

final class Toolbar: NSObject {
    let panel: FloatingPanel
    var onPick: ((Mode, NSPoint) -> Void)?
    private var hideTimer: Timer?
    private let size: NSSize

    override init() {
        let h: CGFloat = 36, pad: CGFloat = 4
        var buttons: [HoverButton] = []
        var widths: [CGFloat] = []
        for m in Mode.allCases {
            let b = HoverButton.make(m.title, symbol: m.symbol, size: 13, target: nil, action: nil)
            b.radius = 14
            b.baseTint = .labelColor
            b.hoverTint = .controlAccentColor
            b.tag = m.rawValue
            b.sizeToFit()
            buttons.append(b)
            widths.append(ceil(b.frame.width) + 20)
        }
        let sepW: CGFloat = 9
        let w = pad * 2 + widths.reduce(0, +) + sepW * CGFloat(Mode.allCases.count - 1)
        size = NSSize(width: w, height: h)
        panel = FloatingPanel(size: size, radius: h / 2, keyable: false)
        super.init()

        var x = pad
        for (i, b) in buttons.enumerated() {
            b.target = self
            b.action = #selector(pick(_:))
            b.frame = NSRect(x: x, y: pad, width: widths[i], height: h - pad * 2)
            panel.container.addSubview(b)
            x += widths[i]
            if i < buttons.count - 1 {
                let sep = FillView(color: Theme.divider)
                sep.frame = NSRect(x: x + (sepW - 1) / 2, y: (h - 14) / 2, width: 1, height: 14)
                panel.container.addSubview(sep)
                x += sepW
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func frame(at p: NSPoint) -> NSRect {
        let vf = screenFor(p).visibleFrame
        var o = NSPoint(x: p.x - 14, y: p.y - 16 - size.height)
        o.x = min(max(o.x, vf.minX + 4), vf.maxX - size.width - 4)
        if o.y < vf.minY + 4 { o.y = p.y + 16 }   // 底部放不下就放到光标上方
        o.y = min(o.y, vf.maxY - size.height - 4)
        return NSRect(origin: o, size: size)
    }

    func show(at p: NSPoint) {
        panel.fadeIn(to: frame(at: p))
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }

    @objc private func pick(_ sender: NSButton) {
        guard let mode = Mode(rawValue: sender.tag) else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        hide()
        onPick?(mode, topLeft)
    }
}

// MARK: - 结果卡片（含追问对话）

/// 可直接点击输入的单行输入框
final class ChatField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ResultPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum Phase { case loading, done, failed }
    private struct ChatTurn {
        var question: String
        var answer = ""
        var state: Phase = .loading
    }

    let panel: FloatingPanel
    private let W: CGFloat = 420
    private let headerH: CGFloat = 48
    private let footerH: CGFloat = 38
    private let inputH: CGFloat = 48
    private var maxBodyH: CGFloat { (mode == .explain || !turns.isEmpty) ? 470 : 380 }

    private let seg = Segmented(titles: Mode.allCases.map { $0.title })
    private var pinBtn: HoverButton!
    private var closeBtn: HoverButton!
    private var copyBtn: HoverButton!
    private var sendBtn: HoverButton!
    private let quoteBG = FillView(color: Theme.quoteBG, radius: 8)
    private let quoteBar = FillView(color: .controlAccentColor, radius: 1.5)
    private let quoteLabel = NSTextField(wrappingLabelWithString: "")
    private let quoteFont = NSFont.systemFont(ofSize: 12.5)
    private let scroll = NSScrollView()
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 60))
    private let dots = TypingDots(frame: NSRect(x: 0, y: 0, width: 32, height: 10))
    private let inputBG = FillView(color: Theme.track, radius: 9)
    private let input = ChatField()
    private let divider = FillView(color: Theme.divider)
    private let statusDot = FillView(color: .controlAccentColor, radius: 3.5)
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyFont = NSFont.systemFont(ofSize: 15)

    private var anchor = NSPoint.zero
    private(set) var pinned = false
    private var source = ""
    private var mode: Mode = .zh
    private var phase: Phase = .loading     // 最近一次请求（主任务或追问）的状态
    private var output = ""                 // 主任务结果
    private var mainText = ""               // 主区域显示的文字（结果 / 错误）
    private var mainColor: NSColor = .labelColor
    private var turns: [ChatTurn] = []
    private var generation = 0              // 切换模式时作废旧请求的回调
    private var task: LLMTask?
    private var startedAt = Date()
    private var timeoutTimer: Timer?
    private var tickTimer: Timer?

    override init() {
        panel = FloatingPanel(size: NSSize(width: 420, height: 200), radius: 14, keyable: true)
        super.init()
        panel.delegate = self
        build()
    }

    var isVisible: Bool { panel.isVisible }
    /// 正在追问输入框里打字（此时 ⌘C/⌘V 等交给输入框）
    var isEditingInput: Bool { (panel.firstResponder as? NSTextView)?.isFieldEditor == true }

    private func build() {
        let c = panel.container

        seg.onChange = { [weak self] i in
            if let m = Mode(rawValue: i) { self?.run(m) }
        }
        c.addSubview(seg)

        closeBtn = HoverButton.make(symbol: "xmark", size: 12, weight: .semibold, target: self, action: #selector(closeTapped))
        closeBtn.toolTip = L("关闭（Esc）", "Close (Esc)")
        pinBtn = HoverButton.make(symbol: "pin", size: 12, weight: .semibold, target: self, action: #selector(togglePin))
        pinBtn.toolTip = L("固定窗口：点击外部不关闭（追问时自动固定）", "Pin: keep open when clicking elsewhere (auto-pinned when you ask a follow-up)")
        c.addSubview(closeBtn)
        c.addSubview(pinBtn)

        quoteLabel.font = quoteFont
        quoteLabel.textColor = .secondaryLabelColor
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.lineBreakMode = .byWordWrapping
        quoteLabel.cell?.wraps = true
        quoteLabel.cell?.truncatesLastVisibleLine = true
        quoteLabel.isSelectable = false
        c.addSubview(quoteBG)
        c.addSubview(quoteBar)
        c.addSubview(quoteLabel)

        scroll.frame = NSRect(x: 0, y: 0, width: W, height: 100)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 13, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: W, height: .greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.25)]
        scroll.documentView = textView
        c.addSubview(scroll)
        c.addSubview(dots)

        // 追问输入框
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 13.5)
        input.placeholderString = L("继续追问…（⏎ 发送）", "Ask a follow-up… (⏎ to send)")
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        input.target = self
        input.action = #selector(sendFromField(_:))
        input.delegate = self
        sendBtn = HoverButton.make(symbol: "arrow.up.circle.fill", size: 18, weight: .regular, target: self, action: #selector(sendTapped))
        sendBtn.radius = 13
        sendBtn.baseTint = .controlAccentColor
        sendBtn.hoverTint = .controlAccentColor
        sendBtn.toolTip = L("发送（⏎）", "Send (⏎)")
        c.addSubview(inputBG)
        c.addSubview(input)
        c.addSubview(sendBtn)

        c.addSubview(divider)
        c.addSubview(statusDot)
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        c.addSubview(statusLabel)

        copyBtn = HoverButton.make(L("复制", "Copy"), symbol: "doc.on.doc", size: 12, target: self, action: #selector(copyResult))
        copyBtn.toolTip = L("复制结果（有追问时复制最新回答）", "Copy result (the latest answer if you asked follow-ups)")
        c.addSubview(copyBtn)
    }

    // MARK: 展示 & 运行
    func show(text: String, mode m: Mode, at topLeft: NSPoint) {
        let wasVisible = panel.isVisible
        source = text
        anchor = topLeft
        input.stringValue = ""
        seg.select(m.rawValue, animated: false)
        run(m, animateIn: !wasVisible)
    }

    /// 仅用于离屏预览（不调用模型）
    func preview(text: String, mode m: Mode, output out: String?, error: String? = nil,
                 chat: [(String, String)] = [], at topLeft: NSPoint) {
        source = text
        anchor = topLeft
        mode = m
        seg.select(m.rawValue, animated: false)
        turns = chat.map { ChatTurn(question: $0.0, answer: $0.1, state: .done) }
        if let error {
            phase = .failed; output = ""; mainText = L("出错了：", "Error: ") + error; mainColor = .systemRed
        } else if let out {
            phase = .done; output = out; mainText = out; mainColor = .labelColor
        } else {
            phase = .loading; output = ""; mainText = ""; mainColor = .labelColor
        }
        render(relayoutNow: false)
        updateStatus(elapsed: 3.2)
        relayout()
    }

    private func run(_ m: Mode, animateIn: Bool = false) {
        mode = m
        output = ""
        mainText = ""
        mainColor = .labelColor
        turns = []
        let gen = beginRequest(prompt: m.prompt(for: source), animateIn: animateIn) { [weak self] ev in
            self?.handleMain(ev)
        }
        _ = gen
    }

    /// 发起一次请求（主任务或追问），统一处理计时、超时、状态
    @discardableResult
    private func beginRequest(prompt: String, animateIn: Bool = false, onEvent: @escaping (LLMEvent) -> Void) -> Int {
        task?.cancel()
        stopTimers()
        generation += 1
        let gen = generation
        phase = .loading
        startedAt = Date()
        render(relayoutNow: false)
        updateStatus()
        relayout(animateIn: animateIn)

        let t = Providers.shared.run(prompt: prompt) { [weak self] ev in
            guard let self, self.generation == gen else { return }
            onEvent(ev)
        }
        task = t
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateStatus() }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            guard let self, self.task === t else { return }
            t.cancel()
            onEvent(.failed(L("请求超时（120 秒），请检查网络后重试", "Request timed out (120 s). Check your network and try again.")))
        }
        return gen
    }

    private func handleMain(_ ev: LLMEvent) {
        switch ev {
        case .delta(let d):
            output += d
            mainText = output
            render()
            if !copyBtn.isEnabled { updateStatus() }
        case .status(let s):
            statusLabel.stringValue = "\(Settings.currentDisplayName) · \(s)"
        case .done(let full):
            let t = full.trimmingCharacters(in: .whitespacesAndNewlines)
            output = t.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : t
            mainText = output.isEmpty ? L("（模型没有返回内容）", "(The model returned nothing)") : output
            mainColor = output.isEmpty ? .secondaryLabelColor : .labelColor
            finishRequest(.done)
        case .failed(let msg):
            mainText = L("出错了：", "Error: ") + msg
            mainColor = .systemRed
            finishRequest(.failed)
        }
    }

    private func handleChat(_ ev: LLMEvent, index i: Int) {
        guard i < turns.count else { return }
        switch ev {
        case .delta(let d):
            turns[i].answer += d
            render()
            if !copyBtn.isEnabled { updateStatus() }
        case .status(let s):
            statusLabel.stringValue = "\(Settings.currentDisplayName) · \(s)"
        case .done(let full):
            let t = full.trimmingCharacters(in: .whitespacesAndNewlines)
            turns[i].answer = t.isEmpty ? turns[i].answer.trimmingCharacters(in: .whitespacesAndNewlines) : t
            if turns[i].answer.isEmpty { turns[i].answer = L("（模型没有返回内容）", "(The model returned nothing)") }
            turns[i].state = .done
            finishRequest(.done)
        case .failed(let msg):
            turns[i].answer = L("出错了：", "Error: ") + msg
            turns[i].state = .failed
            finishRequest(.failed)
        }
    }

    private func finishRequest(_ p: Phase) {
        phase = p
        stopTimers()
        task = nil
        render()
        updateStatus()
    }

    // MARK: 追问
    @objc private func sendFromField(_ sender: Any?) {
        // NSTextField 失去焦点时也可能触发 action，只在按下回车时发送
        guard NSApp.currentEvent?.type == .keyDown else { return }
        send()
    }

    @objc private func sendTapped() { send() }

    private func send() {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard phase != .loading else { NSSound.beep(); return }
        input.stringValue = ""
        if !pinned { togglePin() }   // 开始对话后自动固定，避免点别处时窗口消失
        let history = turns.filter { $0.state == .done }.map { ($0.question, $0.answer) }
        turns.append(ChatTurn(question: q))
        let idx = turns.count - 1
        let prompt = Mode.followUpPrompt(source: source, mode: mode, result: output, history: history, question: q)
        beginRequest(prompt: prompt) { [weak self] ev in self?.handleChat(ev, index: idx) }
    }

    /// 聚焦到追问输入框
    func focusInput() {
        panel.makeKey()
        panel.makeFirstResponder(input)
    }

    private func stopTimers() {
        timeoutTimer?.invalidate()
        tickTimer?.invalidate()
    }

    private var copyableText: String {
        if let last = turns.last, last.state == .done { return last.answer }
        if let last = turns.last, last.state == .loading, !last.answer.isEmpty { return last.answer }
        return output
    }

    private func updateStatus(elapsed: TimeInterval? = nil) {
        let t = elapsed ?? Date().timeIntervalSince(startedAt)
        let secs = String(format: L("%.1f 秒", "%.1fs"), t)
        statusDot.layer?.removeAllAnimations()
        switch phase {
        case .loading:
            statusDot.color = .controlAccentColor
            statusLabel.stringValue = "\(Settings.currentDisplayName) · " + (turns.isEmpty ? L("生成中", "Generating") : L("思考中", "Thinking")) + " \(secs)"
            if statusDot.layer?.animation(forKey: "pulse") == nil { pulse(statusDot) }
            dots.start()
        case .done:
            statusDot.color = .systemGreen
            statusLabel.stringValue = "\(Settings.currentDisplayName) · \(secs)"
            dots.stop()
        case .failed:
            statusDot.color = .systemRed
            statusLabel.stringValue = "\(Settings.currentDisplayName) · " + L("失败", "Failed")
            dots.stop()
        }
        let text = copyableText.trimmingCharacters(in: .whitespacesAndNewlines)
        copyBtn.isEnabled = !text.isEmpty && !(phase == .failed && turns.isEmpty)
        copyBtn.alphaValue = copyBtn.isEnabled ? 1 : 0.4
        sendBtn.isEnabled = phase != .loading
        sendBtn.alphaValue = sendBtn.isEnabled ? 1 : 0.35
    }

    private func pulse(_ v: NSView) {
        v.wantsLayer = true
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.3
        a.duration = 0.7
        a.autoreverses = true
        a.repeatCount = .infinity
        v.layer?.add(a, forKey: "pulse")
    }

    // MARK: 正文渲染（主结果 + 追问对话）
    private static let headingRegex = try? NSRegularExpression(pattern: "【([^】\\n]{1,24})】")

    private var basePara: NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 6
        return p
    }

    private func styled(_ s: String, color: NSColor) -> NSMutableAttributedString {
        let para = basePara
        let attr = NSMutableAttributedString(string: s, attributes: [
            .font: bodyFont, .foregroundColor: color, .paragraphStyle: para,
        ])
        guard color == .labelColor else { return attr }
        // 「• 」开头的条目：换行后悬挂缩进，与文字对齐
        let ns = s as NSString
        let bulletW = ("• " as NSString).size(withAttributes: [.font: bodyFont]).width
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub, sub.hasPrefix("• ") || sub.hasPrefix("- ") else { return }
            let bp = para.mutableCopy() as! NSMutableParagraphStyle
            bp.headIndent = bulletW
            attr.addAttribute(.paragraphStyle, value: bp, range: range)
        }
        // 「解释」模式的小标题：【一句话】→ 强调色加粗的“一句话”
        if let re = Self.headingRegex {
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hp = NSMutableParagraphStyle()
                hp.lineSpacing = 4
                hp.paragraphSpacing = 3
                hp.paragraphSpacingBefore = m.range.location == 0 ? 0 : 8
                attr.replaceCharacters(in: m.range, with: NSAttributedString(
                    string: ns.substring(with: m.range(at: 1)),
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                 .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: hp]))
            }
        }
        return attr
    }

    private func render(relayoutNow: Bool = true) {
        let all = styled(mainText, color: mainColor)
        for t in turns {
            // 问题：强调色「问」+ 加粗问题文字
            let qp = NSMutableParagraphStyle()
            qp.lineSpacing = 3
            qp.paragraphSpacing = 4
            qp.paragraphSpacingBefore = 14
            let q = NSMutableAttributedString(string: "\n")
            q.append(NSAttributedString(string: L("问  ", "Q  "), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: qp]))
            q.append(NSAttributedString(string: t.question, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: qp]))
            all.append(q)
            all.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            switch (t.state, t.answer.isEmpty) {
            case (.loading, true):
                all.append(NSAttributedString(string: L("思考中…", "Thinking…"), attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: basePara]))
            case (.failed, _):
                all.append(styled(t.answer, color: .systemRed))
            default:
                all.append(styled(t.answer, color: .labelColor))
            }
        }
        textView.textStorage?.setAttributedString(all)
        if relayoutNow { relayout() }
    }

    // MARK: 布局（container 为翻转坐标，自上而下排布）
    private func relayout(animateIn: Bool = false) {
        // 原文引用：压成一段文字，最多显示两行
        let preview = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        quoteLabel.stringValue = preview
        let qLabelW = W - 28 - 26
        let lineH = ceil(quoteFont.ascender - quoteFont.descender + quoteFont.leading)
        let fullH = ceil(NSAttributedString(string: preview, attributes: [.font: quoteFont])
            .boundingRect(with: NSSize(width: qLabelW - 4, height: 1000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let qLabelH = min(fullH, lineH * 2 + 2)
        let quoteH = qLabelH + 14

        // 正文
        let showDots = phase == .loading && mainText.isEmpty && turns.isEmpty
        var bodyH: CGFloat = 46
        if !showDots, let lm = textView.layoutManager, let tc = textView.textContainer {
            textView.frame.size.width = W
            lm.ensureLayout(for: tc)
            let textH = ceil(lm.usedRect(for: tc).height + textView.textContainerInset.height * 2) + 8
            bodyH = min(max(textH, 40), maxBodyH)
        }
        let gap: CGFloat = 10
        let H = headerH + quoteH + gap + bodyH + inputH + 1 + footerH

        // 窗口位置：左上角固定在锚点
        let vf = screenFor(anchor).visibleFrame
        let x = min(max(anchor.x, vf.minX + 4), vf.maxX - W - 4)
        let top = min(anchor.y, vf.maxY - 4)
        let y = max(top - H, vf.minY + 4)
        let frame = NSRect(x: x, y: y, width: W, height: H)
        if animateIn { panel.fadeIn(to: frame) } else { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }

        // 子视图
        seg.setFrameOrigin(NSPoint(x: 12, y: (headerH - seg.frame.height) / 2))
        closeBtn.frame = NSRect(x: W - 12 - 26, y: (headerH - 26) / 2, width: 26, height: 26)
        pinBtn.frame = NSRect(x: W - 12 - 26 - 30, y: (headerH - 26) / 2, width: 26, height: 26)

        var cy = headerH
        quoteBG.frame = NSRect(x: 14, y: cy, width: W - 28, height: quoteH)
        quoteBar.frame = NSRect(x: 22, y: cy + 8, width: 3, height: quoteH - 16)
        quoteLabel.frame = NSRect(x: 33, y: cy + 7, width: qLabelW, height: qLabelH)
        cy += quoteH + gap

        scroll.frame = NSRect(x: 0, y: cy, width: W, height: bodyH)
        textView.frame.size.width = scroll.contentSize.width   // 不依赖自动缩放，避免宽度被叠加
        scroll.isHidden = showDots
        dots.isHidden = !showDots
        dots.setFrameOrigin(NSPoint(x: 21, y: cy + 14))
        if phase == .loading || !turns.isEmpty { textView.scrollToEndOfDocument(nil) } else { textView.scroll(.zero) }
        cy += bodyH

        // 追问输入框
        let fieldH: CGFloat = 34
        let fy = cy + 4
        inputBG.frame = NSRect(x: 14, y: fy, width: W - 28, height: fieldH)
        input.frame = NSRect(x: 26, y: fy + (fieldH - 20) / 2, width: W - 28 - 12 - 36, height: 20)
        sendBtn.frame = NSRect(x: W - 14 - 32, y: fy + (fieldH - 26) / 2, width: 26, height: 26)
        cy += inputH

        divider.frame = NSRect(x: 0, y: cy, width: W, height: 1)
        cy += 1
        statusDot.frame = NSRect(x: 18, y: cy + (footerH - 7) / 2, width: 7, height: 7)
        statusLabel.frame = NSRect(x: 32, y: cy + (footerH - 16) / 2, width: 260, height: 16)
        copyBtn.sizeToFit()
        let cw = ceil(copyBtn.frame.width) + 18
        copyBtn.frame = NSRect(x: W - 10 - cw, y: cy + (footerH - 26) / 2, width: cw, height: 26)

        panel.invalidateShadow()
    }

    func hide() {
        task?.cancel()
        task = nil
        generation += 1
        stopTimers()
        dots.stop()
        panel.orderOut(nil)
    }

    func hideIfNotPinned() { if !pinned { hide() } }

    func windowDidMove(_ notification: Notification) {
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    // MARK: 按钮
    @objc private func closeTapped() { hide() }

    @objc private func togglePin() {
        pinned.toggle()
        pinBtn.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: L("固定", "Pin"))?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))
        pinBtn.baseTint = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    /// ⌘C：结果里有选中文字就复制选中部分，否则复制结果（有追问时为最新回答）
    func handleCopyShortcut() {
        let sel = textView.selectedRange()
        if sel.length > 0 {
            writeClipboard((textView.string as NSString).substring(with: sel), source: "⌘C 选中")
            flashCopied()
        } else {
            copyResult()
        }
    }

    func handleSelectAll() { textView.selectAll(nil) }

    @discardableResult
    private func writeClipboard(_ s: String, source: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(s, forType: .string)
        appLog("copy via \(source): \(s.count) chars, ok=\(ok), verify=\(pb.string(forType: .string) == s)")
        return ok
    }

    /// 自测用：模拟点击复制按钮
    func debugClickCopy() { copyBtn.performClick(nil) }

    @objc private func copyResult() {
        let text = copyableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { appLog("copy button: output empty, phase=\(phase)"); NSSound.beep(); return }
        writeClipboard(text, source: "按钮")
        flashCopied()
    }

    private func flashCopied() {
        copyBtn.set(title: L("已复制", "Copied"), symbol: "checkmark")
        copyBtn.baseTint = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self else { return }
            self.copyBtn.set(title: L("复制", "Copy"), symbol: "doc.on.doc")
            self.copyBtn.baseTint = .secondaryLabelColor
        }
    }
}

// MARK: - 离屏渲染预览：SelectTranslate --render <输出目录>

func renderPreviews(to dir: String, english: Bool = false) {
    FloatingPanel.renderMode = true
    L10n.override = english ? .en : .zh
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let src = "Large language models are transforming how people read and write across languages, making cross-lingual communication easier than ever before."
    let paper = "We propose a contrastive pre-training objective that aligns image and text embeddings in a shared latent space, enabling zero-shot transfer to downstream classification tasks."
    let explainOut = english ? """
    【In one sentence】
    The model learns from lots of image–caption pairs to put matching pictures and words close together, so it can recognize new things without extra training.
    【Key concepts】
    • Contrastive pre-training: showing matching and non-matching pairs so the model learns which ones belong together.
    • Embedding: turning an image or text into a list of numbers; similar meanings get similar numbers.
    • Zero-shot transfer: doing a new task it was never specifically trained on.
    【Analogy】
    Like learning vocabulary with picture flashcards — after enough practice you can name a picture you've never seen before.
    """ : """
    【一句话】
    作者让 AI 同时看大量"图片 + 文字说明"，学会把意思相同的图和字放到一起，这样不用专门训练也能认出新东西。
    【关键概念】
    • 对比预训练：给 AI 看配对的和不配对的图文，让它学会"谁和谁是一对"。
    • 嵌入（embedding）：把图片或文字变成一串数字，意思越接近，数字越接近。
    • 零样本迁移：没专门教过的任务，也能直接上手做。
    【打个比方】
    就像背单词时同时看图和单词卡，背多了，看到一张没见过的图也能猜出对应的词。
    """
    let chatMode: Mode = english ? .polish : .zh
    let chatSrc = english ? "Our method achieve better result then previous works on all benchmark." : "Large language models are transforming how people read and write across languages."
    let chatOut = english ? "Our method achieves better results than previous work on all benchmarks." : "大语言模型正在改变人们跨语言阅读和写作的方式。"
    let chatQA: [(String, String)] = english
        ? [("Why \"previous work\" instead of \"previous works\"?", "In academic writing, \"work\" meaning research is usually uncountable, so \"previous work\" sounds more natural."),
           ("Make it sound more confident?", "Our method consistently outperforms prior work across all benchmarks.")]
        : [("这里的 transforming 为什么不译成「转变」？", "「改变」更口语、搭配「方式」更自然；「转变」偏正式，强调从一种状态彻底变成另一种，用在这里略重。"),
           ("换个更学术的说法？", "大语言模型正在深刻重塑人们跨语言阅读与写作的方式。")]

    for (apName, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        NSApp.appearance = NSAppearance(named: ap)
        let tb = Toolbar()
        tb.panel.setFrame(tb.frame(at: NSPoint(x: 400, y: 400)), display: true)
        save(tb.panel, "\(dir)/toolbar-\(apName).png")

        let sw = SettingsWindowController()
        for k in [ProviderKind.codex, .openai, .claudeCode, .anthropic] {
            let w = sw.debugWindow(for: k)
            w.appearance = NSAppearance(named: ap)
            w.contentView?.wantsLayer = true
            w.contentView?.appearance = NSAppearance(named: ap)
            w.contentView?.effectiveAppearance.performAsCurrentDrawingAppearance {
                w.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            save(w, "\(dir)/settings-\(k.rawValue)-\(apName).png")
        }

        let ex = ResultPanel()
        ex.preview(text: paper, mode: .explain, output: explainOut, at: NSPoint(x: 400, y: 900))
        save(ex.panel, "\(dir)/result-explain-\(apName).png")

        let chat = ResultPanel()
        chat.preview(text: chatSrc, mode: chatMode, output: chatOut, chat: chatQA, at: NSPoint(x: 400, y: 900))
        save(chat.panel, "\(dir)/result-chat-\(apName).png")
        chat.panel.orderOut(nil)
        ex.panel.orderOut(nil)

        let states: [(String, String?, String?)] = [
            ("done", "大语言模型正在改变人们跨语言阅读和写作的方式，让跨语言交流变得前所未有地容易。", nil),
            ("loading", nil, nil),
            ("error", nil, "The 'gpt-x' model is not supported."),
        ]
        for (name, out, err) in states {
            let rp = ResultPanel()
            rp.preview(text: src, mode: .zh, output: out, error: err, at: NSPoint(x: 400, y: 700))
            save(rp.panel, "\(dir)/result-\(name)-\(apName).png")
            rp.panel.orderOut(nil)
        }
        tb.panel.orderOut(nil)
    }
}

private func save(_ w: NSWindow, _ path: String) {
    guard let v = w.contentView else { return }
    v.layoutSubtreeIfNeeded()
    v.appearance = NSApp.appearance
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - 启动提示卡片（屏幕顶部居中）

final class NoticePanel: NSObject {
    let panel: FloatingPanel
    var onAction: (() -> Void)?
    private let W: CGFloat = 400, H: CGFloat = 74
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(wrappingLabelWithString: "")
    private let actionBtn = FirstMouseButton(title: "", target: nil, action: nil)
    private var closeBtn: HoverButton!
    private var hideTimer: Timer?

    override init() {
        panel = FloatingPanel(size: NSSize(width: 400, height: 74), radius: 16, keyable: false)
        super.init()
        let c = panel.container
        icon.frame = NSRect(x: 14, y: (H - 36) / 2, width: 36, height: 36)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.frame = NSRect(x: 58, y: 15, width: 220, height: 18)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor
        subLabel.frame = NSRect(x: 58, y: 35, width: 230, height: 32)
        subLabel.maximumNumberOfLines = 2
        actionBtn.bezelStyle = .push
        actionBtn.keyEquivalent = "\r"
        actionBtn.controlSize = .regular
        actionBtn.target = self
        actionBtn.action = #selector(tapAction)
        closeBtn = HoverButton.make(symbol: "xmark", size: 10, weight: .bold, target: self, action: #selector(hide))
        closeBtn.radius = 9
        closeBtn.frame = NSRect(x: W - 24, y: 6, width: 18, height: 18)
        [icon, titleLabel, subLabel, actionBtn, closeBtn].forEach { c.addSubview($0) }
    }

    func show(symbol: String, tint: NSColor, title: String, subtitle: String, action: String?, autoHide: TimeInterval?) {
        if symbol == "@app" {
            icon.image = NSApp.applicationIconImage   // 使用应用图标
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = tint
        }
        titleLabel.stringValue = title
        subLabel.stringValue = subtitle
        if let action {
            actionBtn.isHidden = false
            actionBtn.title = action
            actionBtn.sizeToFit()
            let bw = max(ceil(actionBtn.frame.width) + 8, 76)
            actionBtn.frame = NSRect(x: W - 30 - bw, y: (H - 28) / 2, width: bw, height: 28)
            subLabel.frame.size.width = W - 58 - bw - 40
            titleLabel.frame.size.width = W - 58 - bw - 40
        } else {
            actionBtn.isHidden = true
            subLabel.frame.size.width = W - 58 - 36
            titleLabel.frame.size.width = W - 58 - 36
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let f = NSRect(x: vf.midX - W / 2, y: vf.maxY - H - 14, width: W, height: H)
        if panel.isVisible { panel.setFrame(f, display: true) } else { panel.fadeIn(to: f) }
        hideTimer?.invalidate()
        if let t = autoHide {
            hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.hide() }
        }
    }

    @objc func hide() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    @objc private func tapAction() { onAction?() }
}

func appLog(_ s: String) {
    let url = Settings.logURL("app.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
