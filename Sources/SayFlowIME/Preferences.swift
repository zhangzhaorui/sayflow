import Foundation
import SayFlowCore

/// 输入方案
enum InputSchema: String, CaseIterable {
    case pinyin = "rime_ice"
    case flypy = "double_pinyin_flypy"
    case ziranma = "double_pinyin"
    case microsoft = "double_pinyin_mspy"
    case wubi86 = "wubi86"
    case wubiPinyin = "wubi86_pinyin"

    var title: String {
        switch self {
        case .pinyin: return "全拼（整句）"
        case .flypy: return "小鹤双拼"
        case .ziranma: return "自然码双拼"
        case .microsoft: return "微软双拼"
        case .wubi86: return "五笔 86"
        case .wubiPinyin: return "五笔 86 + 拼音混输"
        }
    }

    var shortTitle: String {
        switch self {
        case .pinyin: return "全拼"
        case .flypy: return "小鹤"
        case .ziranma: return "自然码"
        case .microsoft: return "微软"
        case .wubi86: return "五笔"
        case .wubiPinyin: return "五笔+拼音"
        }
    }
}

/// 用户偏好，存在 App 沙盒容器里的 UserDefaults。不保存任何输入内容。
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let schema = "inputSchema"
        static let pageSize = "pageSize"
        static let learning = "learningEnabled"
        static let vertical = "verticalCandidates"
        static let voice = "voiceEnabled"
        static let cleanup = "cleanupEnabled"
        static let rewrite = "rewriteEnabled"
        static let baseURL = "gatewayBaseURL"
        static let sttModel = "gatewaySTTModel"
        static let cleanupModel = "gatewayCleanupModel"
        static let rewriteModel = "gatewayRewriteModel"
        static let deviceUID = "deviceUID"
        static let style = "cleanupStyle"
        static let dictionary = "dictionary"
    }

    private init() {
        defaults.register(defaults: [
            Key.schema: InputSchema.pinyin.rawValue,
            Key.pageSize: 7,
            Key.learning: true,
            // 联网功能默认关闭：全关时是纯本地输入法，不联网、不申请麦克风
            Key.voice: false,
            Key.cleanup: true,
            Key.rewrite: false,
            Key.style: CleanupStyle.auto.rawValue,
        ])
    }

    // MARK: 打字

    var schema: InputSchema {
        get { InputSchema(rawValue: defaults.string(forKey: Key.schema) ?? "") ?? .pinyin }
        set { defaults.set(newValue.rawValue, forKey: Key.schema) }
    }

    var pageSize: Int {
        get { min(max(defaults.integer(forKey: Key.pageSize), 3), 9) }
        set { defaults.set(min(max(newValue, 3), 9), forKey: Key.pageSize) }
    }

    /// 候选竖排（默认横排）
    var verticalCandidates: Bool {
        get { defaults.bool(forKey: Key.vertical) }
        set { defaults.set(newValue, forKey: Key.vertical) }
    }

    var learningEnabled: Bool {
        get { defaults.bool(forKey: Key.learning) }
        set { defaults.set(newValue, forKey: Key.learning) }
    }

    // MARK: 语音与 AI

    var voiceEnabled: Bool {
        get { defaults.bool(forKey: Key.voice) }
        set { defaults.set(newValue, forKey: Key.voice) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanup) }
        set { defaults.set(newValue, forKey: Key.cleanup) }
    }

    var rewriteEnabled: Bool {
        get { defaults.bool(forKey: Key.rewrite) }
        set { defaults.set(newValue, forKey: Key.rewrite) }
    }

    /// 三个联网功能是否全部关闭
    var allNetworkFeaturesOff: Bool { !voiceEnabled && !rewriteEnabled }

    var gateway: GatewayEndpoint {
        get {
            let fallback = GatewayEndpoint.builtinDefault
            let result = GatewayEndpoint.make(baseURL: defaults.string(forKey: Key.baseURL) ?? fallback.baseURL,
                                              sttModel: defaults.string(forKey: Key.sttModel) ?? "",
                                              cleanupModel: defaults.string(forKey: Key.cleanupModel) ?? "",
                                              rewriteModel: defaults.string(forKey: Key.rewriteModel) ?? "")
            if case .success(let endpoint) = result { return endpoint }
            return fallback
        }
        set {
            defaults.set(newValue.baseURL, forKey: Key.baseURL)
            defaults.set(newValue.sttModel, forKey: Key.sttModel)
            defaults.set(newValue.cleanupModel, forKey: Key.cleanupModel)
            defaults.set(newValue.rewriteModel, forKey: Key.rewriteModel)
        }
    }

    var deviceUID: String? {
        get { defaults.string(forKey: Key.deviceUID) }
        set { defaults.set(newValue, forKey: Key.deviceUID) }
    }

    var cleanupStyle: CleanupStyle {
        get { CleanupStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    var dictionary: [String] {
        get { DictionaryParser.parse(defaults.string(forKey: Key.dictionary) ?? "") }
        set { defaults.set(DictionaryParser.display(newValue), forKey: Key.dictionary) }
    }
}
