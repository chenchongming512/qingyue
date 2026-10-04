// 轻阅 · AI 客户端：Ollama 原生协议 + OpenAI 兼容协议，支持流式、重试与取消

import Foundation

struct ChatMessage {
    var role: String          // system / user / assistant
    var content: String
    var images: [Data] = []   // 视觉输入（PNG/JPEG 原始数据）

    static func system(_ s: String) -> ChatMessage { .init(role: "system", content: s) }
    static func user(_ s: String) -> ChatMessage { .init(role: "user", content: s) }
    static func user(_ s: String, images: [Data]) -> ChatMessage { .init(role: "user", content: s, images: images) }
}

struct ChatUsage {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

struct ChatReply {
    var text: String
    var usage: ChatUsage?
    var model: String
    var seconds: Double
}

enum AIError: LocalizedError {
    case invalidURL(String)
    case noKey(String)
    case noModel
    case http(Int, String)
    case emptyReply
    case decode(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let s):    return "接口地址无效：\(s)"
        case .noKey(let name):      return "「\(name)」还没有填写 API Key，请在 AI 中心补上"
        case .noModel:              return "还没有选择模型，请在 AI 中心选择"
        case .http(let code, let body):
            let brief = body.replacingOccurrences(of: "\n", with: " ").prefix(180)
            return "HTTP \(code)：\(brief)"
        case .emptyReply:           return "模型返回了空内容"
        case .decode(let s):        return "返回内容无法解析：\(s)"
        case .cancelled:            return "已取消"
        }
    }
}

final class AIClient {
    static let shared = AIClient()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: URL 组装

