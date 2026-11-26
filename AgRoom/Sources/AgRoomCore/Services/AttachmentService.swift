import Foundation

// MARK: - Attachment Service

/// 附件落地服务：用户交给调度 Agent 的文件按约定归档。
/// 音频文件必须存入 `~/Documents/MeetMemo/`，以年月日时分秒（yyyyMMddHHmmss）命名；
/// 其余文件存入空间附件目录 `Application Support/AgRoom/<space>/attachments/`。
public enum AttachmentService {

    /// 音频扩展名（落入 MeetMemo 约定的判定依据）
    public static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac", "ogg", "wma", "aiff", "aif"
    ]

    public enum ImportError: LocalizedError, Equatable {
        case fileNotFound
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound: return "The source file does not exist."
            case .copyFailed(let reason): return "Failed to import the file: \(reason)"
            }
        }
    }

    /// MeetMemo 归档目录（音频专用，用户可读可改）
    public static var meetMemoDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MeetMemo", isDirectory: true)
    }

    /// 空间附件目录（非音频文件）
    public static func attachmentsDirectory(space: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("AgRoom", isDirectory: true)
            .appendingPathComponent(space, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Conversation results are app-owned attachments, never implicit writes to
    /// the user's workspace. Exporting them continues to use the normal UI.
    public static func storeGeneratedImages(_ images: [EngineImage], space: AppSpace) throws -> [ChatAttachment] {
        try storeGeneratedImages(images, directory: attachmentsDirectory(space: space.rawValue))
    }

    static func storeGeneratedImages(_ images: [EngineImage], directory: URL) throws -> [ChatAttachment] {
        guard images.count == 1, images[0].mimeType == "image/png" else { throw ImageGenerationError.invalidImage }
        try CloudProvider.validateGeneratedPNG(images[0].data)
        do {
            let root = try AppDirectory(url: directory, create: true)
            let name = "generated-" + UUID().uuidString + ".png"
            try root.write(images[0].data, name: name)
            return [.init(name: name, path: directory.appendingPathComponent(name).path, isImage: true)]
        } catch { throw ImageGenerationError.saveFailed }
    }

    /// 判断文件是否为音频（按扩展名）
    public static func isAudio(url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 导入文件：拷贝到约定位置并返回落地路径。
    /// 音频 → `~/Documents/MeetMemo/yyyyMMddHHmmss.ext`
    /// 其他 → `<空间>/attachments/yyyyMMddHHmmss.ext`
    /// 同秒冲突时追加 `-1`、`-2` 序号（命名规则不变，仅消歧）。
    @discardableResult
    public static func importFile(at sourceURL: URL, space: String) throws -> URL {
        try importFile(at: sourceURL, destinationDirectory: isAudio(url: sourceURL)
            ? meetMemoDirectory : attachmentsDirectory(space: space))
    }

    /// Explicit composition for disposable native hosts; production destinations
    /// continue to be selected only by the public space-bound entry point.
    static func importFile(at sourceURL: URL, destinationDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ImportError.fileNotFound
        }

        let ext = sourceURL.pathExtension.lowercased()
        let destinationDir = destinationDirectory
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let stamp = timestamp()
        var destination = destinationDir.appendingPathComponent("\(stamp).\(ext)")
        var sequence = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = destinationDir.appendingPathComponent("\(stamp)-\(sequence).\(ext)")
            sequence += 1
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        HubLogger.shared.info("Attachment imported into managed storage")
        return destination
    }

    /// 宿主只传入本会话明确附加的文件。归档位置保持不变，给模型的路径指向工作区内副本，
    /// 不为读取附件而授权整个空间附件目录或附件原始目录。
    public static func stageForConversation(_ files: [URL], service: FileAreaService) throws -> [String: String] {
        guard !files.isEmpty else { return [:] }
        guard service.scopedRoots != nil else { throw FileAreaService.AreaError.unsafePath }
        let externalFiles = Set(files).filter {
            (try? service.resolveManaged($0.path)) == nil
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !externalFiles.isEmpty else { return [:] }
        let parent = try service.createDirectory(at: service.defaultReadRoot.appendingPathComponent(".agroom-attachments").path)
        let directory = try service.createFolder(at: parent.path, name: UUID().uuidString)
        var replacements: [String: String] = [:]
        for source in externalFiles {
            let target = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
            _ = try service.resolveManaged(target.path)
            try FileManager.default.copyItem(at: source, to: target)
            replacements[source.path] = target.path
        }
        return replacements
    }

    /// 年月日时分秒命名（yyyyMMddHHmmss）
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
