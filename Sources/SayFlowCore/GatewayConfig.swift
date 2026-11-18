import Foundation

/// 网关默认值和各种阈值。地址和三个模型 ID 可以在设置里修改（见 GatewayEndpoint），这里是默认值。
public enum GatewayConfig {
    public static let defaultBaseURL = ""
    public static let defaultSTTModel = "qwen3-asr-1.7b"
    public static let defaultCleanupModel = "gemini-3.1-flash-lite"
    public static let defaultRewriteModel = "gemini-3.1-flash-lite"

    public static let transcriptionPath = "/v1/audio/transcriptions"
    public static let chatPath = "/v1/chat/completions"

    public static let language = "zh"

    /// 请求超时（秒）
    public static let sttTimeout: TimeInterval = 60
    public static let cleanupTimeout: TimeInterval = 15
    public static let rewriteTimeout: TimeInterval = 40
    public static let pingTimeout: TimeInterval = 10
    /// 单个请求的总时限
    public static let resourceTimeout: TimeInterval = 120

    /// 录音
    public static let maxRecordingSeconds: TimeInterval = 180
    public static let minRecordingSeconds: TimeInterval = 0.4
    public static let tailSeconds: TimeInterval = 0.25
    /// 小于这个字节数视为没录到声音（WAV 头 44 字节）
    public static let minRecordingBytes = 2000

    /// 整理
    public static let cleanupMinChars = 6
    public static let maxExpandRatio = 1.5
    public static let maxExpandChars = 20

    /// 改写：选中文字最多这么多字
    public static let rewriteMaxChars = 4000
}

/// 当前使用的网关：地址 + 识别模型 + 整理模型 + 改写模型
public struct GatewayEndpoint: Equatable {
    public let baseURL: String
    public let sttModel: String
    public let cleanupModel: String
    public let rewriteModel: String

    public static let builtinDefault = GatewayEndpoint(baseURL: GatewayConfig.defaultBaseURL,
                                                       sttModel: GatewayConfig.defaultSTTModel,
                                                       cleanupModel: GatewayConfig.defaultCleanupModel,
                                                       rewriteModel: GatewayConfig.defaultRewriteModel)

    public init(baseURL: String, sttModel: String, cleanupModel: String, rewriteModel: String) {
        self.baseURL = baseURL
        self.sttModel = sttModel
        self.cleanupModel = cleanupModel
        self.rewriteModel = rewriteModel
    }

    /// 校验并创建。模型留空时用默认值；任何一项不合法返回错误说明
    public static func make(baseURL: String,
                            sttModel: String,
                            cleanupModel: String,
                            rewriteModel: String) -> Result<GatewayEndpoint, EndpointError> {
        guard let base = normalizeBaseURL(baseURL) else { return .failure(.badBaseURL) }
        let stt = orDefault(sttModel, GatewayConfig.defaultSTTModel)
        let cleanup = orDefault(cleanupModel, GatewayConfig.defaultCleanupModel)
        let rewrite = orDefault(rewriteModel, GatewayConfig.defaultRewriteModel)
        guard isValidModelID(stt) else { return .failure(.badSTTModel) }
        guard isValidModelID(cleanup) else { return .failure(.badCleanupModel) }
        guard isValidModelID(rewrite) else { return .failure(.badRewriteModel) }
        return .success(GatewayEndpoint(baseURL: base, sttModel: stt, cleanupModel: cleanup, rewriteModel: rewrite))
    }

    private static func orDefault(_ value: String, _ fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public enum EndpointError: Error, Equatable {
        case badBaseURL, badSTTModel, badCleanupModel, badRewriteModel

        public var message: String {
            let rule = "只能包含字母、数字和 . _ - : / @ +"
            switch self {
            case .badBaseURL: return "地址必须是 https:// 开头的网址，例如 https://api.example.com"
            case .badSTTModel: return "语音识别模型 ID 不正确：" + rule
            case .badCleanupModel: return "AI 整理模型 ID 不正确：" + rule
            case .badRewriteModel: return "AI 改写模型 ID 不正确：" + rule
            }
        }
    }

    /// 只接受 https；去掉末尾的 / 和 /v1（接口路径由程序拼接）；不允许账号密码、查询参数和锚点
    public static func normalizeBaseURL(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/v1") { value.removeLast(3) }
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return value
    }

    /// 模型 ID：1–128 个字符，只能是字母、数字和 . _ - : / @ +
    public static func isValidModelID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 128 else { return false }
        for s in scalars {
            switch s.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: continue
            case 0x2E, 0x5F, 0x2D, 0x3A, 0x2F, 0x40, 0x2B: continue   // . _ - : / @ +
            default: return false
            }
        }
        return true
    }

    /// 拼出接口地址；结果必须仍是 https，且主机名不变
    public func url(for path: String) -> URL? {
        guard let base = URL(string: baseURL),
              let url = URL(string: baseURL + path),
              url.scheme?.lowercased() == "https",
              url.host != nil, url.host == base.host else { return nil }
        return url
    }

    public var host: String {
        return URL(string: baseURL)?.host ?? baseURL
    }
}
