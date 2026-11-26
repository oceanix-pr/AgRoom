import CryptoKit
import Foundation

/// 只有模型权重路径属于全局偏好；文本、分段与向量始终属于空间库。
public struct KnowledgeEmbeddingSettings: Sendable, Equatable {
    public static let enabledKey = "agroom.knowledge.embedding.enabled"
    public static let modelPathKey = "agroom.knowledge.embedding.modelPath"
    public static let modelFileName = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    public static var defaultModelURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AgRoom/models/Qwen3-Embedding-0.6B")
            .appendingPathComponent(modelFileName)
    }
    public var isEnabled: Bool
    public var modelPath: String

    public init(isEnabled: Bool = true, modelPath: String = Self.defaultModelURL.path) {
        self.isEnabled = isEnabled
        self.modelPath = modelPath
    }

    public static func load() -> Self {
        let defaults = UserDefaults.standard
        return Self(
            isEnabled: defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey),
            modelPath: defaults.string(forKey: modelPathKey) ?? defaultModelURL.path
        )
    }

    public func makeProvider() throws -> LocalKnowledgeEmbedder {
        guard isEnabled else { throw KnowledgeEmbeddingError.disabled }
        return try LocalKnowledgeEmbedder(modelURL: URL(fileURLWithPath: modelPath))
    }
}

/// 错误代码交给 UI 三语翻译；不传播含文档正文的进程输出。
public enum KnowledgeEmbeddingError: String, Error, Sendable {
    case disabled, modelMissing, invalidModel, runtimeMissing, inferenceFailed, invalidVector, timedOut, changed
}

public protocol KnowledgeEmbeddingProvider: Sendable {
    var indexIdentity: String { get }
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]]
}

public struct LocalKnowledgeEmbedder: KnowledgeEmbeddingProvider {
    public let indexIdentity: String
    let modelURL: URL
    let executableURL: URL

    public init(modelURL: URL, executableURL: URL? = nil) throws {
        let url = modelURL.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "gguf",
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw KnowledgeEmbeddingError.modelMissing
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() } // 只清理只读句柄。
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw KnowledgeEmbeddingError.invalidModel
        }
        let executable = executableURL ?? Self.bundledExecutableURL()
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw KnowledgeEmbeddingError.runtimeMissing
        }
        self.modelURL = url
        self.executableURL = executable
        // 权重换路径/被替换即视为新索引；分段、前缀、pooling、维度也参与版本。
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "qwen3-0.6b/1024/last/l2/chunk-v1/prompt-v1/\(url.path)/\(values.fileSize ?? 0)/\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        indexIdentity = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func bundledExecutableURL() -> URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let relative = "EmbeddingRuntime/\(architecture)/llama-embedding"
        let main = Bundle.main
        let spmBundleURL = main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgRoom_AgRoom.bundle")
        let candidates = [
            main.bundleURL.appendingPathComponent("Contents/Helpers/\(relative)"),
            main.resourceURL?.appendingPathComponent(relative),
            main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/\(relative)"),
            spmBundleURL.flatMap { Bundle(url: $0)?.resourceURL }?.appendingPathComponent(relative)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        try await KnowledgeEmbeddingExecutor.shared.embed(texts, isQuery: isQuery, provider: self)
    }
}

