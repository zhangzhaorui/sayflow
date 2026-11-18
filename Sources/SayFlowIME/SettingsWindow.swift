import AppKit
import SayFlowCore

/// 设置窗口里的输入框只用英文键盘（网址、模型 ID、令牌都是英文），
/// 避免输入法在自己的窗口里处理自己的按键。
final class RomanFieldEditor: NSTextView {
    override var inputContext: NSTextInputContext? {
        let context = super.inputContext
        context?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        return context
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let services: AppServices
    private var prefs: Preferences { services.prefs }
    private var window: NSWindow!
    private let fieldEditor: RomanFieldEditor = {
        let editor = RomanFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    // 打字
    private let schemaPopup = NSPopUpButton()
    private let pageSizePopup = NSPopUpButton()
    private let verticalCheck = NSButton(checkboxWithTitle: "候选竖排显示（默认横排；打字时按 ↓ 展开 7×7 候选）", target: nil, action: nil)
    private let learningCheck = NSButton(checkboxWithTitle: "记住我常打的词（个人词频，只存在本机）", target: nil, action: nil)
    private let engineStatus = NSTextField(wrappingLabelWithString: "")


    // 语音与 AI
    private let voiceCheck = NSButton(checkboxWithTitle: "语音输入：按住右 Command 说话", target: nil, action: nil)
    private let cleanupCheck = NSButton(checkboxWithTitle: "AI 整理语音识别结果（去口头禅、补标点）", target: nil, action: nil)
    private let rewriteCheck = NSButton(checkboxWithTitle: "AI 改写选中的文字（⌃⌥R）", target: nil, action: nil)
    private let baseURLField = NSTextField()
    private let sttField = NSTextField()
    private let cleanupModelField = NSTextField()
    private let rewriteModelField = NSTextField()
    private let gatewayStatus = NSTextField(wrappingLabelWithString: "")
    private let tokenField = NSSecureTextField()
    private let tokenStatus = NSTextField(wrappingLabelWithString: "")
    private let devicePopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    private let dictionaryField = NSTextField()
    private let micStatus = NSTextField(labelWithString: "")

    init(services: AppServices) {
        self.services = services
        super.init()
        build()
    }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        return fieldEditor
    }

    // MARK: 布局

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "SayFlow 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let tabs = NSTabView()
        tabs.addTabViewItem(tab("打字", typingPane()))
        tabs.addTabViewItem(tab("语音与 AI", aiPane()))
        tabs.addTabViewItem(tab("隐私", privacyPane()))
        window.contentView = tabs
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        item.view = container
        return item
    }

    private func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func row(_ label: String, _ control: NSView, width: CGFloat? = nil) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if let width { control.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let s = NSStackView(views: [title, control])
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 560
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        return NSButton(title: title, target: self, action: action)
    }