    private func url(_ base: String, _ path: String, kind: ProviderKind) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        if kind == .openAICompatible, s.hasSuffix("/chat/completions") {
            return URL(string: s)
        }
        return URL(string: s + path)
    }

    private func request(url: URL, kind: ProviderKind, key: String, body: [String: Any], stream: Bool) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if kind == .openAICompatible, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    private func body(provider: AIProvider, model: String, messages: [ChatMessage],
                      temperature: Double, maxTokens: Int?, stream: Bool) -> [String: Any] {
        switch provider.kind {
        case .ollama:
            var msgs: [[String: Any]] = []
            for m in messages {
                var d: [String: Any] = ["role": m.role, "content": m.content]
                if !m.images.isEmpty { d["images"] = m.images.map { $0.base64EncodedString() } }
                msgs.append(d)
            }
            var options: [String: Any] = ["temperature": temperature]
            if let maxTokens { options["num_predict"] = maxTokens }
            // 关闭思考链，避免把推理过程混进译文；老版本忽略未知字段
            return ["model": model, "messages": msgs, "stream": stream,
                    "options": options, "think": false]

        case .openAICompatible:
            var msgs: [[String: Any]] = []
            for m in messages {
                if m.images.isEmpty {
                    msgs.append(["role": m.role, "content": m.content])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": m.content]]
                    for img in m.images {
                        parts.append(["type": "image_url",
                                      "image_url": ["url": "data:image/png;base64,\(img.base64EncodedString())"]])
                    }
                    msgs.append(["role": m.role, "content": parts])
                }
            }
            var b: [String: Any] = ["model": model, "messages": msgs,
                                    "temperature": temperature, "stream": stream]
            if let maxTokens { b["max_tokens"] = maxTokens }
            return b
        }
    }

    // MARK: 调试（设 QY_DEBUG_AI=1 后会把请求与响应落到 /tmp，便于给服务商提工单）

    private func dumpDebug(url: URL, payload: [String: Any]) {
        guard ProcessInfo.processInfo.environment["QY_DEBUG_AI"] == "1" else { return }
        let dbg: [String: Any] = ["url": url.absoluteString, "body": payload]
        if let d = try? JSONSerialization.data(withJSONObject: dbg, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? d.write(to: URL(fileURLWithPath: "/tmp/qy-last-request.json"))
        }
    }

    private func dumpResponse(_ data: Data) {
        guard ProcessInfo.processInfo.environment["QY_DEBUG_AI"] == "1" else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/qy-last-response.json"))
    }

    // MARK: 一次调用（带重试）

    func chat(provider: AIProvider, model: String, key: String, messages: [ChatMessage],
              temperature: Double = 0.2, maxTokens: Int? = nil) async throws -> ChatReply {
        guard !model.isEmpty else { throw AIError.noModel }
        if !provider.isLocal && key.isEmpty { throw AIError.noKey(provider.name) }
        let path = provider.kind == .ollama ? "/api/chat" : "/chat/completions"
        guard let u = url(provider.baseURL, path, kind: provider.kind) else {
            throw AIError.invalidURL(provider.baseURL)
        }
        let payload = body(provider: provider, model: model, messages: messages,
                           temperature: temperature, maxTokens: maxTokens, stream: false)
        dumpDebug(url: u, payload: payload)

        var lastError: Error = AIError.emptyReply
        for attempt in 0..<3 {
            if Task.isCancelled { throw AIError.cancelled }
            let started = Date()
            do {
                let req = request(url: u, kind: provider.kind, key: key, body: payload, stream: false)
                let (data, resp) = try await session.data(for: req)
                dumpResponse(data)
                let seconds = Date().timeIntervalSince(started)
                guard let http = resp as? HTTPURLResponse else { throw AIError.emptyReply }
                if http.statusCode >= 400 {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    // 429 / 5xx 重试
                    if (http.statusCode == 429 || http.statusCode >= 500), attempt < 2 {
                        lastError = AIError.http(http.statusCode, text)
                        try? await Task.sleep(nanoseconds: UInt64(700_000_000 * (attempt + 1)))
                        continue
                    }
                    throw AIError.http(http.statusCode, text)
                }
                let reply = try parseReply(data, provider: provider, model: model, seconds: seconds)
                return reply
            } catch let e as AIError {
                if case .http(let code, _) = e, code == 429 || code >= 500 {
                    lastError = e
                    continue
                }
                throw e
            } catch is CancellationError {
                throw AIError.cancelled
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private func parseReply(_ data: Data, provider: AIProvider, model: String, seconds: Double) throws -> ChatReply {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decode(String(data: data.prefix(200), encoding: .utf8) ?? "二进制")
        }
        switch provider.kind {
        case .ollama:
            let msg = obj["message"] as? [String: Any]
            let text = (msg?["content"] as? String) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AIError.emptyReply }
            var usage: ChatUsage?
            if let pc = obj["prompt_eval_count"] as? Int, let ec = obj["eval_count"] as? Int {
                usage = ChatUsage(promptTokens: pc, completionTokens: ec, totalTokens: pc + ec)
            }
            return ChatReply(text: text, usage: usage, model: (obj["model"] as? String) ?? model, seconds: seconds)
        case .openAICompatible:
            let choices = obj["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            var text = (msg?["content"] as? String) ?? ""
            if text.isEmpty, let arr = msg?["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["text"] as? String }.joined()
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
                    throw AIError.decode(m)
                }
                throw AIError.emptyReply
            }
            var usage: ChatUsage?
            if let u = obj["usage"] as? [String: Any] {
                usage = ChatUsage(promptTokens: u["prompt_tokens"] as? Int,
                                  completionTokens: u["completion_tokens"] as? Int,
                                  totalTokens: u["total_tokens"] as? Int)
            }
            return ChatReply(text: text, usage: usage, model: (obj["model"] as? String) ?? model, seconds: seconds)
        }
    }

    // MARK: 流式调用

    /// 逐段吐出增量文本，用于「边翻边看」的即时反馈
    func chatStream(provider: AIProvider, model: String, key: String, messages: [ChatMessage],
                    temperature: Double = 0.2, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !model.isEmpty else { throw AIError.noModel }
                    if !provider.isLocal && key.isEmpty { throw AIError.noKey(provider.name) }
                    let path = provider.kind == .ollama ? "/api/chat" : "/chat/completions"
                    guard let u = url(provider.baseURL, path, kind: provider.kind) else {
                        throw AIError.invalidURL(provider.baseURL)
                    }
                    let payload = body(provider: provider, model: model, messages: messages,
                                       temperature: temperature, maxTokens: maxTokens, stream: true)
                    let req = request(url: u, kind: provider.kind, key: key, body: payload, stream: true)
                    let (bytes, resp) = try await session.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                        var raw = ""
                        for try await line in bytes.lines { raw += line; if raw.count > 400 { break } }
                        throw AIError.http(http.statusCode, raw)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        var jsonText = trimmed
                        if trimmed.hasPrefix("data:") {
                            jsonText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if jsonText == "[DONE]" { break }
                        }
                        guard let d = jsonText.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if provider.kind == .ollama {
                            if let msg = obj["message"] as? [String: Any], let piece = msg["content"] as? String {
                                continuation.yield(piece)
                            }
                            if (obj["done"] as? Bool) == true { break }
                        } else {
                            if let choices = obj["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let piece = delta["content"] as? String {
                                continuation.yield(piece)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 模型列表 / 连接测试

    func listModels(provider: AIProvider, key: String = "") async throws -> [String] {
        guard let u = url(provider.baseURL, provider.kind == .ollama ? "/api/tags" : "/models",
                          kind: provider.kind) else { throw AIError.invalidURL(provider.baseURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        if provider.kind == .openAICompatible, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.decode("模型列表格式异常")
        }
        if provider.kind == .ollama {
            let models = obj["models"] as? [[String: Any]] ?? []
            return models.compactMap { $0["name"] as? String }.sorted()
        } else {
            let arr = obj["data"] as? [[String: Any]] ?? []
            return arr.compactMap { $0["id"] as? String }.sorted()
        }
    }

    func testConnection(provider: AIProvider, model: String, key: String) async throws -> String {
        if model.isEmpty {
            let models = try await listModels(provider: provider, key: key)
            return models.isEmpty ? "服务可访问，但没有取到模型列表" : "服务可访问，共 \(models.count) 个模型"
        }
        let reply = try await chat(provider: provider, model: model, key: key,
                                   messages: [.user("只回复两个字：可用")], temperature: 0, maxTokens: 16)
        return "连接正常（\(reply.model) · \(String(format: "%.1f", reply.seconds))s）：\(reply.text.prefix(20))"
    }
}
