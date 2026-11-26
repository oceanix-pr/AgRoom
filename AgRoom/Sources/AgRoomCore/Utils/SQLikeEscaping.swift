import Foundation

/// SQL `LIKE` 字面转义：把用户查询里的 `\` `%` `_` 转义，配合 `ESCAPE '\'` 使用。
///
/// 不转义时 `%` 会匹配任意串、`_` 匹配任意单字符——用户搜 "50%" 或 "a_b"
/// 会命中远超预期的记录。各服务统一走这里，避免转义规则各自实现走样。
enum SQLikeEscaping {
    static func escape(_ value: String) -> String {
        var output = ""
        for character in value {
            if character == "\\" || character == "%" || character == "_" {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }
}