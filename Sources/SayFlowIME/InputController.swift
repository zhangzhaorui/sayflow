import AppKit
import InputMethodKit
import SayFlowCore

/// 每个输入框（客户端）一个控制器。系统只在当前输入法是 SayFlow 时把按键交给它。
/// 不记录、不保存、不上传任何按键；只有用户主动触发的语音和改写才会联网。
@objc(SayFlowInputController)
final class InputController: IMKInputController {
    private var hasMarkedText = false
    private var rightCommandDown = false

    /// 按 ↓ 展开的候选网格（7 × 7）
    private struct Grid {
        static let columns = 7
        static let rows = 7
        static var size: Int { columns * rows }
        var offset: Int          // 网格第一个候选在全部候选里的序号
        var highlighted: Int     // 网格内高亮的位置
        var items: [Candidate]
    }
    private var grid: Grid?

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? TextClient else { return false }
        return MainActor.assumeIsolated { handleEvent(event, client: client) }
    }

    override func activateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            let services = AppServices.shared
            services.candidates.onSelect = { [weak self] index in self?.selectCandidate(index) }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            if let client = sender as? TextClient { finishComposition(client) }
            AppServices.shared.hidePanels()
            if rightCommandDown {
                rightCommandDown = false
                AppServices.shared.voice.released()
            }
        }
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            if let client = sender as? TextClient { finishComposition(client) }
        }
    }

    // MARK: 按键

    @MainActor
    private func handleEvent(_ event: NSEvent, client: TextClient) -> Bool {
        let services = AppServices.shared
        // 密码框等安全输入：什么都不处理，按键原样交给 App
        if Permissions.isSecureInputActive { return false }

        switch event.type {
        case .flagsChanged:
            return handleModifier(event, client: client, services: services)
        case .keyDown:
            return handleKeyDown(event, client: client, services: services)
        default:
            return false
        }
    }

    @MainActor
    private func handleModifier(_ event: NSEvent, client: TextClient, services: AppServices) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 右 Command：按住说话（只看按下和松开，不拦截，App 照常收到）
        if event.keyCode == 54 {
            if flags.contains(.command), !rightCommandDown {
                rightCommandDown = true
                services.voice.pressed(target: TextTarget(client: client))
            } else if !flags.contains(.command), rightCommandDown {
                rightCommandDown = false
                services.voice.released()
            }
            return false
        }
        if services.rewrite.isVisible { return false }
        guard services.engine.isReady else { return false }
        let pressed: Bool
        switch event.keyCode {
        case 56, 60: pressed = flags.contains(.shift)
        case 59, 62: return false   // Control 不交给 Rime，留给系统处理 ⌃空格等快捷键
        case 58, 61: pressed = flags.contains(.option)
        case 55: pressed = flags.contains(.command)
        case 57: pressed = flags.contains(.capsLock)
        default: return false
        }
        let wasAscii = services.engine.isAsciiMode
        let result = services.engine.processModifier(keyCode: event.keyCode, pressed: pressed, modifiers: flags.rimeModifiers)
        apply(result, client: client)
        let isAscii = services.engine.isAsciiMode
        if isAscii != wasAscii {
            services.hud.show(isAscii ? "英文" : "中文", duration: 0.8)
        }
        return result.handled
    }

    @MainActor
    private func handleKeyDown(_ event: NSEvent, client: TextClient, services: AppServices) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var chars = event.charactersIgnoringModifiers
        // 按住 Shift 打符号（? @ # $ % ( ) 等）：用实际产生的字符，不同键盘布局下才准确
        if flags.contains(.shift), flags.intersection([.control, .option, .command]).isEmpty,
           let typed = event.characters, let scalar = typed.unicodeScalars.first,
           typed.unicodeScalars.count == 1, scalar.value >= 0x21, scalar.value < 0x7F,
           !CharacterSet.letters.contains(scalar) {
            chars = typed
        }

        // 按住右 Command 时按了别的键：这是快捷键，取消录音，按键照常交给 App
        if services.voice.isRecording {
            services.voice.cancelForOtherKey()
            return false
        }
        if services.rewrite.isVisible {
            return services.rewrite.handle(keyCode: event.keyCode, characters: chars, modifiers: flags)
        }

        // ⌃⌥R 改写选中文字
        if flags == [.control, .option] {
            switch event.keyCode {
            case 15:
                finishComposition(client)
                services.rewrite.start(target: TextTarget(client: client))
                return true
            default:
                break
            }
        }

        // ⌃空格、⌃⌥空格 是系统切换输入法的快捷键，一律交给系统
        if event.keyCode == 49, flags.contains(.control) {
            finishComposition(client)
            return false
        }
        // 没在打字时，带 ⌃ / ⌥ / ⌘ 的组合键都是 App 的快捷键，不交给引擎
        if !hasMarkedText, !flags.intersection([.control, .option, .command]).isEmpty {
            return false
        }

        // 展开的候选网格：方向键选择、回车/空格上屏、数字选当前行
        if grid != nil, flags.intersection([.control, .option, .command]).isEmpty {
            if handleGridKey(event.keyCode, characters: chars, client: client) { return true }
        }
        // 打字中按 ↓：展开 7 × 7 候选网格（类似搜狗）
        if grid == nil, hasMarkedText, !services.prefs.verticalCandidates, event.keyCode == 125, flags.intersection([.shift, .control, .option, .command]).isEmpty {
            if openGrid(client: client) { return true }
        }

        let result = services.engine.process(keyCode: event.keyCode, characters: chars, modifiers: flags.rimeModifiers)
        apply(result, client: client)
        return result.handled
    }

    // MARK: 展开的候选网格

    @MainActor
    private func openGrid(client: TextClient) -> Bool {
        let engine = AppServices.shared.engine
        let state = engine.snapshot
        let start = state.pageStart
        let items = engine.candidateList(from: start, count: Grid.size)
        guard items.count > 1 else { return false }
        grid = Grid(offset: start, highlighted: min(state.highlighted, items.count - 1), items: items)
        showGrid(client: client, preedit: state.preedit, schemaLabel: state.schemaLabel)
        return true
    }

    @MainActor
    private func showGrid(client: TextClient, preedit: String? = nil, schemaLabel: String? = nil) {
        guard let grid else { return }
        let services = AppServices.shared
        let row = grid.highlighted / Grid.columns
        let labels = grid.items.indices.map { i -> String in
            i / Grid.columns == row ? String(i % Grid.columns + 1) : ""
        }
        var display = CandidateDisplay()
        display.header = gridHeader
        display.items = grid.items
        display.labels = labels
        display.highlighted = grid.highlighted
        display.layout = .grid(columns: Grid.columns)
        display.footer = "↑↓←→ 选择　回车/空格 上屏　1–7 选本行　-/= 翻页　Esc 收起"
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        services.candidates.show(display, caret: rect)
    }

    private var gridHeader: String = ""

    @MainActor
    private func closeGrid(client: TextClient) {
        grid = nil
        let state = AppServices.shared.engine.snapshot
        showCandidates(state, client: client)
    }

    /// 网格打开时处理按键；返回 false 表示交给引擎（例如继续打拼音）
    @MainActor
    private func handleGridKey(_ keyCode: UInt16, characters: String?, client: TextClient) -> Bool {
        guard var g = grid else { return false }
        let engine = AppServices.shared.engine
        func move(to index: Int) {
            g.highlighted = max(0, min(index, g.items.count - 1))
            grid = g
            showGrid(client: client)
        }
        func pick(_ index: Int) {
            guard index >= 0, index < g.items.count else { return }
            grid = nil
            apply(engine.select(globalIndex: g.offset + index), client: client)
        }
        func page(_ delta: Int) {
            let start = max(0, g.offset + delta * Grid.size)
            let items = engine.candidateList(from: start, count: Grid.size)
            guard !items.isEmpty, start != g.offset else { return }
            grid = Grid(offset: start, highlighted: 0, items: items)
            showGrid(client: client)
        }
        switch keyCode {
        case 123: move(to: g.highlighted - 1)                       // ←
        case 124: move(to: g.highlighted + 1)                       // →
        case 125: move(to: g.highlighted + Grid.columns)            // ↓
        case 126:                                                   // ↑：第一行再按就收起
            if g.highlighted < Grid.columns { closeGrid(client: client) } else { move(to: g.highlighted - Grid.columns) }
        case 36, 76, 49: pick(g.highlighted)                        // 回车、空格
        case 53: closeGrid(client: client)                          // Esc
        case 121: page(1)                                           // Page Down
        case 116: page(-1)                                          // Page Up
        default:
            if let c = characters, c == "=" || c == "]" { page(1); return true }
            if let c = characters, c == "-" || c == "[" { page(-1); return true }
            if let c = characters, let n = Int(c), n >= 1, n <= Grid.columns {
                pick((g.highlighted / Grid.columns) * Grid.columns + n - 1)
                return true
            }
            // 其他键（继续打字、退格）：收起网格，交给引擎
            grid = nil
            return false
        }
        return true
    }

    // MARK: 上屏和输入状态

    @MainActor
    private func apply(_ result: EngineResult, client: TextClient) {
        let services = AppServices.shared
        if let commit = result.commit {
            let text = TextSanitizer.sanitize(commit, singleLine: false)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            hasMarkedText = false
        }
        let state = result.state
        // 有拼音或有候选（例如按「/」弹出的符号选单）都要显示候选窗
        if state.isComposing || !state.candidates.isEmpty {
            if state.isComposing {
                let attributed = NSAttributedString(string: state.preedit, attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
                let cursor = min(max(0, state.cursor), state.preedit.utf16.count)
                client.setMarkedText(attributed,
                                     selectionRange: NSRange(location: cursor, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                hasMarkedText = true
            }
            showCandidates(state, client: client)
        } else {
            if hasMarkedText {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                hasMarkedText = false
            }
            grid = nil
            services.candidates.hide()
        }
    }

    /// 普通（收起）状态的候选窗：横排或竖排，按设置
    @MainActor
    private func showCandidates(_ state: EngineState, client: TextClient) {
        let services = AppServices.shared
        guard state.isComposing || !state.candidates.isEmpty else {
            services.candidates.hide()
            return
        }
        var display = CandidateDisplay()
        let header = state.preedit.isEmpty ? state.schemaLabel
            : (state.schemaLabel.isEmpty ? state.preedit : state.schemaLabel + " · " + state.preedit)
        display.header = header
        gridHeader = header
        display.items = state.candidates
        display.labels = state.candidates.indices.map { i in
            i < state.selectLabels.count ? state.selectLabels[i] : String(i + 1)
        }
        display.highlighted = state.highlighted
        display.layout = services.prefs.verticalCandidates ? .vertical : .horizontal
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        services.candidates.show(display, caret: rect)
    }

    /// 切走或点到别处时：把还没选词的拼音原样上屏
    @MainActor
    private func finishComposition(_ client: TextClient) {
        let services = AppServices.shared
        if let raw = services.engine.commitRaw() {
            client.insertText(TextSanitizer.sanitize(raw, singleLine: true),
                              replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        } else if hasMarkedText {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        hasMarkedText = false
        grid = nil
        services.candidates.hide()
    }

    /// 鼠标点选：网格打开时按网格位置选，否则按当前页
    @MainActor
    private func selectCandidate(_ index: Int) {
        guard let client = self.client() else { return }
        let engine = AppServices.shared.engine
        if let g = grid {
            grid = nil
            apply(engine.select(globalIndex: g.offset + index), client: client)
        } else {
            apply(engine.select(index: index), client: client)
        }
    }



    // MARK: 输入法菜单（菜单栏里的输入法图标）

    override func menu() -> NSMenu! {
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated { menu = buildMenu() }
        return menu
    }

    @MainActor
    private func buildMenu() -> NSMenu {
        let services = AppServices.shared
        let menu = NSMenu(title: "SayFlow")
        let engineLine = NSMenuItem(title: services.engine.isReady
                                    ? "打字：" + services.prefs.schema.title
                                    : "打字：英文直通（引擎未加入）", action: nil, keyEquivalent: "")
        engineLine.isEnabled = false
        menu.addItem(engineLine)
        menu.addItem(.separator())

        let rewrite = NSMenuItem(title: "AI 改写选中的文字（⌃⌥R）", action: #selector(menuRewrite(_:)), keyEquivalent: "")
        rewrite.isEnabled = services.prefs.rewriteEnabled
        menu.addItem(rewrite)
        let voice = NSMenuItem(title: services.prefs.voiceEnabled ? "语音输入：按住右 Command 说话" : "语音输入：已关闭",
                               action: nil, keyEquivalent: "")
        voice.isEnabled = false
        menu.addItem(voice)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "SayFlow 设置…", action: #selector(menuSettings(_:)), keyEquivalent: ""))
        let about = NSMenuItem(title: "SayFlow " + AppInfo.version, action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        return menu
    }


    @objc func menuRewrite(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let client = self.client() else { return }
            AppServices.shared.rewrite.start(target: TextTarget(client: client))
        }
    }

    @objc func menuSettings(_ sender: Any?) {
        MainActor.assumeIsolated { AppServices.shared.openSettings() }
    }
}
