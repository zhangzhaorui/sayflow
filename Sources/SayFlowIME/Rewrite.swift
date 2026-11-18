import AppKit
import SayFlowCore

/// 选中文字 AI 改写：只读取选中的部分；结果先预览，用户按回车（或点「替换」）才写入。
/// 浮窗不抢焦点，按键由输入法处理：1–4 选改写方式，回车替换，Esc 取消。
@MainActor
final class RewriteController {
    private let prefs: Preferences
    private let gateway: GatewayClient
    private let hud: HUD
    private let panel = RewritePanel()

    private var target: TextTarget?
    private var original = ""
    private var range = NSRange(location: NSNotFound, length: 0)
    private var result: String?
    private var requestID = 0

    init(prefs: Preferences, gateway: GatewayClient, hud: HUD) {
        self.prefs = prefs
        self.gateway = gateway
        self.hud = hud
        panel.onAction = { [weak self] action in self?.run(action) }
        panel.onReplace = { [weak self] in self?.replace() }
        panel.onCancel = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel.isVisible }

    func start(target: TextTarget) {
        guard prefs.rewriteEnabled else {
            hud.show("AI 改写已关闭，可以在 SayFlow 设置里打开", duration: 3)
            return
        }
        guard KeychainStore.hasKey else {
            hud.show("AI 改写需要先在 SayFlow 设置里填写令牌", duration: 3)
            return
        }
        guard !Permissions.isSecureInputActive else { return }
        switch target.selectedText(maxLength: GatewayConfig.rewriteMaxChars) {
        case .none:
            hud.show("先选中要改写的文字", duration: 2.5)
        case .tooLong:
            hud.show("选中的文字太长（最多 \(GatewayConfig.rewriteMaxChars) 字）", duration: 3)
        case .unsupported:
            hud.show("这个 App 不向输入法提供选中的文字，暂时不能改写", duration: 3)
        case .text(let text, let range):
            self.target = target
            self.original = text
            self.range = range
            self.result = nil
            requestID += 1
            panel.show(original: text, caret: target.caretRect)
        }
    }

    func close() {
        requestID += 1
        target = nil
        result = nil
        original = ""
        panel.hide()
    }

    private func run(_ action: RewriteAction) {
        guard let target, let key = KeychainStore.read() else { return }
        requestID += 1
        let id = requestID
        result = nil
        panel.showWorking(action)
        let source = original
        gateway.rewrite(text: source, action: action, dictionary: prefs.dictionary,
                        endpoint: prefs.gateway, apiKey: key) { [weak self] outcome in
            guard let self, self.requestID == id, self.target === target else { return }
            switch outcome {
            case .failure(let error):
                self.panel.showError("改写失败：" + error.message)
            case .success(let text):
                let clean = TextSanitizer.sanitize(text, singleLine: target.isTerminal)
                if clean.isEmpty {
                    self.panel.showError("改写结果为空")
                } else if ResultGuard.isTooMuchLonger(raw: source, cleaned: clean) {
                    self.panel.showError("改写结果比原文长太多，按安全规则不替换")
                } else {
                    self.result = clean
                    self.panel.showResult(clean, action: action)
                }
            }
        }
    }

    private func replace() {
        guard let target, let result else { return }
        // 选区变了（用户点了别处）就不替换，避免改错地方
        let now = target.client.selectedRange()
        guard now.location == range.location, now.length == range.length else {
            hud.show("选中的文字变了，已取消替换", duration: 3)
            close()
            return
        }
        target.insert(result, replacing: range)
        close()
    }

    /// 浮窗打开时处理按键；返回 true 表示已处理
    func handle(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard panel.isVisible else { return false }
        // ⌘ / ⌃ 组合键是 App 或系统快捷键（包括 ⌃空格切换输入法），关闭面板后交还系统
        if !modifiers.intersection([.command, .control]).isEmpty {
            close()
            return false
        }
        switch keyCode {
        case 53: close()                    // Esc
        case 36, 76: replace()              // 回车
        default:
            if let c = characters, let n = Int(c), n >= 1, n <= RewriteAction.allCases.count {
                run(RewriteAction.allCases[n - 1])
            }
        }
        return true
    }
}

@MainActor
final class RewritePanel: NSObject {
    private let panel: NSPanel
    private let originalLabel = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var actionButtons: [NSButton] = []
    private let replaceButton = NSButton(title: "替换（回车）", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消（Esc）", target: nil, action: nil)
    private var caret = NSRect.zero

    var onAction: ((RewriteAction) -> Void)?
    var onReplace: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isVisible = false

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        super.init()
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        build()
    }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "AI 改写选中的文字")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor

        originalLabel.font = .systemFont(ofSize: 12)
        originalLabel.textColor = .secondaryLabelColor
        originalLabel.maximumNumberOfLines = 2
        originalLabel.lineBreakMode = .byTruncatingTail

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        for (i, action) in RewriteAction.allCases.enumerated() {
            let button = NSButton(title: "\(i + 1) " + action.title, target: self, action: #selector(actionClicked(_:)))
            button.tag = i
            button.bezelStyle = .rounded
            button.controlSize = .small
            actionButtons.append(button)
            actions.addArrangedSubview(button)
        }

        resultLabel.font = .systemFont(ofSize: 14)
        resultLabel.maximumNumberOfLines = 12
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.isSelectable = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceButton.bezelStyle = .rounded
        replaceButton.keyEquivalent = ""
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [statusLabel, NSView(), cancelButton, replaceButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, originalLabel, actions, resultLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            originalLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        panel.contentView = background
    }

    func show(original: String, caret: NSRect) {
        self.caret = caret
        originalLabel.stringValue = "原文：" + TextPreview.line(original, maxLength: 80)
        resultLabel.stringValue = "按 1–4 选择改写方式"
        resultLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        replaceButton.isEnabled = false
        isVisible = true
        relayout()
    }

    func showWorking(_ action: RewriteAction) {
        resultLabel.stringValue = "正在" + action.title + "…"
        resultLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        replaceButton.isEnabled = false
        relayout()
    }

    func showResult(_ text: String, action: RewriteAction) {
        resultLabel.stringValue = text
        resultLabel.textColor = .labelColor
        statusLabel.stringValue = action.title + "完成"
        replaceButton.isEnabled = true
        relayout()
    }

    func showError(_ text: String) {
        resultLabel.stringValue = text
        resultLabel.textColor = .systemRed
        statusLabel.stringValue = ""
        replaceButton.isEnabled = false
        relayout()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    private func relayout() {
        guard isVisible, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelPlacement.origin(below: caret, size: size))
        panel.orderFrontRegardless()
    }

    @objc private func actionClicked(_ sender: NSButton) {
        let all = RewriteAction.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        onAction?(all[sender.tag])
    }

    @objc private func replaceClicked() { onReplace?() }
    @objc private func cancelClicked() { onCancel?() }
}
