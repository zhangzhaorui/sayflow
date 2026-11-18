import Foundation
import SayFlowCore

enum GatewayError: Error {
    case invalidKey
    case badAddress
    case network(String)
    case timeout
    case http(Int, String?)
    case badResponse

    var message: String {
        switch self {
        case .invalidKey: return "令牌缺失或格式不正确"
        case .badAddress: return "网关地址不可用"
        case .network(let reason): return "网络错误：" + reason
        case .timeout: return "请求超时"
        case .http(let code, let detail):
            if code == 401 { return "令牌无效或已停用（401）" }
            if code == 429 { return "调用太频繁或额度用完（429）" }
            return "网关返回 \(code)" + (detail.map { "：" + $0 } ?? "")
        case .badResponse: return "网关返回的内容无法解析"
        }
    }
}

/// 只连设置里配置的网关（必须 https）的两个固定接口；不跟随重定向，不缓存，不存 Cookie，有超时。
final class GatewayClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = GatewayConfig.resourceTimeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 禁止重定向，保证只连配置的网关
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func transcribe(fileURL: URL,
                    endpoint: GatewayEndpoint,
                    apiKey: String,
                    dictionary: [String],
                    completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) {
        let audio: Data
        do {
            audio = try Data(contentsOf: fileURL)
        } catch {
            onMain { completion(.failure(.badResponse)) }
            return
        }
        let form = GatewayRequests.transcriptionForm(audio: audio, dictionary: dictionary, model: endpoint.sttModel)
        guard var request = makeRequest(endpoint: endpoint, path: GatewayConfig.transcriptionPath, apiKey: apiKey,
                                        timeout: GatewayConfig.sttTimeout, completion: completion) else { return }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        send(request, completion: completion) { data in
            try GatewayResponse.transcriptionText(from: data)
        }
    }

    func cleanup(transcript: String,
                 systemPrompt: String,
                 endpoint: GatewayEndpoint,
                 apiKey: String,
                 completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) {
        chat(systemPrompt: systemPrompt,
             userContent: PromptBuilder.userMessage(transcript: transcript),
             model: endpoint.cleanupModel,
             timeout: GatewayConfig.cleanupTimeout,
             endpoint: endpoint, apiKey: apiKey, completion: completion)
    }

    func rewrite(text: String,
                 action: RewriteAction,
                 dictionary: [String],
                 endpoint: GatewayEndpoint,
                 apiKey: String,
                 completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) {
        chat(systemPrompt: RewriteAction.systemPrompt(action, dictionary: dictionary),
             userContent: RewriteAction.userMessage(text),
             model: endpoint.rewriteModel,
             timeout: GatewayConfig.rewriteTimeout,
             endpoint: endpoint, apiKey: apiKey, completion: completion)
    }

    private func chat(systemPrompt: String,
                      userContent: String,
                      model: String,
                      timeout: TimeInterval,
                      endpoint: GatewayEndpoint,
                      apiKey: String,
                      completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) {
        guard var request = makeRequest(endpoint: endpoint, path: GatewayConfig.chatPath, apiKey: apiKey,
                                        timeout: timeout, completion: completion) else { return }
        guard let body = try? GatewayRequests.chatBody(systemPrompt: systemPrompt, userContent: userContent, model: model) else {
            onMain { completion(.failure(.badResponse)) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        send(request, completion: completion) { data in
            try GatewayResponse.chatText(from: data)
        }
    }

    /// 「测试连接」：发一个最小的整理请求
    func ping(endpoint: GatewayEndpoint, apiKey: String, completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) {
        guard var request = makeRequest(endpoint: endpoint, path: GatewayConfig.chatPath, apiKey: apiKey,
                                        timeout: GatewayConfig.pingTimeout, completion: completion) else { return }
        guard let body = try? GatewayRequests.pingBody(model: endpoint.cleanupModel) else {
            onMain { completion(.failure(.badResponse)) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        send(request, completion: completion) { data in
            guard GatewayResponse.isValidChat(data) else { throw GatewayParseError.missingText }
            return "ok"
        }
    }

    // MARK: -

    private func makeRequest(endpoint: GatewayEndpoint,
                             path: String,
                             apiKey: String,
                             timeout: TimeInterval,
                             completion: @escaping @MainActor (Result<String, GatewayError>) -> Void) -> URLRequest? {
        guard APIKeyFormat.isValid(apiKey) else {
            onMain { completion(.failure(.invalidKey)) }
            return nil
        }
        guard let url = endpoint.url(for: path) else {
            onMain { completion(.failure(.badAddress)) }
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest,
                      completion: @escaping @MainActor (Result<String, GatewayError>) -> Void,
                      parse: @escaping @Sendable (Data) throws -> String) {
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<String, GatewayError>
            if let error = error as NSError? {
                if error.code == NSURLErrorTimedOut {
                    result = .failure(.timeout)
                } else {
                    result = .failure(.network(error.localizedDescription))
                }
            } else if let http = response as? HTTPURLResponse, let data {
                if http.statusCode == 200 {
                    do {
                        result = .success(try parse(data))
                    } catch {
                        result = .failure(.badResponse)
                    }
                } else {
                    result = .failure(.http(http.statusCode, GatewayResponse.errorMessage(from: data)))
                }
            } else {
                result = .failure(.badResponse)
            }
            onMain { completion(result) }
        }
        task.resume()
    }
}
