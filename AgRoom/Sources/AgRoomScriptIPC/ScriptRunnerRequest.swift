import Foundation
import Darwin

/// 内核限制与宿主预算使用同一常量；不得由脚本上调。
public enum ScriptRunnerLimits {
    public static let maximumFileBytes: UInt64 = 128 * 1024 * 1024
    public static let maximumOutputBytes: UInt64 = 256 * 1024 * 1024
    public static let maximumOutputFiles = 4096
    public static let maximumResidentBytes: UInt64 = 2 * 1024 * 1024 * 1024
}

/// 可信准备阶段的固定诊断。不携带书签、源码、环境变量或私有路径。
public struct ScriptRunnerFailure: Codable, Error, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case invalidRequest, protocolMismatch, identityMismatch
        case bookmarkCreationFailed, bookmarkResolutionFailed, bookmarkStale, scopeAccessDenied, bookmarkPathMismatch, bookmarkIdentityMismatch
        case scopeConflict, scopeLimitExceeded, runnerLaunchFailed, preparationTimeout, preparationFailed, invalidResponse
        case directoryAccessDenied, stdioAccessDenied, resourceLimitFailed, execFailed
    }
    public enum Stage: String, Codable, Sendable {
        case request, identity, inputScopes, prepareScopes, writeScopes, standardIO, workingDirectory, resourceLimits, execution
    }
    public let marker: String
    public let code: Code
    public let stage: Stage
    public let scopeIndex: Int?
    public let systemError: Int32?
    public init(_ code: Code, stage: Stage, scopeIndex: Int? = nil, systemError: Int32? = nil) {
        self.marker = "agroom.sandbox.failure/v1"
        self.code = code; self.stage = stage; self.scopeIndex = scopeIndex; self.systemError = systemError
    }
    public var isValid: Bool { marker == "agroom.sandbox.failure/v1" && (scopeIndex.map { (0..<256).contains($0) } ?? true) }
}

public struct ScriptRunnerBookmark: Codable, Sendable {
    public let data: Data
    public let path: String
    public let identity: ScriptRunnerFileIdentity
    public init(data: Data, path: String, identity: ScriptRunnerFileIdentity) {
        self.data = data; self.path = path; self.identity = identity
    }
}

/// A stale metadata hint is recoverable only for the exact object the host approved.
public struct ScriptRunnerFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let kind: UInt32
    public init(device: UInt64, inode: UInt64, kind: UInt32) {
        self.device = device; self.inode = inode; self.kind = kind
    }
    public static func capture(_ url: URL) -> Self? {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), kind: UInt32(info.st_mode & S_IFMT))
    }
}

/// 数据流使用已授权文件，控制请求仍只从启动时的匿名 stdin 读取。
public struct ScriptRunnerStandardIO: Codable, Sendable {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public var input: String?
    public var output: String?
    public var error: String?

    public init(input: String? = nil, output: String? = nil, error: String? = nil) {
        self.input = input; self.output = output; self.error = error
    }
}

/// 一次性、经继承 stdin 文件描述符传递的请求；不暴露监听端口或持久化授权令牌。
public struct ScriptRunnerRequest: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepareScopes, execute }
    public enum Purpose: String, Codable, Sendable { case script, packageResolution }
    public static let currentVersion = 7
    public static let maximumBytes = 1024 * 1024

    public var version: Int
    public var phase: Phase
    public var purpose: Purpose
    public var helperIdentifier: String
    public var allowsNetwork: Bool
    public var bookmarks: [ScriptRunnerBookmark]
    public var writeBookmarks: [ScriptRunnerBookmark]
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]
    public var standardIO: ScriptRunnerStandardIO?

    public init(phase: Phase = .execute, helperIdentifier: String, allowsNetwork: Bool,
                bookmarks: [ScriptRunnerBookmark], writeBookmarks: [ScriptRunnerBookmark] = [],
                executable: String, arguments: [String], directory: String, environment: [String: String],
                standardIO: ScriptRunnerStandardIO? = nil, purpose: Purpose = .script) {
        self.version = Self.currentVersion
        self.phase = phase
        self.purpose = purpose
        self.helperIdentifier = helperIdentifier
        self.allowsNetwork = allowsNetwork
        self.bookmarks = bookmarks
        self.writeBookmarks = writeBookmarks
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.standardIO = standardIO
    }
}