/// 串行化 GPU 使用。仅持有执行互斥标记，不缓存查询、向量或空间服务。
/// 每批一个短命进程，完成/失败/取消都释放模型内存，不留下驻留服务或监听端口。
private actor KnowledgeEmbeddingExecutor {
    static let shared = KnowledgeEmbeddingExecutor()
    private var isBusy = false

    func embed(_ texts: [String], isQuery: Bool, provider: LocalKnowledgeEmbedder) async throws -> [[Float]] {
        while isBusy { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        guard try LocalKnowledgeEmbedder(modelURL: provider.modelURL, executableURL: provider.executableURL).indexIdentity == provider.indexIdentity else {
            throw KnowledgeEmbeddingError.changed
        }
        isBusy = true
        defer { isBusy = false }
        guard !texts.isEmpty, texts.count <= 16 else { throw KnowledgeEmbeddingError.invalidVector }
        let result = try await Self.run(texts, isQuery: isQuery, provider: provider)
        guard try LocalKnowledgeEmbedder(modelURL: provider.modelURL, executableURL: provider.executableURL).indexIdentity == provider.indexIdentity else {
            throw KnowledgeEmbeddingError.changed
        }
        return result
    }

    private static func run(_ texts: [String], isQuery: Bool, provider: LocalKnowledgeEmbedder) async throws -> [[Float]] {
        // 唯一临时目录，权限 0700；不把私人正文放进命令行参数或进程日志。
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agroom-embedding-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) } // 派生输入可安全清理。
        let separator = "<agroom-\(UUID())>"
        let inputs = texts.map { text in
            isQuery ? "Instruct: Given a question, retrieve relevant passages from personal notes and documents that answer the question.\nQuery: \(text)" : text
        }
        let inputURL = directory.appendingPathComponent("input.txt")
        try inputs.joined(separator: separator).write(to: inputURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = provider.executableURL
        process.arguments = ["-m", provider.modelURL.path, "-f", inputURL.path,
                             "--pooling", "last", "--embd-normalize", "2",
                             "--embd-output-format", "json", "--embd-separator", separator,
                             "-c", "8192", "-b", "8192", "-ub", "8192", "-ngl", "99",
                             "--log-verbosity", "0", "--offline"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdout = BoundedOutputCollector(limit: 2_000_000)
        let stderr = BoundedOutputCollector(limit: 2_000_000)
        output.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { stdout.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { stderr.append(data) }
        }
        let cancelled = CancellationGate(), timeout = CancellationGate()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                    if cancelled.isCancelled { ProcessTerminator.terminate(process: process, label: "knowledge-embedding") }
                    ProcessTerminator.scheduleTimeout(process: process, timeout: 120, label: "knowledge-embedding") {
                        timeout.markCancelled()
                    }
                } catch { continuation.resume(throwing: KnowledgeEmbeddingError.inferenceFailed) }
            }
        } onCancel: {
            cancelled.markCancelled()
            ProcessTerminator.terminate(process: process, label: "knowledge-embedding")
        }
        try Task.checkCancellation()
        if timeout.isCancelled { throw KnowledgeEmbeddingError.timedOut }
        guard process.terminationStatus == 0 else { throw KnowledgeEmbeddingError.inferenceFailed }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        stdout.append(output.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errors.fileHandleForReading.readDataToEndOfFile())
        // llama.cpp 的 LOG 输出通道随构建版本变化；两个通道均只在内存中解析，不写日志。
        for data in [stdout.data, stderr.data] {
            if let result = try? decodeOutput(data, count: texts.count) { return result }
        }
        throw KnowledgeEmbeddingError.invalidVector
    }

    private struct Output: Decodable {
        struct Entry: Decodable { let index: Int; let embedding: [Float] }
        let data: [Entry]
    }
    static func decodeOutput(_ data: Data, count: Int) throws -> [[Float]] {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "{\n  \"object\": \"list\""),
              let end = text.range(of: "\n}", range: start.lowerBound..<text.endIndex) else {
            throw KnowledgeEmbeddingError.invalidVector
        }
        let object = try JSONDecoder().decode(Output.self, from: Data(text[start.lowerBound..<end.upperBound].utf8))
        let entries = object.data.sorted { $0.index < $1.index }
        guard entries.map(\.index) == Array(0..<count) else { throw KnowledgeEmbeddingError.invalidVector }
        return try entries.map { try KnowledgeVector.normalized($0.embedding) }
    }
}

enum KnowledgeVector {
    static let dimension = 1024
    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { throw KnowledgeEmbeddingError.invalidVector }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-10 else { throw KnowledgeEmbeddingError.invalidVector }
        return vector.map { Float(Double($0) / norm) }
    }
    static func encode(_ vector: [Float]) throws -> Data {
        let normalized = try normalized(vector)
        return normalized.withUnsafeBufferPointer { pointer in Data(buffer: pointer) }
    }
    static func decode(_ data: Data) throws -> [Float] {
        guard data.count == dimension * MemoryLayout<Float>.size else { throw KnowledgeEmbeddingError.invalidVector }
        // macOS 支持的平台均为小端；不依赖 Data 的对齐。
        return try normalized(data.withUnsafeBytes { bytes in
            (0..<dimension).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        })
    }
}
