import Foundation

/// A validated destination. Credentials are stored separately in the Keychain.
struct RemoteConnection: Codable, Equatable {
    let endpoint: URL
    let label: String

    init(endpoint: URL, label: String) throws {
        guard Self.permits(endpoint), endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw RemoteError.configuration }
        self.endpoint = endpoint
        self.label = label
    }

    static func make(transport: String, direct: String, relay: String, device: String) throws -> RemoteConnection {
        if transport == "中继" {
            guard device.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  let url = URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/" + device + "/rpc") else {
                throw RemoteError.configuration
            }
            return try RemoteConnection(endpoint: url, label: device + " · 中继")
        }
        guard let url = URL(string: direct) else { throw RemoteError.configuration }
        return try RemoteConnection(endpoint: url, label: "安卓 · 直连")
    }

    static func permits(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.scheme == "https" { return true }
        guard url.scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127 || octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
    }
}

enum RemoteError: LocalizedError {
    case configuration, missingCredential, http(Int), malformed, message(String)
    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写有效的连接地址和设备 ID。公网地址须使用 HTTPS。"
        case .missingCredential: return "请填写访问令牌。"
        case .http(401), .http(403): return "配对令牌无效或已被撤销，请检查目标设备的连接配置。"
        case .http(504): return "目标设备离线或响应超时。任务可能已提交，请先查看已有任务，勿重复发送。"
        case .http(let code): return "远程连接失败，HTTP \(code)。"
        case .malformed: return "目标设备返回了无法识别的数据。"
        case .message(let message): return message
        }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class MCPClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 65
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        }
    }
    func call(_ name: String, arguments: [String: Any], connection: RemoteConnection, credential: String) async throws -> [String: Any] {
        guard RemoteConnection.permits(connection.endpoint) else { throw RemoteError.configuration }
        guard !credential.isEmpty, !credential.contains("\n"), !credential.contains("\r") else { throw RemoteError.missingCredential }
        var request = URLRequest(url: connection.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":UUID().uuidString,
            "method":"tools/call", "params":["name":name,"arguments":arguments]])
        let data:Data
        let response:URLResponse
        do {(data,response)=try await session.data(for:request)}
        catch {
            if name=="mika_run_task" {throw RemoteError.message("任务提交结果未确认，目标设备可能已开始执行。请先在连接页查看已有任务，避免重复提交。")}
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw RemoteError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw RemoteError.http(http.statusCode) }
        return try Self.decode(data, credential: credential)
    }
    static func decode(_ data: Data, credential: String = "") throws -> [String: Any] {
        guard data.count <= 2_097_152, let root = try JSONSerialization.jsonObject(with:data) as? [String: Any] else { throw RemoteError.malformed }
        func safe(_ value: Any?) -> String {
            let text = String((value as? String ?? "远程任务失败。").prefix(2000))
            return credential.isEmpty ? text : text.replacingOccurrences(of: credential, with: "***")
        }
        if let error = root["error"] as? [String: Any] { throw RemoteError.message(safe(error["message"])) }
        guard let result = root["result"] as? [String: Any] else { throw RemoteError.malformed }
        if result["isError"] as? Bool == true {
            throw RemoteError.message(safe((result["content"] as? [[String: Any]])?.first?["text"]))
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let content = result["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
              let bytes = text.data(using:.utf8), let value = try JSONSerialization.jsonObject(with:bytes) as? [String: Any] else { throw RemoteError.malformed }
        return value
    }
}

struct RemoteTaskRecord: Codable, Equatable {
    let id: String
    let chatID: String
    let goal: String
    let connection: RemoteConnection
    var conversation: String
    var status: String
    var progress: String
    var question: String
    var updatedAt: Date
    var interaction:PhoneInteraction?=nil
    var terminal: Bool { ["done", "failed", "cancelled"].contains(status) }
}
