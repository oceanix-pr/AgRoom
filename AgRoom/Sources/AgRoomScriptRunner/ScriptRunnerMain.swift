import Darwin
import Foundation
import Security
import AgRoomScriptIPC

/// 独立 App Sandbox 身份的单次执行器。不依赖 Core、数据库、Keychain 或 UI。
/// 解析授权后原位 exec：监控的 PID 不变，取消/超时继续由宿主唯一执行链负责。
@main
enum ScriptRunnerMain {
    static func main() {
        do {
            let bytes = try FileHandle.standardInput.read(upToCount: ScriptRunnerRequest.maximumBytes + 1) ?? Data()
            guard bytes.count <= ScriptRunnerRequest.maximumBytes else { throw ScriptRunnerFailure(.scopeLimitExceeded, stage: .request) }
            let request: ScriptRunnerRequest
            do { request = try JSONDecoder().decode(ScriptRunnerRequest.self, from: bytes) }
            catch { throw ScriptRunnerFailure(.invalidRequest, stage: .request) }
            try validate(request)
            var scopes: [URL] = []
            for (index, bookmark) in request.bookmarks.enumerated() {
                var stale = false
                var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
                if request.phase == .execute { options.insert(.withSecurityScope) }
                let url: URL
                do { url = try URL(resolvingBookmarkData: bookmark.data, options: options,
                                   relativeTo: nil, bookmarkDataIsStale: &stale) }
                catch { throw ScriptRunnerFailure(.bookmarkResolutionFailed, stage: .inputScopes, scopeIndex: index) }
                guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
                    throw ScriptRunnerFailure(.scopeAccessDenied, stage: .inputScopes, scopeIndex: index)
                }
                guard canonicalPath(url) == bookmark.path else { throw ScriptRunnerFailure(.bookmarkPathMismatch, stage: .inputScopes, scopeIndex: index) }
                guard ScriptRunnerFileIdentity.capture(url) == bookmark.identity else {
                    throw ScriptRunnerFailure(.bookmarkIdentityMismatch, stage: .inputScopes, scopeIndex: index)
                }
                // Stale means bookmark metadata needs refreshing, not that access was revoked.
                // Preparation always creates a new read-only token. Execution may refresh it only
                // after scope activation, canonical-path and object-identity checks all pass.
                if stale && request.phase == .execute {
                    do { _ = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) }
                    catch { throw ScriptRunnerFailure(.bookmarkCreationFailed, stage: .inputScopes, scopeIndex: index) }
                }
                scopes.append(url)
            }
            if request.phase == .prepareScopes {
                // 此进程只运行可信授权逻辑。它收到的临时读写 scope 不传给执行进程。
                let readOnly = try scopes.enumerated().map { index, url in
                    do { return ScriptRunnerBookmark(data: try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]),
                                                    path: canonicalPath(url), identity: request.bookmarks[index].identity) }
                    catch { throw ScriptRunnerFailure(.bookmarkCreationFailed, stage: .prepareScopes, scopeIndex: index) }
                }
                let result = try JSONEncoder().encode(readOnly)
                guard result.count <= ScriptRunnerRequest.maximumBytes else { throw ScriptRunnerFailure(.scopeLimitExceeded, stage: .prepareScopes) }
                FileHandle.standardOutput.write(result)
                return
            }
            for (index, bookmark) in request.writeBookmarks.enumerated() {
                var stale = false
                let url: URL
                do { url = try URL(resolvingBookmarkData: bookmark.data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) }
                catch { throw ScriptRunnerFailure(.bookmarkResolutionFailed, stage: .writeScopes, scopeIndex: index) }
                guard url.isFileURL, url.startAccessingSecurityScopedResource() else { throw ScriptRunnerFailure(.scopeAccessDenied, stage: .writeScopes, scopeIndex: index) }
                guard canonicalPath(url) == bookmark.path else { throw ScriptRunnerFailure(.bookmarkPathMismatch, stage: .writeScopes, scopeIndex: index) }
                guard ScriptRunnerFileIdentity.capture(url) == bookmark.identity else {
                    throw ScriptRunnerFailure(.bookmarkIdentityMismatch, stage: .writeScopes, scopeIndex: index)
                }
                scopes.append(url)
            }
            // 授权数据不进入 Python stdin，也不留下能被脚本再次读取的控制文件。
            try attach(request.standardIO?.input ?? "/dev/null", to: STDIN_FILENO, writing: false)
            if let path = request.standardIO?.output { try attach(path, to: STDOUT_FILENO, writing: true) }
            if let path = request.standardIO?.error { try attach(path, to: STDERR_FILENO, writing: true) }
            guard chdir(request.directory) == 0 else { throw ScriptRunnerFailure(.directoryAccessDenied, stage: .workingDirectory) }
            umask(0o077)
            var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
            var processLimit = rlimit(rlim_cur: 0, rlim_max: 0)
            // rlimit 存在本进程中，不改变宿主或其他 App 的限制。硬限额为零，脚本不能再抬高。
            guard getuid() != 0, geteuid() != 0,
                  setrlimit(RLIMIT_CORE, &coreLimit) == 0,
                  setrlimit(RLIMIT_NPROC, &processLimit) == 0 else { throw ScriptRunnerFailure(.resourceLimitFailed, stage: .resourceLimits) }
            let redirected = request.standardIO?.output != nil || request.standardIO?.error != nil
            let fileBytes = redirected ? UInt64(ScriptRunnerStandardIO.maximumFileBytes)
                : (request.purpose == .packageResolution ? 512 * 1024 * 1024 : ScriptRunnerLimits.maximumFileBytes)
            var fileLimit = rlimit(rlim_cur: rlim_t(fileBytes), rlim_max: rlim_t(fileBytes))
            var cpuLimit = rlimit(rlim_cur: 300, rlim_max: 300)
            var descriptorLimit = rlimit(rlim_cur: 1024, rlim_max: 1024)
            guard setrlimit(RLIMIT_FSIZE, &fileLimit) == 0,
                  setrlimit(RLIMIT_CPU, &cpuLimit) == 0,
                  setrlimit(RLIMIT_NOFILE, &descriptorLimit) == 0 else {
                throw ScriptRunnerFailure(.resourceLimitFailed, stage: .resourceLimits)
            }
            let arguments = [request.executable] + request.arguments
            let environment = request.environment.map { "\($0.key)=\($0.value)" }
            try withExtendedLifetime(scopes) {
                try exec(arguments: arguments, environment: environment)
            }
        } catch {
            // 固定诊断，不把书签、源码或请求中的路径写入日志。
            let failure = error as? ScriptRunnerFailure ?? ScriptRunnerFailure(.invalidRequest, stage: .request)
            if let data = try? JSONEncoder().encode(failure) { FileHandle.standardError.write(data) }
            exit(78)
        }
    }

    private static func attach(_ path: String, to stream: Int32, writing: Bool) throws {
        let flags = (writing ? O_WRONLY | O_TRUNC : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor = open(path, flags)
        guard descriptor >= 0 else { throw ScriptRunnerFailure(.stdioAccessDenied, stage: .standardIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT == S_IFREG || !writing && path == "/dev/null"),
              dup2(descriptor, stream) >= 0 else { throw ScriptRunnerFailure(.stdioAccessDenied, stage: .standardIO) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return "" }
        defer { free(path) }
        return String(cString: path)
    }

    private static func validate(_ request: ScriptRunnerRequest) throws {
        guard request.version == ScriptRunnerRequest.currentVersion else { throw ScriptRunnerFailure(.protocolMismatch, stage: .request) }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var rawInfo: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              entitlements["com.apple.security.inherit"] as? Bool != true,
              entitlements["com.apple.security.network.client"] as? Bool != true, !request.allowsNetwork,
              ["com.agroom.runner.personal", "com.agroom.runner.work"].contains(identifier),
              identifier == request.helperIdentifier else { throw ScriptRunnerFailure(.identityMismatch, stage: .identity) }
        guard
              request.bookmarks.count + request.writeBookmarks.count <= 256, !request.bookmarks.isEmpty,
              request.directory.hasPrefix("/"),
              (request.phase == .prepareScopes
                ? request.executable.isEmpty && request.arguments.isEmpty && request.environment.isEmpty && request.writeBookmarks.isEmpty && request.standardIO == nil
                : request.executable.hasPrefix("/")),
              ([request.executable, request.directory] + request.arguments
               + Array(request.environment.keys) + Array(request.environment.values)).allSatisfy({ !$0.contains("\0") }),
              request.environment.keys.allSatisfy({ !$0.contains("=") }) else {
            throw ScriptRunnerFailure(.invalidRequest, stage: .request)
        }
        if request.purpose == .packageResolution && !PackageDownload.permits(request) {
            throw ScriptRunnerFailure(.invalidRequest, stage: .request)
        }
        let streams = [request.standardIO?.input, request.standardIO?.output, request.standardIO?.error].compactMap { $0 }
        guard streams.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              request.standardIO?.output == nil || request.standardIO?.output != request.standardIO?.error else {
            throw ScriptRunnerFailure(.invalidRequest, stage: .request)
        }
    }

    private static func exec(arguments: [String], environment: [String]) throws -> Never {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw ScriptRunnerFailure(.execFailed, stage: .execution)
        }
        var executionError: Int32 = 0
        argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                _ = execve(args[0]!, args.baseAddress!, env.baseAddress!)
                executionError = errno
            }
        }
        throw ScriptRunnerFailure(.execFailed, stage: .execution, systemError: executionError)
    }
}
