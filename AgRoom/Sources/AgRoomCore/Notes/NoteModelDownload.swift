import Foundation

/// Public model assets only. Cancellation keeps URLSession's bounded resume receipt in this space.
enum NoteModelDownload {
    static func fetch(_ url: URL, root: URL) async throws -> URL {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw NoteStoreError.invalidContent }
        let folder = root.appendingPathComponent(".downloads")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        try NoteCaptureRecovery.regularDirectory(folder)
        let key = NoteMediaTranscriber.sourceHash(Data(url.absoluteString.utf8)), resume = folder.appendingPathComponent(key + ".resume")
        let target = folder.appendingPathComponent(UUID().uuidString + ".download")
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 600
        let receipt = try await NoteDownloadReceipts.shared.begin(resume)
        let operation = NoteModelDownloadOperation(config: config,resume: resume,target: target,receipt: receipt)
        return try await withTaskCancellationHandler { try await operation.run(url) } onCancel: { operation.cancel() }
    }
}

/// Only transfer ownership is shared. Receipt files stay inside the chosen space's model folder.
/// Late cancellation callbacks cannot overwrite or delete a newer download's receipt.
private actor NoteDownloadReceipts {
    static let shared = NoteDownloadReceipts()
    struct Receipt: Sendable { let id: UUID; let data: Data? }
    private var owners: [URL:UUID] = [:]
    func begin(_ file: URL) throws -> Receipt {
        try Task.checkCancellation()
        let id = UUID()
        let data = FileManager.default.fileExists(atPath: file.path) ? try NoteCaptureRecovery.read(file,maximum: 2 * 1024 * 1024) : nil
        owners[file] = id
        return .init(id: id,data: data)
    }
    func persist(_ data: Data, to file: URL, owner: UUID) {
        guard owners[file] == owner, !data.isEmpty, data.count <= 2 * 1024 * 1024 else { return }
        do { try data.write(to: file,options: .atomic) }
        catch { HubLogger.shared.warning("Model download resume receipt could not be saved") }
    }
    func clear(_ file: URL, owner: UUID) {
        guard owners[file] == owner else { return }
        try? FileManager.default.removeItem(at: file)
        owners[file] = nil
    }
}

/// The lock protects continuation/task ownership only; copying and receipt I/O run after unlocking.
private final class NoteModelDownloadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL,Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finished = false
    private let session: URLSession
    private let resume: URL
    private let target: URL
    private let receipt: NoteDownloadReceipts.Receipt
    init(config: URLSessionConfiguration,resume: URL,target: URL,receipt: NoteDownloadReceipts.Receipt) { session = URLSession(configuration: config); self.resume = resume; self.target = target; self.receipt = receipt }
    func run(_ url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (URL?,URLResponse?,Error?) -> Void = { [self] temporary, response, error in
                do {
                    if let error {
                        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { persist(data) }
                        throw error
                    }
                    guard let temporary, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw NoteStoreError.invalidContent }
                    guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                    try FileManager.default.moveItem(at: temporary,to: target)
                    Task { await NoteDownloadReceipts.shared.clear(resume,owner: receipt.id) }
                    if !finish(.success(target)) { try? FileManager.default.removeItem(at: target) }
                } catch { _ = finish(.failure(error)) }
                session.finishTasksAndInvalidate()
            }
            let download = receipt.data.map { session.downloadTask(withResumeData: $0,completionHandler: completion) } ?? session.downloadTask(with: url,completionHandler: completion)
            let stop = lock.withLock { self.continuation = continuation; task = download; return cancelled }
            if stop { download.cancel(); _ = finish(.failure(CancellationError())) }
            else { download.resume() }
        }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel(byProducingResumeData: { [self] data in if let data { persist(data) } })
        _ = finish(.failure(CancellationError()))
    }
    private func persist(_ data: Data) {
        Task { await NoteDownloadReceipts.shared.persist(data,to: resume,owner: receipt.id) }
    }
    @discardableResult private func finish(_ result: Result<URL,Error>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<URL,Error>? in
            guard !finished, let continuation = self.continuation else { return nil }; finished = true; self.continuation = nil; return continuation
        }
        guard let continuation else { return false }; continuation.resume(with: result); return true
    }
}
