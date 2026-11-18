import Foundation

/// multipart/form-data 请求体（语音识别接口用）
public struct MultipartForm {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "SayFlowBoundary-" + UUID().uuidString) {
        self.boundary = boundary
    }

    public var contentType: String {
        return "multipart/form-data; boundary=" + boundary
    }

    public mutating func addField(_ name: String, _ value: String) {
        append("--" + boundary + "\r\n")
        append("Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        append("--" + boundary + "\r\n")
        append("Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\"\r\n")
        append("Content-Type: " + contentType + "\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    public func finished() -> Data {
        var result = body
        result.append(Data(("--" + boundary + "--\r\n").utf8))
        return result
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }
}

/// 请求体构造
public enum GatewayRequests {
    public static func transcriptionForm(audio: Data, dictionary: [String], model: String) -> MultipartForm {
        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "json")
        form.addField("language", GatewayConfig.language)
        if !dictionary.isEmpty {
            form.addField("prompt", dictionary.joined(separator: ", "))
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: audio)
        return form
    }

    public static func chatBody(systemPrompt: String, transcript: String, model: String) throws -> Data {
        return try chatBody(systemPrompt: systemPrompt,
                            userContent: PromptBuilder.userMessage(transcript: transcript),
                            model: model)
    }

    public static func chatBody(systemPrompt: String, userContent: String, model: String, temperature: Double = 0.2) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// 「测试连接」用的最小请求
    public static func pingBody(model: String) throws -> Data {
        let object: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

public enum GatewayParseError: Error {
    case missingText
}

/// 响应解析
public enum GatewayResponse {
    public static func transcriptionText(from data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["text"] as? String else {
            throw GatewayParseError.missingText
        }
        return text
    }

    public static func chatText(from data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw GatewayParseError.missingText
        }
        if let text = message["content"] as? String {
            return clean(text)
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return clean(text) }
        }
        throw GatewayParseError.missingText
    }

    public static func isValidChat(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["choices"] is [Any]
    }

    public static func errorMessage(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(150))
        }
        if let message = object["error"] as? String { return String(message.prefix(150)) }
        if let message = object["message"] as? String { return String(message.prefix(150)) }
        return nil
    }

    /// 去掉推理模型的思考过程和提示词里的标签
    public static func clean(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        result = result.replacingOccurrences(of: "<transcript>", with: "")
        result = result.replacingOccurrences(of: "</transcript>", with: "")
        result = result.replacingOccurrences(of: "<text>", with: "")
        result = result.replacingOccurrences(of: "</text>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
