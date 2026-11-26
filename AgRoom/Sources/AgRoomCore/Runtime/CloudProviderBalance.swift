import Foundation
import CoreFoundation

// MARK: - Cloud Provider Balance

/// 账户余额查询（同模块扩展）。
///
/// 当前适配 DeepSeek 与 Kimi（Moonshot）的余额接口；其他端点暂不支持。
/// OpenAI 组织消费接口不等同于账户余额，官方端点只提供账单管理链接。
/// 与 `listModels()` 同构：GET + Bearer 认证 + 统一的错误映射，
/// 端点由对话端点按 host 推导，不落盘、不改数据库。
extension CloudProvider {

    /// 该端点所属厂商是否支持余额查询（按 host 判断，自定义端点同 host 亦生效）
    public static func supportsBalanceQuery(endpoint: String) -> Bool {
        (try? balanceURL(for: endpoint)) != nil
    }

    /// A fixed official dashboard link; never forward a configured endpoint,
    /// query or credentials to a browser. Relays keep their own billing identity.
    public static func billingManagementURL(endpoint: String) -> URL? {
        guard ModelPricingService.endpointBase(endpoint) == "https://api.openai.com/v1" else { return nil }
        return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
    }

    /// 查询当前账户余额
    public func fetchBalance() async throws -> ProviderBalance {
        try EndpointSafety.validate(endpoint)
        let url = try Self.balanceURL(for: endpoint)

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await boundedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(statusCode: -1, message: "Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw LLMError.invalidAPIKey
            }
            let message = Self.parseErrorMessage(data: data) ?? "HTTP \(httpResponse.statusCode)"
            throw LLMError.networkError(statusCode: httpResponse.statusCode, message: message)
        }

        guard let host = url.host?.lowercased() else {
            throw LLMError.responseParsingFailed(reason: "Cannot determine host from balance URL")
        }
        return try Self.parseBalance(data: data, host: host)
    }

    // MARK: - Endpoint

    /// 由对话端点推导余额端点（按 host 重建，避免对话路径变体差异）：
    /// - api.deepseek.com → `{scheme}://{host}/user/balance`
    /// - api.moonshot.cn / api.moonshot.ai → `{scheme}://{host}/v1/users/me/balance`
    /// 不支持的 host 抛 `LLMError.balanceUnsupported`
    static func balanceURL(for endpoint: String) throws -> URL {
        guard let components = URLComponents(string: endpoint),
              let scheme = components.scheme,
              let host = components.host?.lowercased() else {
            throw LLMError.balanceUnsupported
        }
        let path: String
        switch host {
        case "api.deepseek.com":
            path = "/user/balance"
        case "api.moonshot.cn", "api.moonshot.ai":
            path = "/v1/users/me/balance"
        default:
            throw LLMError.balanceUnsupported
        }
        guard let url = URL(string: "\(scheme)://\(host)\(path)") else {
            throw LLMError.balanceUnsupported
        }
        return url
    }

    // MARK: - Parsing

    static func parseBalance(data: Data, host: String) throws -> ProviderBalance {
        switch host {
        case "api.moonshot.cn", "api.moonshot.ai":
            return try parseKimiBalance(data: data, currency: host == "api.moonshot.ai" ? "USD" : "CNY")
        default:
            return try parseDeepSeekBalance(data: data)
        }
    }

    /// DeepSeek `GET /user/balance`：
    /// `{ is_available, balance_infos: [{ currency, total_balance, granted_balance, topped_up_balance }] }`
    static func parseDeepSeekBalance(data: Data) throws -> ProviderBalance {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            throw LLMError.responseParsingFailed(reason: "Unexpected DeepSeek balance response format")
        }
        let isAvailable = json["is_available"] as? Bool ?? true
        let items = infos.flatMap { info -> [ProviderBalance.Item] in
            let currency = info["currency"] as? String ?? "CNY"
            var result: [ProviderBalance.Item] = []
            if let total = info["total_balance"] as? String {
                result.append(.init(label: .total, amount: total, currency: currency))
            }
            if let granted = info["granted_balance"] as? String {
                result.append(.init(label: .granted, amount: granted, currency: currency))
            }
            if let toppedUp = info["topped_up_balance"] as? String {
                result.append(.init(label: .toppedUp, amount: toppedUp, currency: currency))
            }
            return result
        }
        return ProviderBalance(isAvailable: isAvailable, items: items)
    }

    /// Kimi `GET /v1/users/me/balance`：
    /// `{ code, data: { available_balance, voucher_balance, cash_balance } }`
    /// `code != 0` 视为失败；`available_balance <= 0` 表示无法继续调用推理 API
    static func parseKimiBalance(data: Data, currency: String = "CNY") throws -> ProviderBalance {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let info = json["data"] as? [String: Any] else {
            throw LLMError.responseParsingFailed(reason: "Unexpected Kimi balance response format")
        }
        guard let available = Self.decimalString(info["available_balance"]) else {
            throw LLMError.responseParsingFailed(reason: "Missing available_balance in Kimi response")
        }

        var items: [ProviderBalance.Item] = [
            .init(label: .total, amount: available, currency: currency)
        ]
        if let voucher = Self.decimalString(info["voucher_balance"]) {
            items.append(.init(label: .granted, amount: voucher, currency: currency))
        }
        if let cash = Self.decimalString(info["cash_balance"]) {
            items.append(.init(label: .toppedUp, amount: cash, currency: currency))
        }
        let isAvailable = (Double(available) ?? 0) > 0
        return ProviderBalance(isAvailable: isAvailable, items: items)
    }

    /// Preserve provider precision: rounding a small balance to cents can hide usage.
    private static func decimalString(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else { return nil }
        guard let amount = Double(text), amount.isFinite else { return nil }
        return text
    }
}
