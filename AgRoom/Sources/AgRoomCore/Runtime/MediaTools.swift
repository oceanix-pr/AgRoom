import Foundation

// MARK: - OCR Tool

/// 调度工具：OCR 识别图片文字（系统 Vision 引擎，简体中文 + 英文，只读免确认）
public struct OCRTool: DispatcherTool {
    private let fileAreaService: FileAreaService

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "ocr_recognize",
            description: "Extract text from an image file (screenshot, photo, scan) using on-device OCR. "
                + "Supports Simplified Chinese and English. Use when the user provides an image path "
                + "or asks to read text out of a picture.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the image file (png/jpg/jpeg/gif/webp/bmp/tiff/heic)"}},"required":["path"]}"#
        )
    }
    public let requiresConfirmation = false
    /// 只读：不入副作用日志，可安全重试
    public let sideEffectClass = ToolSideEffectClass.readOnly

    public init(fileAreaService: FileAreaService = .standard) { self.fileAreaService = fileAreaService }

    public func execute(argumentsJSON: String) async throws -> String {
        let path = ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw ToolExecutionFailure(message: "ocr_recognize requires a 'path' argument.")
        }
        let url = try fileAreaService.resolveManaged(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolExecutionFailure(message: "Image file not found: \(url.path)")
        }
        do {
            let text = try await OCRService.recognizeCancellable(imageURL: url)
            ToolArtifactCapture.recordSource(.init(.image, text.isEmpty ? .noMatches : .found,
                inputDigest: ResponsesContextWindow.digest(url.standardizedFileURL.path)))
            return "OCR result:\n\(text)"
        } catch let error as OCRService.OCRError {
            throw ToolExecutionFailure(message: "OCR failed: \(error.localizedDescription)")
        }
    }

    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}

// MARK: - Transcribe Audio Tool

/// 调度工具：音频文件转文字（系统 Speech 引擎；授权预检避免工具循环内挂死）
public struct TranscribeAudioTool: DispatcherTool {
    private let service = TranscriptionService()
    private let fileAreaService: FileAreaService

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "transcribe_audio",
            description: "Transcribe an audio file to text using the on-device speech engine "
                + "(m4a/mp3/wav etc.). Returns the full transcript. May take roughly the audio's "
                + "own duration for long files.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the audio file"},"language":{"type":"string","enum":["zh-CN","en-US"],"description":"Spoken language of the audio (default zh-CN)"}},"required":["path"]}"#
        )
    }
    public let requiresConfirmation = false

    public init(fileAreaService: FileAreaService = .standard) { self.fileAreaService = fileAreaService }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "transcribe_audio requires a 'path' argument." }
        let url = try fileAreaService.resolveManaged(path)
        // 授权预检：未授权时系统会弹窗并阻塞识别，这里直接返回指引
        switch TranscriptionService.authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            _ = await TranscriptionService.requestAuthorization()
            guard TranscriptionService.authorizationStatus == .authorized else {
                return "Speech recognition is not authorized. Ask the user to grant it in "
                    + "System Settings → Privacy & Security → Speech Recognition, then retry."
            }
        default:
            return "Speech recognition permission was denied. Ask the user to enable it in "
                + "System Settings → Privacy & Security → Speech Recognition, then retry."
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Audio file not found: \(url.path)"
        }

        let language = ToolArguments.string(args, "language")
        let locale = language == "en-US"
            ? Locale(identifier: "en-US")
            : Locale(identifier: "zh-CN")

        do {
            let result = try await service.transcribeFile(at: url, locale: locale)
            return "Transcript of \(url.lastPathComponent):\n\(result.text)"
        } catch let error as TranscriptionService.TranscriptionError {
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - File Write Tool

/// 兼容旧技能的 file_write 名称；复用受管文件写入与会话工作区边界。
public struct FileWriteTool: DispatcherTool {
    let service: FileAreaService
    let workspaceRoot: URL
    let space: AppSpace

    public init(service: FileAreaService = .standard, workspaceRoot: URL? = nil, space: AppSpace = .work) {
        self.service = service
        self.workspaceRoot = workspaceRoot ?? service.workspaceRoot
        self.space = space
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "file_write",
            description: "Compatibility alias for files_write. Create a text file inside this session's workspace; "
                + "existing files are never overwritten (name conflicts get numbered suffixes). "
                + "Prefer files_write with an absolute path. Relative paths resolve inside this session's workspace.",
            parametersSchemaJSON: FilesWriteTool(service: service).definition.parametersSchemaJSON
        )
    }
    public var requiresConfirmation: Bool { true }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public var confirmationScope: ConfirmationRequirement.Scope { .fileArea }
    public func writeTargets(argumentsJSON: String) -> [String] {
        let resolved = resolvedArgumentsJSON(argumentsJSON)
        return [ToolArguments.string(ToolArguments.parse(resolved), "path")].filter { !$0.isEmpty }
    }
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    public func roundAuthorizationKey(argumentsJSON: String) -> String? {
        "file_write#" + workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 审核、范围守卫和执行使用同一份解析后的真实参数。
    func resolvedArgumentsJSON(_ json: String) -> String {
        var args = ToolArguments.parse(json)
        let path = ToolArguments.string(args, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") {
            args["path"] = workspaceRoot.appendingPathComponent(path).path
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let result = String(data: data, encoding: .utf8) else { return json }
        return result
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let resolved = resolvedArgumentsJSON(argumentsJSON)
        let path = ToolArguments.string(ToolArguments.parse(resolved), "path")
        guard let target = FileAreaService.expandHome(path), FileAreaService.isInside(target, root: workspaceRoot) else {
            return "Blocked: file_write must stay inside this session's workspace. Use files_write with an absolute in-scope path."
        }
        return try await FilesWriteTool(service: service, space: space).execute(argumentsJSON: resolved)
    }
}
