import AppKit
import InputMethodKit
import SayFlowCore

enum AppInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.0.0"
    }
    static var connectionName: String {
        (Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String)
            ?? "com.sayflow.inputmethod.SayFlow_Connection"
    }
}

/// 输入法进程里的共享服务（所有输入框共用一份）
@MainActor
final class AppServices {
    static let shared = AppServices()

    let prefs = Preferences.shared
    let hud = HUD()
    let gateway = GatewayClient()
    lazy var engine: InputEngine = EngineFactory.make(prefs: prefs)
    lazy var voice = VoiceInput(prefs: prefs, gateway: gateway, hud: hud)
    lazy var rewrite = RewriteController(prefs: prefs, gateway: gateway, hud: hud)
    let candidates = CandidatePanel()
    private var settings: SettingsWindowController?

    func start() {
        TempFiles.cleanAll()
        _ = engine
    }

    func openSettings() {
        if settings == nil { settings = SettingsWindowController(services: self) }
        settings?.present()
    }

    /// 设置改了以后调用
    func settingsChanged() {
        engine.apply(schema: prefs.schema, pageSize: prefs.pageSize, learning: prefs.learningEnabled)
    }

    /// 关闭所有浮窗（切换输入框、切换输入法时）
    func hidePanels() {
        candidates.hide()
        rewrite.close()
    }
}
