import CryptoKit
import Foundation

// MARK: - Skill Store

/// 文件系统制技能库（Anthropic Agent Skills 标准形态）：
/// 每个技能是一个以技能名命名的文件夹，内含 SKILL.md 与可选的
/// scripts/、references/ 等资源文件；渐进式披露由调度工具实现。
/// 技能库按空间物理隔离：`Application Support/AgRoom/<space>/skills/`
public final class SkillStore: @unchecked Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        case invalidName
        case notFound(String)
        case disabled(String)
        case unsafePath
        case unreadableFile
        case resourceTooLarge
        case protectedFile
        case notScript

        /// 本地化键（UI 层 L.string 使用；Core 层不直接依赖本地化设施）
        public var localizationKey: String {
            switch self {
            case .invalidName: return "skills.error.invalid_name"
            case .notFound: return "skills.error.not_found"
            case .disabled: return "skills.error.disabled"
            case .unsafePath: return "skills.error.unsafe_path"
            case .unreadableFile: return "skills.error.unreadable_file"
            case .resourceTooLarge: return "skills.error.resources_too_large"
            case .protectedFile: return "skills.error.protected_file"
            case .notScript: return "skills.error.not_script"
            }
        }

        /// 兜底英文描述（无本地化环境时的 description）
        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Skill folder name must match the slug standard"
            case .notFound(let name): return "Skill '\(name)' was not found"
            case .disabled(let name): return "Skill '\(name)' is disabled. Enable it in Skills before using it."
            case .unsafePath: return "The requested file path escapes the skill folder"
            case .unreadableFile: return "The file could not be read as text"
            case .resourceTooLarge: return "The skill resources exceed the rewrite context size. Edit a smaller set of files."
            case .protectedFile: return "SKILL.md cannot be deleted from a skill folder"
            case .notScript: return "Only .py scripts inside a skill folder can be executed"
            }
        }
    }

    /// 读文件体积上限（防止把巨大文件塞进上下文）
    static let maxFileBytes = 200_000
    /// 停用标记文件（标准 frontmatter 无开关字段，用隐藏标记承载）
    static let disabledMarker = ".agroom-disabled"

    let directoryURL: URL
    private let fileManager = FileManager.default

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            HubLogger.shared.error("Skill store directory setup failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    /// 技能库目录（跨模块只读访问，如技能使用日志定位空间目录）
    public var skillsDirectoryURL: URL { directoryURL }

    /// 本技能库所属空间（目录结构 `…/AgRoom/<space>/skills`）；无法判定时为 nil
    public var space: AppSpace? {
        AppSpace(rawValue: directoryURL.deletingLastPathComponent().lastPathComponent)
    }

    // MARK: - 列表快照（后台扫描 + 失效）

    /// 后台串行扫描队列：技能列表构建不占用主线程
    private let snapshotQueue = DispatchQueue(label: "agroom.skillstore.snapshot", qos: .userInitiated)
    private let snapshotLock = NSLock()
    /// 缓存的是「某一代的不可变列表」，世代随任何写入前进
    private var snapshotCache: [Skill]?
    private var snapshotGeneration = 0

    /// 使列表快照失效：技能库任何写入（新建/删除/导入/改写/启停/回滚）后调用
    func invalidateSnapshot() {
        snapshotLock.lock()
        snapshotGeneration += 1
        snapshotCache = nil
        snapshotLock.unlock()
    }

    /// 技能列表快照：在后台串行队列扫描并缓存；命中缓存直接返回。
    /// 组装点（MainActor 的 EngineAssembly、别名缓存）据此避免在主线程逐个读盘解析 SKILL.md
    public func listSnapshot() async -> [Skill] {
        if let cached = cachedSnapshot() { return cached }
        let generation = snapshotGenerationValue()
        let built = await withCheckedContinuation { continuation in
            snapshotQueue.async {
                continuation.resume(returning: (try? self.list()) ?? [])
            }
        }
        storeSnapshot(built, ifGenerationIs: generation)
        return built
    }

    /// NSLock 的同步取用点：异步函数内不能直接 lock/unlock
    private func cachedSnapshot() -> [Skill]? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotCache
    }

    private func snapshotGenerationValue() -> Int {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotGeneration
    }

    /// 扫描期间若发生写入，本代结果已过期，不写回缓存
    private func storeSnapshot(_ skills: [Skill], ifGenerationIs generation: Int) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        if snapshotGeneration == generation {
            snapshotCache = skills
        }
    }

    // MARK: - 每技能写入串行归属

    /// 每个技能名使用可重入的串行队列；注册表锁只保护队列映射，不包住文件 I/O。
    private final class SkillWriteQueue: @unchecked Sendable {
        private let queue = DispatchQueue(label: "agroom.skill.write", qos: .utility)
        private let key = DispatchSpecificKey<Bool>()
        init() { queue.setSpecific(key: key, value: true) }
        func sync<T>(_ body: () throws -> T) rethrows -> T {
            if DispatchQueue.getSpecific(key: key) == true { return try body() }
            return try queue.sync(execute: body)
        }
    }
    private let writeLockRegistryLock = NSLock()
    private var skillWriteQueues: [String: SkillWriteQueue] = [:]

    var maintenanceKey: String { skillsDirectoryURL.deletingLastPathComponent().appendingPathComponent("backup-restore").path }

    func withSkillWriteLock<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let lease = ResourceMaintenance.owned.contains(maintenanceKey) ? nil : try ResourceMaintenance.Lease(key: maintenanceKey, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        writeLockRegistryLock.lock()
        let queue: SkillWriteQueue
        if let existing = skillWriteQueues[name] {
            queue = existing
        } else {
            queue = SkillWriteQueue()
            skillWriteQueues[name] = queue
        }
        writeLockRegistryLock.unlock()
        let owned = ResourceMaintenance.owned
        return try queue.sync { try ResourceMaintenance.$owned.withValue(owned, operation: body) }
    }

    /// 技能文件夹 URL（slug 校验后拼接）
    public func folderURL(for name: String) throws -> URL {
        guard name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil,
              name.count <= Skill.Constants.nameLimit else {
            throw StoreError.invalidName
        }
        return directoryURL.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 列表（仅解析 frontmatter 元数据 = 渐进式披露第一层）

    public func list() throws -> [Skill] {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var skills: [Skill] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            let skillMD = entry.appendingPathComponent("SKILL.md")
            // 无 SKILL.md 的文件夹不是技能（导入中/用户手动放入），正常跳过
            guard fileManager.fileExists(atPath: skillMD.path) else { continue }
            let text: String
            var skill: Skill
            do {
                text = try String(contentsOf: skillMD, encoding: .utf8)
                skill = try SkillDocument.parse(text)
            } catch {
                // SKILL.md 存在但读不出/解析失败：跳过但必须留痕，
                // 否则技能"无声消失"无从排查
                HubLogger.shared.warning("Skipping unreadable skill definition: \(HubLogger.safeErrorSummary(error))")
                continue
            }
            // 文件夹名即技能名（Anthropic 标准要求）：所有地址（删除/加载/文件）
            // 一律以文件夹为准，防止 frontmatter 与文件夹名不一致时删除/加载错位
            skill.name = entry.lastPathComponent
            skill.isEnabled = !fileManager.fileExists(
                atPath: entry.appendingPathComponent(Self.disabledMarker).path
            )
            // 修改时间取 SKILL.md 文件 mtime（编辑器/AI 重写/访达改动均实时反映）
            skill.updatedAt = (try? skillMD.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? skill.updatedAt
            skills.append(skill)
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// 技能包内的资源文件（相对路径，不含 SKILL.md、隐藏文件与运行产物）
    public func files(for name: String) throws -> [String] {
        let folder = try folderURL(for: name)
        return Self.regularFiles(in: folder)
            .map(\.relative)
            .filter { $0 != "SKILL.md" && !Self.isRuntimeArtifact($0) }
            .sorted()
    }

    /// 枚举目录内常规文件，返回 (绝对 URL, 相对路径)。
    /// 用 subpathsOfPath 取天然相对路径：URL 枚举器返回的绝对路径可能解析前缀符号链接
    /// （macOS 的 /var → /private/var firmlink，且 resolvingSymlinksInPath 不解析它），
    /// 若按 folder.path 字符数硬截会把相对路径切错位，混入文件夹名残段
    private static func regularFiles(in folder: URL) -> [(url: URL, relative: String)] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) else { return [] }
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        var result: [(url: URL, relative: String)] = []
        for sub in subpaths where !sub.isEmpty {
            // 任意层级含隐藏组件即跳过（对齐枚举器 .skipsHiddenFiles 的不下降语义）
            if sub.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let absolute = folder.appendingPathComponent(sub)
            guard fileManager.fileExists(atPath: absolute.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            result.append((absolute, sub))
        }
        return result
    }

    /// 脚本运行产物判定：scratch/ 输出区、__pycache__/.pyc 字节码与 versions/ 版本快照
    static func isRuntimeArtifact(_ relativePath: String) -> Bool {
        relativePath == "scratch"
            || relativePath.hasPrefix("scratch/")
            || relativePath.hasPrefix("__pycache__/")
            || relativePath.hasSuffix(".pyc")
            || relativePath == "versions"
            || relativePath.hasPrefix("versions/")
    }

    // MARK: - 渐进式披露（调度工具调用）

    /// 加载技能正文（SKILL.md body）+ 资源清单
    public func loadBody(name: String) throws -> String {
        let folder = try folderURL(for: name)
        let skillMD = folder.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillMD, encoding: .utf8),
              let skill = try? SkillDocument.parse(text) else {
            throw StoreError.notFound(name)
        }
        var output = skill.content
        // 参数化变量提示：占位符由调度 Agent 按当前对话上下文填空
        if !skill.variables.isEmpty {
            let used = skill.variables.filter { output.contains("{{\($0)}}") }
            if !used.isEmpty {
                output += "\n\n[Placeholders]\n"
                    + "This skill is parameterized. Before following the steps, replace each placeholder "
                    + "with the value from the current conversation context:\n"
                    + used.map { "- {{\($0)}}" }.joined(separator: "\n")
            }
        }
        let resources = (try? files(for: name)) ?? []
        if !resources.isEmpty {
            output += "\n\n[Files available in this skill (read with skill_file)]\n"
                + resources.map { "- \($0)" }.joined(separator: "\n")
        }
        return output
    }

    /// 读取技能包内的资源文件（路径遍历防护 + 体积上限）
    public func readFile(name: String, relativePath: String) throws -> String {
        let folder = try folderURL(for: name)
        let resolved = folder.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
            throw StoreError.unsafePath
        }
        let attributes = try? fileManager.attributesOfItem(atPath: resolved.path)
        if let size = attributes?[.size] as? Int, size > Self.maxFileBytes {
            throw StoreError.unreadableFile
        }
        guard let text = try? String(contentsOf: resolved, encoding: .utf8) else {
            throw StoreError.unreadableFile
        }
        return String(text.prefix(Self.maxFileBytes))
    }

    /// 校验并返回技能包内可执行脚本的绝对路径：
    /// 仅限 .py、防目录穿越、须为已存在的常规文件且不超过体积上限
    public func scriptURL(name: String, relativePath: String) throws -> URL {
        guard relativePath.hasSuffix(".py") else {
            throw StoreError.notScript
        }
        let resolved = try resolvedResourceURL(name: name, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.notFound(relativePath)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: resolved.path)
        if let size = attributes?[.size] as? Int, size > Self.maxFileBytes {
            throw StoreError.unreadableFile
        }
        return resolved
    }

    /// 校验并返回技能包内任意资源文件的绝对路径（防目录穿越）。产物契约校验用。
    public func resolvedResourceURL(name: String, relativePath: String) throws -> URL {
        let folder = try folderURL(for: name)
        let resolved = folder.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
            throw StoreError.unsafePath
        }
        return resolved
    }

    /// 解析技能元数据（含产物契约 outputs / output-required-fields）；解析失败返回 nil
    public func skill(named name: String) -> Skill? {
        guard let folder = try? folderURL(for: name),
              let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
              var parsed = try? SkillDocument.parse(text) else { return nil }
        parsed.name = name
        return parsed
    }

    /// 技能执行依赖摘要：覆盖技能包内全部 Python 脚本与可选的依赖声明文件。
    /// 授权指纹据此判定——辅助脚本（被导入的模块）发生变化后必须重新核验授权。
    public func executionDependencyDigest(name: String) throws -> String {
        try ScriptBundleSnapshot(root: folderURL(for: name)).digest
    }

    /// 技能包内依赖声明的固定相对路径
    public static let requirementsRelativePath = "scripts/requirements.txt"

    /// 读取技能包内依赖声明（不存在或不可读返回 nil）
    public func requirementsText(name: String) throws -> String? {
        let folder = try folderURL(for: name)
        let url = folder.appendingPathComponent(Self.requirementsRelativePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 写入 / 删除

    /// 解析并校验技能包内的相对路径（防目录穿越），返回绝对 URL
    private func resolvedFileURL(name: String, relativePath: String) throws -> URL {
        let folder = try folderURL(for: name)
        let resolved = folder.appendingPathComponent(relativePath).resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
            throw StoreError.unsafePath
        }
        return resolved
    }

    /// 写入技能包内文件（编辑器保存入口）：自动创建中间目录，原子写入
    public func writeFile(name: String, relativePath: String, content: String) throws {
        let url = try resolvedFileURL(name: name, relativePath: relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        invalidateSnapshot()
    }

    /// 删除技能包内文件（SKILL.md 受保护不可删）
    public func deleteFile(name: String, relativePath: String) throws {
        let normalized = relativePath.trimmingCharacters(in: .whitespaces)
        guard normalized != "SKILL.md" else { throw StoreError.protectedFile }
        let url = try resolvedFileURL(name: name, relativePath: normalized)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.notFound(relativePath)
        }
        try fileManager.removeItem(at: url)
        invalidateSnapshot()
    }

    /// 保存技能为文件夹（SKILL.md + 停用标记同步）
    public func save(_ skill: Skill) throws {
        try withSkillWriteLock(skill.name) {
            let folder = try folderURL(for: skill.name)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = SkillDocument.render(skill)
            try text.write(
                to: folder.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            let marker = folder.appendingPathComponent(Self.disabledMarker)
            if skill.isEnabled {
                Self.removeMarkerQuietly(marker, skill: skill.name)
            } else if !fileManager.fileExists(atPath: marker.path) {
                fileManager.createFile(atPath: marker.path, contents: nil)
            }
            invalidateSnapshot()
        }
    }

    // MARK: - Validation State

    /// 验证状态与技能包分开保存：改动 SKILL.md 不会顺手把旧的“运行通过”带过去。
    public func validationRecord(name: String) -> SkillValidationRecord {
        guard let folder = try? folderURL(for: name),
              let data = try? Data(contentsOf: folder.appendingPathComponent(SkillValidationService.validationFileName)),
              let record = try? JSONDecoder().decode(SkillValidationRecord.self, from: data) else {
            return .unverified
        }
        return record
    }

    public func saveValidationRecord(_ record: SkillValidationRecord, name: String) {
        guard let folder = try? folderURL(for: name) else { return }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(
                to: folder.appendingPathComponent(SkillValidationService.validationFileName),
                options: .atomic
            )
        } catch {
            HubLogger.shared.warning("Skill validation state write failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    /// 先组装完整新包，再原子替换旧包；失败时恢复旧包。
    /// `overwrite == false` 时自动取一个未占用的名字。
    @discardableResult
    public func installPackage(
        _ skill: Skill,
        scripts: [(path: String, content: String)],
        references: [(path: String, content: String)],
        overwrite: Bool,
        preserveExistingResources: Bool = false
    ) throws -> String {
        let requestedName = skill.name
        return try withSkillWriteLock(requestedName) {
            let exists = fileManager.fileExists(
                atPath: try folderURL(for: requestedName).path
            )
            let replacingExisting = exists && overwrite
            let finalName = replacingExisting ? requestedName : uniqueName(for: requestedName)
            let finalFolder = try folderURL(for: finalName)

            var installed = skill
            installed.name = finalName
            let stagingRoot = directoryURL
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let staging = stagingRoot.appendingPathComponent(finalName, isDirectory: true)
            defer { try? fileManager.removeItem(at: stagingRoot) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try SkillDocument.render(installed).write(
                to: staging.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            for script in scripts {
                try writeStaged(script.content, relativePath: script.path, root: staging)
            }
            for reference in references {
                try writeStaged(reference.content, relativePath: reference.path, root: staging)
            }
            if replacingExisting, preserveExistingResources {
                let replaced = Set((scripts.map(\.path) + references.map(\.path)))
                for relative in (try? files(for: requestedName)) ?? [] where !replaced.contains(relative) {
                    let source = try folderURL(for: requestedName).appendingPathComponent(relative)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = staging.appendingPathComponent(relative)
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: source, to: destination)
                }
            }
            if !installed.isEnabled {
                fileManager.createFile(
                    atPath: staging.appendingPathComponent(Self.disabledMarker).path,
                    contents: nil
                )
            }

            // 覆盖前保留旧版本；真正替换只做两次同卷 rename。
            if replacingExisting {
                try snapshotVersion(name: requestedName)
                let backup = stagingRoot.appendingPathComponent("previous-\(finalName)", isDirectory: true)
                try fileManager.moveItem(at: finalFolder, to: backup)
                do {
                    try fileManager.moveItem(at: staging, to: finalFolder)
                    try? fileManager.removeItem(at: backup)
                } catch {
                    if !fileManager.fileExists(atPath: finalFolder.path) {
                        try? fileManager.moveItem(at: backup, to: finalFolder)
                    }
                    throw error
                }
            } else {
                try fileManager.createDirectory(
                    at: finalFolder.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: staging, to: finalFolder)
            }
            // 新包一律从未验证开始；调用方可在保存后写入语法检查结果。
            saveValidationRecord(.unverified, name: finalName)
            invalidateSnapshot()
            return finalName
        }
    }

    private func writeStaged(_ content: String, relativePath: String, root: URL) throws {
        let candidate = root.appendingPathComponent(relativePath)
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            throw StoreError.unsafePath
        }
        try fileManager.createDirectory(
            at: candidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: candidate, atomically: true, encoding: .utf8)
    }

    /// 删除停用标记：标记删不掉时技能会表现为停用，必须记警告（不存在属正常，静默）
    private static func removeMarkerQuietly(_ marker: URL, skill: String) {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        do { try FileManager.default.removeItem(at: marker) }
        catch {
            HubLogger.shared.warning("Skill disabled marker removal failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    public func delete(name: String) throws {
        let folder = try folderURL(for: name)
        guard fileManager.fileExists(atPath: folder.path) else {
            throw StoreError.notFound(name)
        }
        try fileManager.removeItem(at: folder)
        invalidateSnapshot()
    }

    // MARK: - 版本快照（AI 重写 / 导入覆盖前的自动备份，保留最近 5 版）

    /// 技能版本条目：版本目录名（时间戳 id）+ 快照时间
    public struct SkillVersion: Identifiable, Equatable, Sendable {
        public let id: String
        public let date: Date
    }

    static let maxVersions = 5
    /// 独立版本区目录名（以点开头：被 list() 的 .skipsHiddenFiles 跳过，不当作技能）
    static let versionsDirectory = ".versions"

    /// 独立版本区：`<skills>/.versions/<name>/`。刻意放在技能文件夹之外——
    /// 落在文件夹内的快照会随「覆盖时删除旧目录」一起消失，不能作为持久恢复点
    func versionsRootURL(for name: String) throws -> URL {
        _ = try folderURL(for: name)  // 复用 slug 校验，防路径注入
        return directoryURL
            .appendingPathComponent(Self.versionsDirectory, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// 唯一版本 ID（yyyyMMdd-HHmmss；同一秒内冲突则顺延 1 秒直至可用）。
    /// 格式必须匹配 rollback 的白名单 `^[0-9]{8}-[0-9]{6}$`
    private static func uniqueVersionId(versionsRoot: URL) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        var date = Date()
        for _ in 0..<10 {
            let id = formatter.string(from: date)
            if !FileManager.default.fileExists(
                atPath: versionsRoot.appendingPathComponent(id, isDirectory: true).path
            ) {
                return id
            }
            date = date.addingTimeInterval(1)
        }
        return formatter.string(from: date)
    }

    /// 快照当前技能到 .versions/<name>/<yyyyMMdd-HHmmss>（AI 重写 / 导入覆盖前调用）。
    /// 跳过运行产物与既有版本目录（快照的快照没有意义），超过上限裁掉最旧版本
    @discardableResult
    public func snapshotVersion(name: String) throws -> SkillVersion {
        try withSkillWriteLock(name) {
            let folder = try folderURL(for: name)
            guard fileManager.fileExists(atPath: folder.path) else {
                throw StoreError.notFound(name)
            }
            let versionsRoot = try versionsRootURL(for: name)
            try fileManager.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
            let id = Self.uniqueVersionId(versionsRoot: versionsRoot)
            let destination = versionsRoot.appendingPathComponent(id, isDirectory: true)
            // 只快照技能本体（SKILL.md + 资源文件），跳过 scratch/、versions/ 等运行产物
            let resources = (try? files(for: name)) ?? []
            for relative in resources + ["SKILL.md"] {
                let src = folder.appendingPathComponent(relative)
                guard fileManager.fileExists(atPath: src.path) else { continue }
                let dest = destination.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: src, to: dest)
            }
            pruneVersions(name: name)
            return SkillVersion(id: id, date: Date())
        }
    }

    /// 版本列表（新→旧）
    public func listVersions(name: String) throws -> [SkillVersion] {
        let versionsRoot = try versionsRootURL(for: name)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> SkillVersion? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? Date.distantPast
            return SkillVersion(id: url.lastPathComponent, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// 回滚到指定版本：快照当前状态（保底可撤销）后，用版本内容整体覆盖技能文件夹
    public func rollback(name: String, versionId: String) throws {
        try withSkillWriteLock(name) {
            // 版本目录名白名单（防路径注入）
            guard versionId.range(of: "^[0-9]{8}-[0-9]{6}$", options: .regularExpression) != nil else {
                throw StoreError.unsafePath
            }
            let folder = try folderURL(for: name)
            let versionRoot = try versionsRootURL(for: name)
                .appendingPathComponent(versionId, isDirectory: true)
            guard fileManager.fileExists(atPath: versionRoot.path),
                  fileManager.fileExists(
                      atPath: versionRoot.appendingPathComponent("SKILL.md").path
                  ) else {
                throw StoreError.notFound(versionId)
            }
            try snapshotVersion(name: name)
            let currentFiles = (try? files(for: name)) ?? []
            // 删除当前资源文件（SKILL.md 最后直接覆盖），scratch/ 不动。
            // 删不掉的残留会与新版本文件混杂，必须留警告
            for relative in currentFiles {
                do { try fileManager.removeItem(at: folder.appendingPathComponent(relative)) }
                catch {
                    HubLogger.shared.warning("Skill rollback could not remove a stale file: \(HubLogger.safeErrorSummary(error))")
                }
            }
            for file in Self.regularFiles(in: versionRoot) {
                let dest = folder.appendingPathComponent(file.relative)
                try fileManager.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: dest.path) {
                    try fileManager.removeItem(at: dest)
                }
                try fileManager.copyItem(at: file.url, to: dest)
            }
            invalidateSnapshot()
        }
    }

    /// 裁掉超出上限的最旧版本（尽力而为，失败留警告）
    private func pruneVersions(name: String) {
        let versions: [SkillVersion]
        let versionsRoot: URL
        do {
            versions = try listVersions(name: name)
            versionsRoot = try versionsRootURL(for: name)
        } catch {
            HubLogger.shared.warning("Skill version prune skipped: \(HubLogger.safeErrorSummary(error))")
            return
        }
        guard versions.count > Self.maxVersions else { return }
        for stale in versions.suffix(versions.count - Self.maxVersions) {
            do {
                try fileManager.removeItem(
                    at: versionsRoot.appendingPathComponent(stale.id, isDirectory: true)
                )
            } catch {
                HubLogger.shared.warning("Skill version prune failed: \(HubLogger.safeErrorSummary(error))")
            }
        }
    }

    // MARK: - 启用开关（列表行 Toggle 入口，读写停用标记文件）

    /// 运行时门禁：直接检查磁盘，不信任装配名单或实例内的列表缓存。
    /// 管理页的 loadBody/readFile 等底层接口仍可访问停用技能。
    func requireEnabled(name: String) throws {
        let folder = try folderURL(for: name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StoreError.notFound(name)
        }
        do {
            _ = try fileManager.attributesOfItem(
                atPath: folder.appendingPathComponent(Self.disabledMarker).path
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        // 标记存在即停用；读取状态失败则向上抛错，不能视为启用。
        throw StoreError.disabled(name)
    }

    /// 切换技能启用状态：停用 = 写入标记文件，启用 = 删除标记
    public func setEnabled(name: String, enabled: Bool) throws {
        let folder = try folderURL(for: name)
        guard fileManager.fileExists(atPath: folder.path) else {
            throw StoreError.notFound(name)
        }
        let marker = folder.appendingPathComponent(Self.disabledMarker)
        if enabled {
            Self.removeMarkerQuietly(marker, skill: name)
        } else if !fileManager.fileExists(atPath: marker.path) {
            guard fileManager.createFile(atPath: marker.path, contents: nil) else {
                throw StoreError.unreadableFile
            }
        }
        invalidateSnapshot()
    }

    // MARK: - 导出 ZIP

    /// 导出技能包为 ZIP（分发闭环：导入的逆向操作）。
    /// 在临时目录按原相对结构组装后整体压缩，跳过运行产物（scratch/、__pycache__）与停用标记。
    public func exportZip(name: String, to destination: URL) throws {
        try withSkillWriteLock(name) {
            let folder = try folderURL(for: name)
            guard fileManager.fileExists(atPath: folder.path) else {
                throw StoreError.notFound(name)
            }
            // 组装临时副本（zipItem 压缩目录本身，顶层即为技能文件夹名）
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("agroom-skill-export-\(UUID().uuidString)")
            let skillRoot = staging.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: skillRoot, withIntermediateDirectories: true)
            let resources = try files(for: name)
            for relative in resources + ["SKILL.md"] {
                let src = folder.appendingPathComponent(relative)
                guard fileManager.fileExists(atPath: src.path) else { continue }
                let dest = skillRoot.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: src, to: dest)
            }
            defer { try? fileManager.removeItem(at: staging) }

            // NSFileCoordinator .forUploading：系统在协调块内对目录生成临时 ZIP，
            // 块结束即失效，必须在块内复制到目标
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var zipError: Error?

            // 先写到同目录下的临时文件并校验，再原子替换目标——
            // 旧实现先删目标再建 ZIP，一旦压缩失败旧导出包就丢了
            let tempZip = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: tempZip) }
            coordinator.coordinate(readingItemAt: skillRoot, options: .forUploading, error: &coordError) { zipURL in
                do {
                    try fileManager.copyItem(at: zipURL, to: tempZip)
                } catch {
                    zipError = error
                }
            }
            if let coordError { throw coordError }
            if let zipError { throw zipError }
            // 校验临时 ZIP 非空，避免用空壳替换掉可用的旧包
            let attributes = try? fileManager.attributesOfItem(atPath: tempZip.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw StoreError.unreadableFile
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: tempZip)
            } else {
                try fileManager.moveItem(at: tempZip, to: destination)
            }
        }
    }

    /// ZIP 导入预览：名称/描述/文件数/是否覆盖同名技能（确认前不落盘）
    public struct SkillImportPreview: Equatable, Sendable {
        public let name: String
        public let description: String
        public let fileCount: Int
        public let overwritesExisting: Bool
    }

    /// 从外部技能文件夹导入（整个目录拷贝进当前空间技能库）。
    /// 覆盖同名技能：先把旧版本快照进独立版本区（失败即中止覆盖），再把新内容原子换入，
    /// 中途失败不留空目标、旧技能始终可用
    public func importFolder(from sourceURL: URL) throws -> String {
        let skillMD = sourceURL.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillMD, encoding: .utf8),
              let skill = try? SkillDocument.parse(text) else {
            throw StoreError.notFound(sourceURL.lastPathComponent)
        }
        let targetName = skill.isNameValid ? skill.name : Skill.slugify(skill.name)
        return try withSkillWriteLock(targetName) {
            let target = try folderURL(for: targetName)
            // 1) 先完整复制到技能库内的暂存目录并校验：中途失败不留半成品，也不动旧技能
            let staging = directoryURL
                .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: sourceURL, to: staging)
            guard let stagedText = try? String(
                    contentsOf: staging.appendingPathComponent("SKILL.md"), encoding: .utf8
                  ),
                  (try? SkillDocument.parse(stagedText)) != nil else {
                throw StoreError.notFound(sourceURL.lastPathComponent)
            }

            let existed = fileManager.fileExists(atPath: target.path)
            if existed {
                // 2) 覆盖前把旧技能快照进独立版本区；失败即中止覆盖（旧技能原地不动）
                _ = try snapshotVersion(name: targetName)
                // 原子换出：旧目录重命名到同卷暂存区（rename 原子），再把新内容换入
                let replaced = directoryURL
                    .appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: target, to: replaced)
                do {
                    try fileManager.moveItem(at: staging, to: target)
                } catch {
                    // 换入失败：把旧目录搬回，保证不留空目标
                    try? fileManager.moveItem(at: replaced, to: target)
                    throw error
                }
                try? fileManager.removeItem(at: replaced)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
            invalidateSnapshot()
            return targetName
        }
    }

    /// 预检 ZIP 技能包：解压解析元数据，返回预览信息（不写入技能库）
    public func inspectZip(from zipURL: URL) throws -> SkillImportPreview {
        let (root, temp) = try extractZipRoot(from: zipURL)
        defer { try? fileManager.removeItem(at: temp) }
        let skillMD = root.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillMD, encoding: .utf8),
              let skill = try? SkillDocument.parse(text) else {
            throw StoreError.notFound("SKILL.md in \(zipURL.lastPathComponent)")
        }
        let targetName = skill.isNameValid ? skill.name : Skill.slugify(skill.name)
        let fileCount = ((try? filesInFolder(root)) ?? []).count
        let overwrites = (try? folderURL(for: targetName)).map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false
        return SkillImportPreview(
            name: targetName,
            description: skill.description,
            fileCount: fileCount,
            overwritesExisting: overwrites
        )
    }

    /// 解压 ZIP 并定位技能根目录（zip 根或唯一一级子目录）。
    /// 返回 (根目录, 临时目录)；调用方负责清理临时目录
    private func extractZipRoot(from zipURL: URL) throws -> (root: URL, temp: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)

        // macOS 自带 ditto 解压（兼容 Finder 压缩包与 __MACOSX 结构）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, temp.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: temp)
            throw StoreError.notFound(zipURL.lastPathComponent)
        }

        // 清除 Finder 压缩产生的资源叉目录
        let macosx = temp.appendingPathComponent("__MACOSX", isDirectory: true)
        if fileManager.fileExists(atPath: macosx.path) {
            try? fileManager.removeItem(at: macosx)
        }

        // 定位根：zip 根直接有 SKILL.md，或唯一一级子目录里有
        if fileManager.fileExists(atPath: temp.appendingPathComponent("SKILL.md").path) {
            return (temp, temp)
        }
        let entries = (try? fileManager.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        if directories.count == 1,
           fileManager.fileExists(atPath: directories[0].appendingPathComponent("SKILL.md").path) {
            return (directories[0], temp)
        }
        try? fileManager.removeItem(at: temp)
        throw StoreError.notFound("SKILL.md in \(zipURL.lastPathComponent)")
    }

    /// 枚举目录内资源文件（同 files(for:) 的过滤规则，用于导入预览）
    private func filesInFolder(_ folder: URL) throws -> [String] {
        Self.regularFiles(in: folder)
            .map(\.relative)
            .filter { $0 != "SKILL.md" && !Self.isRuntimeArtifact($0) }
    }

    /// 导入 ZIP 技能包：解压到临时目录，定位 SKILL.md 根（zip 根或唯一一级子目录）后整包导入
    public func importZip(from zipURL: URL) throws -> String {
        let (root, temp) = try extractZipRoot(from: zipURL)
        defer { try? fileManager.removeItem(at: temp) }
        return try importFolder(from: root)
    }

    /// 若同名技能已存在，返回加序号的可用名称（name-2、name-3…），AI 新增防覆盖用
    public func uniqueName(for desired: String) -> String {
        let base = (try? folderURL(for: desired)) != nil ? desired : "generated-skill"
        guard fileManager.fileExists(
            atPath: directoryURL.appendingPathComponent(base, isDirectory: true).path
        ) else { return base }
        var index = 2
        while fileManager.fileExists(
            atPath: directoryURL.appendingPathComponent("\(base)-\(index)", isDirectory: true).path
        ) {
            index += 1
        }
        return "\(base)-\(index)"
    }

    /// 旧数据库技能一次性迁移到文件系统（每个空间技能库仅执行一次，UserDefaults 标记）。
    ///
    /// 必须一次性：若每次列表加载都重新迁移，用户删除技能文件夹后，
    /// 下一次 load() 会用旧库记录把文件夹原样复活——表现为"技能删不掉"
    /// （调用点：SkillsView.load 与 ChatView.buildEngine，两处共用本标记）。
    @discardableResult
    public func migrateFromLegacy(_ legacySkills: [Skill]) -> Int {
        // 目录结构 …/AgRoom/<space>/skills，父目录名即空间标识
        let spaceKey = directoryURL.deletingLastPathComponent().lastPathComponent
        let flagKey = "agroom.skills.legacyMigrated.\(spaceKey)"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return 0 }
        // 先置位再迁移：保证删除后的文件夹绝不会再次被旧库复活
        UserDefaults.standard.set(true, forKey: flagKey)

        var migrated = 0
        for skill in legacySkills {
            var standardized = skill
            if !standardized.isNameValid {
                standardized.name = Skill.slugify(standardized.name)
            }
            if standardized.name.isEmpty { continue }
            if (try? folderURL(for: standardized.name)) != nil,
               fileManager.fileExists(
                   atPath: directoryURL.appendingPathComponent(standardized.name).path
               ) {
                continue
            }
            do {
                try save(standardized)
                migrated += 1
            } catch {
                HubLogger.shared.warning("Legacy skill migration failed: \(HubLogger.safeErrorSummary(error))")
            }
        }
        return migrated
    }
}
