import Foundation

public enum NativeAppLocalActionError: String, Error, Sendable {
    case invalidInput, divisionByZero, outOfRange, tooComplex
    public var localizationKey: String { "apps.local.error." + rawValue }
}

/// Pure local transforms. No dynamic evaluation, scripts, tools or resource access.
public enum NativeAppLocalActions {
    public static func transform(_ operation: NativeAppDefinition.Action.Operation, current: String,
                                 value: NativeAppValue) throws -> NativeAppValue {
        switch operation {
        case .append:
            let candidate = NativeAppValue.string(current + value.string)
            guard candidate.isBounded else { throw NativeAppLocalActionError.tooComplex }
            return candidate
        case .removeLast: return .string(String(current.dropLast()))
        case .calculate:
            var parser = try ArithmeticParser(value.string)
            let result = try parser.parse()
            return .string(NSDecimalNumber(decimal: result == 0 ? Decimal(0) : result).stringValue)
        }
    }
}

private struct ArithmeticParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private var operations = 0

    init(_ expression: String) throws {
        guard expression.utf8.count <= 512 else { throw NativeAppLocalActionError.tooComplex }
        let normalized = expression.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        bytes = Array(normalized.utf8)
    }

    mutating func parse() throws -> Decimal {
        let result = try sum()
        skipSpaces()
        guard index == bytes.count else { throw NativeAppLocalActionError.invalidInput }
        return result
    }

    private mutating func skipSpaces() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        skipSpaces()
        guard index < bytes.count && bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func sum() throws -> Decimal {
        var result = try product()
        while true {
            if consume(43) { let right = try product(); result = try combine(result, right, operation: 43) }
            else if consume(45) { let right = try product(); result = try combine(result, right, operation: 45) }
            else { return result }
        }
    }

    private mutating func product() throws -> Decimal {
        var result = try factor()
        while true {
            if consume(42) { let right = try factor(); result = try combine(result, right, operation: 42) }
            else if consume(47) { let right = try factor(); result = try combine(result, right, operation: 47) }
            else { return result }
        }
    }

    private mutating func factor() throws -> Decimal {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 16 else { throw NativeAppLocalActionError.tooComplex }
        if consume(43) { return try factor() }
        if consume(45) { let right = try factor(); return try combine(0, right, operation: 45) }
        if consume(40) {
            let result = try sum()
            guard consume(41) else { throw NativeAppLocalActionError.invalidInput }
            return result
        }
        skipSpaces()
        let start = index
        var digits = 0
        while index < bytes.count && (48...57).contains(bytes[index]) { index += 1; digits += 1 }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1; digits += 1 }
        }
        guard digits > 0 else { throw NativeAppLocalActionError.invalidInput }
        if index < bytes.count && (bytes[index] == 101 || bytes[index] == 69) {
            index += 1
            if index < bytes.count && (bytes[index] == 43 || bytes[index] == 45) { index += 1 }
            let exponent = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > exponent else { throw NativeAppLocalActionError.invalidInput }
        }
        guard digits <= 38, let number = Decimal(string: String(decoding: bytes[start..<index], as: UTF8.self),
                                               locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else {
            throw NativeAppLocalActionError.outOfRange
        }
        return number
    }

    private mutating func combine(_ left: Decimal, _ right: Decimal, operation: UInt8) throws -> Decimal {
        operations += 1
        guard operations <= 128 else { throw NativeAppLocalActionError.tooComplex }
        if operation == 47 && right == 0 { throw NativeAppLocalActionError.divisionByZero }
        var lhs = left, rhs = right, result = Decimal()
        let error: Decimal.CalculationError
        switch operation {
        case 43: error = NSDecimalAdd(&result, &lhs, &rhs, .plain)
        case 45: error = NSDecimalSubtract(&result, &lhs, &rhs, .plain)
        case 42: error = NSDecimalMultiply(&result, &lhs, &rhs, .plain)
        default: error = NSDecimalDivide(&result, &lhs, &rhs, .plain)
        }
        guard (error == .noError || error == .lossOfPrecision), !result.isNaN else {
            throw NativeAppLocalActionError.outOfRange
        }
        return result
    }
}
