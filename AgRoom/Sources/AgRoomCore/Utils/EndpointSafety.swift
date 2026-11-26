import Foundation

// MARK: - Endpoint Safety

/// 端点 URL 安全校验：携带 API Key/用户内容的端点必须 HTTPS，
/// 仅 localhost/127.0.0.1/::1 豁免 HTTP（本地 Ollama / LM Studio）。
/// 在发请求前统一强制校验，不依赖设置页 UI 警告。
public enum EndpointSafety {

    public enum SafetyError: LocalizedError {
        case insecureEndpoint(String)

        public var errorDescription: String? {
            switch self {
            case .insecureEndpoint(let endpoint):
                return "Endpoint must use HTTPS (local services like localhost are exempt): \(endpoint)"
            }
        }
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// 校验端点是否允许携带凭据；不允许则 throw
    public static func validate(_ endpoint: String) throws {
        guard let components = URLComponents(string: endpoint) else {
            throw SafetyError.insecureEndpoint(endpoint)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw SafetyError.insecureEndpoint(endpoint)
        }
        if scheme == "http" {
            guard let url = components.url, isLoopback(url) else {
                throw SafetyError.insecureEndpoint(endpoint)
            }
        }
    }
}
