import Testing
import Foundation
@testable import AgRoomCore

// MARK: - Provider Balance Tests

@Suite("ProviderBalance")
struct ProviderBalanceTests {

    // MARK: - Endpoint Derivation

    @Test("DeepSeek 余额端点由 host 重建（不含 /v1）")
    func deepSeekURL() throws {
        let url = try CloudProvider.balanceURL(for: "https://api.deepseek.com/chat/completions")
        #expect(url.absoluteString == "https://api.deepseek.com/user/balance")
    }

    @Test("Kimi 余额端点在 .cn / .ai 两个站点均正确")
    func kimiURL() throws {
        let cn = try CloudProvider.balanceURL(for: "https://api.moonshot.cn/v1/chat/completions")
        #expect(cn.absoluteString == "https://api.moonshot.cn/v1/users/me/balance")

        let ai = try CloudProvider.balanceURL(for: "https://api.moonshot.ai/v1/chat/completions")
        #expect(ai.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
    }

    @Test("不支持的厂商报告无余额能力")
    func unsupportedProvider() {
        #expect(!CloudProvider.supportsBalanceQuery(endpoint: "https://api.openai.com/v1/chat/completions"))
        #expect(CloudProvider.supportsBalanceQuery(endpoint: "https://api.deepseek.com/chat/completions"))
        #expect(throws: LLMError.self) {
            try CloudProvider.balanceURL(for: "https://api.openai.com/v1/chat/completions")
        }
    }

    // MARK: - Response Parsing

    @Test("DeepSeek 响应解析为统一明细项")
    func parseDeepSeekBalance() throws {
        let data = """
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}
        """.data(using: .utf8)!

        let balance = try CloudProvider.parseDeepSeekBalance(data: data)
        #expect(balance.isAvailable)
        #expect(balance.total?.amount == "110.00")
        #expect(balance.total?.currency == "CNY")
        #expect(balance.items.count == 3)
        #expect(balance.items.contains { $0.label == .granted && $0.amount == "10.00" })
        #expect(balance.items.contains { $0.label == .toppedUp && $0.amount == "100.00" })
    }

    @Test("Kimi 响应解析为统一明细项，并识别余额耗尽")
    func parseKimiBalance() throws {
        let ok = """
        {"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.0},"scode":"0x0","status":true}
        """.data(using: .utf8)!

        let balance = try CloudProvider.parseKimiBalance(data: ok)
        #expect(balance.isAvailable)
        #expect(balance.total?.amount == "49.58894")
        #expect(balance.total?.currency == "CNY")
        #expect(balance.items.contains { $0.label == .granted })
        #expect(balance.items.contains { $0.label == .toppedUp })

        let exhausted = """
        {"code":0,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":-1.0},"scode":"0x0","status":true}
        """.data(using: .utf8)!
        let exhaustedBalance = try CloudProvider.parseKimiBalance(data: exhausted)
        #expect(!exhaustedBalance.isAvailable)
    }

    @Test("Kimi regional balance currencies and sub-cent precision are preserved")
    func kimiRegionalCurrencies() throws {
        let data = Data(#"{"code":0,"data":{"available_balance":0.001234,"voucher_balance":0,"cash_balance":0.001234}}"#.utf8)
        let cn = try CloudProvider.parseBalance(data: data, host: "api.moonshot.cn")
        let international = try CloudProvider.parseBalance(data: data, host: "api.moonshot.ai")
        #expect(cn.total?.currency == "CNY")
        #expect(international.total?.currency == "USD")
        #expect(international.total?.amount == "0.001234" && international.isAvailable)
    }

    @Test("异常响应抛解析错误")
    func malformedResponse() {
        let bad = "{}".data(using: .utf8)!
        #expect(throws: LLMError.self) { try CloudProvider.parseDeepSeekBalance(data: bad) }
        #expect(throws: LLMError.self) { try CloudProvider.parseKimiBalance(data: bad) }
    }
}
