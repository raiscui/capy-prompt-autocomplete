import Foundation

struct AliyunSpeech {
    private static let endpoint = URL(string: "https://token-plan.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer")!

    private struct Settings: Decodable {
        var speechVoice: String?
        var speechCredentialFile: String?
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func settings() throws -> Settings {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CapyPrompts/config.json")
        do {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Settings()
        } catch {
            throw Failure("无法读取 CapyPrompts 朗读配置")
        }
    }

    static func selectedVoice() throws -> String {
        let voice = try settings().speechVoice?.trimmingCharacters(in: .whitespacesAndNewlines)
        return voice.flatMap { $0.isEmpty ? nil : $0 } ?? "longanlingxin"
    }

    private static func planKey(_ value: String?) -> String? {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              key.hasPrefix("sk-sp-"), key.count > 6,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return key
    }

    private static func credential() throws -> String {
        let names = ["DASHSCOPE_API_KEY", "YINO_QWEN_TOKEN_PLAN_KEY"]
        let environment = ProcessInfo.processInfo.environment
        for name in names {
            if let key = planKey(environment[name]) { return key }
        }
        if let path = try settings().speechCredentialFile {
            guard path.hasPrefix("/"), let file = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw Failure("无法读取配置指定的朗读凭据文件")
            }
            for line in file.split(whereSeparator: \.isNewline) {
                var assignment = line.trimmingCharacters(in: .whitespaces)[...]
                if assignment.hasPrefix("export"), assignment.dropFirst(6).first?.isWhitespace == true {
                    assignment = assignment.dropFirst(6).drop(while: \.isWhitespace)
                }
                guard let equals = assignment.firstIndex(of: "="),
                      names.contains(assignment[..<equals].trimmingCharacters(in: .whitespaces)) else { continue }
                let rhs = assignment[assignment.index(after: equals)...].drop(while: \.isWhitespace)
                var value = rhs.prefix(while: { !$0.isWhitespace })
                let tail = rhs.dropFirst(value.count).drop(while: \.isWhitespace)
                guard tail.isEmpty || tail.first == "#" else { continue }
                if let quote = value.first, quote == "'" || quote == "\"" {
                    guard value.count >= 2, value.last == quote else { continue }
                    value = value.dropFirst().dropLast()
                }
                if let key = planKey(String(value)) { return key }
            }
        }
        throw Failure("未找到有效的 Token Plan 套餐密钥")
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: result.isEmpty ? 60 : 180, limitedBy: text.endIndex) ?? text.endIndex
            var cut = end
            if end < text.endIndex {
                let window = text[start..<end]
                if let boundary = window.lastIndex(where: { $0.isNewline || "。！？.!?".contains($0) })
                    ?? window.lastIndex(where: \.isPunctuation)
                    ?? window.lastIndex(where: \.isWhitespace) {
                    cut = text.index(after: boundary)
                }
            }
            result.append(String(text[start..<cut]))
            start = cut
        }
        return result
    }

    private func fetch(_ request: URLRequest, timeout: TimeInterval) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw Failure("无效的语音服务响应") }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure("语音服务请求失败, HTTP \(http.statusCode)")
            }
            return data
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw Failure(error.code == .timedOut ? "语音服务请求超时" : "语音服务网络请求失败")
        } catch let error as Failure {
            throw error
        } catch {
            try Task.checkCancellation()
            throw Failure("语音服务请求失败")
        }
    }

    func synthesize(_ text: String, voice: String) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try Self.credential())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "qwen-audio-3.0-tts-plus",
            "input": ["text": text, "voice": voice, "format": "wav", "sample_rate": 24000] as [String: Any]
        ] as [String: Any])
        let payload = try await fetch(request, timeout: 120)
        struct Reply: Decodable {
            struct Output: Decodable {
                struct Audio: Decodable { let url: String }
                let audio: Audio
            }
            let output: Output
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: payload),
              var parts = URLComponents(string: reply.output.audio.url),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.hasSuffix(".oss-cn-beijing.aliyuncs.com"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw Failure("语音服务返回了无效的音频地址") }
        parts.scheme = "https"
        guard let url = parts.url else { throw Failure("语音服务返回了无效的音频地址") }
        try Task.checkCancellation()
        let wav = try await fetch(URLRequest(url: url, timeoutInterval: 60), timeout: 60)
        guard wav.count >= 44, wav.prefix(4).elementsEqual("RIFF".utf8),
              wav.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8) else {
            throw Failure("语音服务返回了无效的 WAV 音频")
        }
        return wav
    }
}