    private func typingPane() -> NSView {
        for schema in InputSchema.allCases {
            schemaPopup.addItem(withTitle: schema.title)
            schemaPopup.lastItem?.representedObject = schema.rawValue
        }
        schemaPopup.target = self
        schemaPopup.action = #selector(typingChanged)
        for n in 5...9 {
            pageSizePopup.addItem(withTitle: "\(n) 个")
            pageSizePopup.lastItem?.tag = n
        }
        pageSizePopup.target = self
        pageSizePopup.action = #selector(typingChanged)
        learningCheck.target = self
        learningCheck.action = #selector(typingChanged)
        verticalCheck.target = self
        verticalCheck.action = #selector(typingChanged)
        engineStatus.preferredMaxLayoutWidth = 560
        return stack([
            row("输入方案", schemaPopup, width: 200),
            verticalCheck,
            learningCheck,
            button("清空词库…", #selector(clearDictionary)),
            hint("Shift 切换中英文。横排每页 8 个候选，数字键选词；打字时按 ↓ 展开 7×7 候选，方向键选择、回车上屏。双拼可选小鹤、自然码、微软。\n「五笔 86 + 拼音混输」：不会拆的字直接打全拼，候选旁会显示它的五笔编码；纯五笔下也可以先按 z 再打拼音查字。\n词库只存在本机，不上传。"),
            engineStatus,
        ])
    }

    private func aiPane() -> NSView {
        for check in [voiceCheck, cleanupCheck, rewriteCheck] {
            check.target = self
            check.action = #selector(featuresChanged)
        }
        baseURLField.placeholderString = "https://api.example.com"
        sttField.placeholderString = GatewayConfig.defaultSTTModel + "（默认）"
        cleanupModelField.placeholderString = GatewayConfig.defaultCleanupModel + "（默认）"
        rewriteModelField.placeholderString = GatewayConfig.defaultRewriteModel + "（默认）"
        tokenField.placeholderString = "粘贴你的 API Key"
        for popupChoice in CleanupStyle.allCases {
            stylePopup.addItem(withTitle: popupChoice.title)
            stylePopup.lastItem?.representedObject = popupChoice.rawValue
        }
        stylePopup.target = self
        stylePopup.action = #selector(voiceOptionsChanged)
        devicePopup.target = self
        devicePopup.action = #selector(voiceOptionsChanged)
        dictionaryField.placeholderString = "例如：Claude Code, New API, SayFlow"
        dictionaryField.target = self
        dictionaryField.action = #selector(voiceOptionsChanged)

        let gatewayButtons = NSStackView(views: [button("保存网关设置", #selector(saveGateway)),
                                                 button("恢复默认", #selector(resetGateway)),
                                                 button("测试连接", #selector(testConnection))])
        gatewayButtons.orientation = .horizontal
        let tokenButtons = NSStackView(views: [tokenField, button("保存", #selector(saveToken)), button("删除", #selector(deleteToken))])
        tokenButtons.orientation = .horizontal
        tokenField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let micRow = NSStackView(views: [micStatus, button("去授权", #selector(openMicSettings))])
        micRow.orientation = .horizontal
        gatewayStatus.preferredMaxLayoutWidth = 560
        tokenStatus.preferredMaxLayoutWidth = 560

        return stack([
            voiceCheck, cleanupCheck, rewriteCheck,
            hint("三项都关闭时，SayFlow 是纯本地输入法：不联网，也不申请麦克风。"),
            row("网关地址", baseURLField, width: 340),
            row("语音识别模型", sttField, width: 340),
            row("AI 整理模型", cleanupModelField, width: 340),
            row("AI 改写模型", rewriteModelField, width: 340),
            gatewayButtons,
            gatewayStatus,
            row("令牌", tokenButtons),
            tokenStatus,
            row("录音设备", devicePopup, width: 300),
            row("整理风格", stylePopup, width: 300),
            row("专有名词", dictionaryField, width: 340),
            row("麦克风", micRow),
        ], spacing: 8)
    }

    private func privacyPane() -> NSView {
        let lines = [
            "打字：全部在本机完成，不联网，不记录也不上传你打的字。个人词频只存在本机，可在「打字」里关闭或清空。",
            "语音输入（开启后）：只在你按住右 Command 时录音，松开后把这段录音发到你设置的网关转文字，录音文件用完立即删除。",
            "AI 整理（开启后）：把这段语音识别出的文字发到网关整理。",
            "AI 改写（开启后）：只在你按 ⌃⌥R 并选择改写方式后，把你选中的那段文字发到网关；结果先给你看，你确认后才替换。",
            "网关：你在「语音与 AI」里填写的地址，只用 https，不跟随重定向，每个请求都有超时。令牌保存在钥匙串里。",
            "不会做的事：不读取输入框里已有的文字（改写时只读你选中的部分），密码框里不工作，不经过剪贴板写入文字，没有自动更新、崩溃上报和使用统计，不写日志。",
        ]
        return stack(lines.map { line -> NSView in
            let label = NSTextField(wrappingLabelWithString: line)
            label.preferredMaxLayoutWidth = 560
            return label
        }, spacing: 12)
    }

    // MARK: 刷新

    private func refresh() {
        if let index = InputSchema.allCases.firstIndex(of: prefs.schema) { schemaPopup.selectItem(at: index) }
        learningCheck.state = prefs.learningEnabled ? .on : .off
        verticalCheck.state = prefs.verticalCandidates ? .on : .off
        engineStatus.stringValue = services.engine.statusText


        voiceCheck.state = prefs.voiceEnabled ? .on : .off
        cleanupCheck.state = prefs.cleanupEnabled ? .on : .off
        rewriteCheck.state = prefs.rewriteEnabled ? .on : .off
        cleanupCheck.isEnabled = prefs.voiceEnabled
        let g = prefs.gateway
        baseURLField.stringValue = g.baseURL
        sttField.stringValue = g.sttModel == GatewayConfig.defaultSTTModel ? "" : g.sttModel
        cleanupModelField.stringValue = g.cleanupModel == GatewayConfig.defaultCleanupModel ? "" : g.cleanupModel
        rewriteModelField.stringValue = g.rewriteModel == GatewayConfig.defaultRewriteModel ? "" : g.rewriteModel
        tokenStatus.stringValue = KeychainStore.hasKey ? "✅ 已保存令牌（存在钥匙串里）" : "还没有填写令牌：语音和 AI 功能需要令牌，纯打字不需要"
        tokenField.stringValue = ""

        devicePopup.removeAllItems()
        devicePopup.addItem(withTitle: "自动（有遥控器麦克风时优先用它）")
        devicePopup.lastItem?.representedObject = nil
        for device in AudioDevices.inputs() {
            devicePopup.addItem(withTitle: device.name)
            devicePopup.lastItem?.representedObject = device.uid
        }
        if let uid = prefs.deviceUID, let index = devicePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == uid }) {
            devicePopup.selectItem(at: index)
        } else {
            devicePopup.selectItem(at: 0)
        }
        if let index = CleanupStyle.allCases.firstIndex(of: prefs.cleanupStyle) { stylePopup.selectItem(at: index) }
        dictionaryField.stringValue = DictionaryParser.display(prefs.dictionary)
        refreshMic()
    }

    private func refreshMic() {
        switch Permissions.microphone() {
        case .granted: micStatus.stringValue = "✅ 已授权"
        case .notDetermined: micStatus.stringValue = prefs.voiceEnabled ? "第一次说话时会请求授权" : "不需要（语音输入已关闭）"
        case .denied: micStatus.stringValue = "❌ 未授权"
        }
    }

    // MARK: 动作

    @objc private func typingChanged() {
        if let raw = schemaPopup.selectedItem?.representedObject as? String, let schema = InputSchema(rawValue: raw) {
            prefs.schema = schema
        }
        prefs.learningEnabled = learningCheck.state == .on
        prefs.verticalCandidates = verticalCheck.state == .on
        services.settingsChanged()
        engineStatus.stringValue = services.engine.statusText
    }

    @objc private func clearDictionary() {
        let alert = NSAlert()
        alert.messageText = "清空本机词库？"
        alert.informativeText = "会删除 SayFlow 记住的个人词频，删除后不能恢复。系统自带的词库不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ok = services.engine.clearUserDictionary()
        engineStatus.stringValue = ok ? "已清空本机词库" : (services.engine.isReady ? "部分文件没能删除，请重试" : services.engine.statusText)
    }

    @objc private func featuresChanged() {
        prefs.voiceEnabled = voiceCheck.state == .on
        prefs.cleanupEnabled = cleanupCheck.state == .on
        prefs.rewriteEnabled = rewriteCheck.state == .on
        cleanupCheck.isEnabled = prefs.voiceEnabled
        if prefs.voiceEnabled, Permissions.microphone() == .notDetermined {
            Permissions.requestMicrophone { [weak self] _ in self?.refreshMic() }
        }
        refreshMic()
    }

    private func typedGateway() -> Result<GatewayEndpoint, GatewayEndpoint.EndpointError> {
        return GatewayEndpoint.make(baseURL: baseURLField.stringValue.isEmpty ? GatewayConfig.defaultBaseURL : baseURLField.stringValue,
                                    sttModel: sttField.stringValue,
                                    cleanupModel: cleanupModelField.stringValue,
                                    rewriteModel: rewriteModelField.stringValue)
    }

    @objc private func saveGateway() {
        switch typedGateway() {
        case .failure(let error):
            gatewayStatus.stringValue = "❌ " + error.message
        case .success(let endpoint):
            prefs.gateway = endpoint
            gatewayStatus.stringValue = "✅ 已保存：" + endpoint.host
            refresh()
        }
    }

    @objc private func resetGateway() {
        prefs.gateway = .builtinDefault
        gatewayStatus.stringValue = "已恢复默认网关和模型"
        refresh()
    }

    @objc private func testConnection() {
        guard case .success(let endpoint) = typedGateway() else {
            saveGateway()
            return
        }
        guard let key = KeychainStore.read() else {
            gatewayStatus.stringValue = "请先保存令牌"
            return
        }
        gatewayStatus.stringValue = "正在测试 " + endpoint.host + " …"
        services.gateway.ping(endpoint: endpoint, apiKey: key) { [weak self] result in
            switch result {
            case .success: self?.gatewayStatus.stringValue = "✅ 连接正常：" + endpoint.host
            case .failure(let error): self?.gatewayStatus.stringValue = "❌ " + error.message
            }
        }
    }

    @objc private func saveToken() {
        let key = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIKeyFormat.isValid(key) else {
            tokenStatus.stringValue = "❌ 令牌格式不对：只能包含字母、数字和 . _ -"
            return
        }
        guard KeychainStore.save(key) else {
            tokenStatus.stringValue = "❌ 写入钥匙串失败"
            return
        }
        tokenField.stringValue = ""
        tokenStatus.stringValue = "✅ 已保存令牌"
        testConnection()
    }

    @objc private func deleteToken() {
        KeychainStore.delete()
        tokenStatus.stringValue = "已删除令牌"
    }

    @objc private func voiceOptionsChanged() {
        prefs.deviceUID = devicePopup.selectedItem?.representedObject as? String
        if let raw = stylePopup.selectedItem?.representedObject as? String, let style = CleanupStyle(rawValue: raw) {
            prefs.cleanupStyle = style
        }
        prefs.dictionary = DictionaryParser.parse(dictionaryField.stringValue)
    }

    @objc private func openMicSettings() {
        Permissions.openMicrophoneSettings()
    }

    func windowWillClose(_ notification: Notification) {
        voiceOptionsChanged()
    }

}
