import Foundation
import Darwin

/// The offline helper resolves wheels with the managed base copy of pip.
/// Missing HTTP responses are requested from the host through a per-run file exchange.
public enum PackageDownload {
    public static func arguments(requirement: String) -> [String] {
        ["-I", "-S", "-B", "-c", program, requirement]
    }

    /// Run the managed base copy of pip with the target interpreter's installation paths.
    /// -S avoids executing third-party site hooks while an environment is writable.
    public static func offlineArguments(_ arguments: [String]) -> [String] {
        ["-I", "-S", "-B", "-c", #"""
        import mimetypes, pathlib, sys, sysconfig
        base, platbase = sys.base_prefix, sys.base_exec_prefix
        target = pathlib.Path(sys.executable).parent.parent
        if (target / "pyvenv.cfg").is_file():
            sys.prefix = sys.exec_prefix = str(target)
        base_paths = sysconfig.get_paths(vars={"base": base, "platbase": platbase})
        target_paths = sysconfig.get_paths(vars={"base": sys.prefix, "platbase": sys.exec_prefix})
        for key in ("purelib", "platlib"):
            if base_paths[key] not in sys.path:
                sys.path.append(base_paths[key])
        mimetypes.knownfiles = []
        mimetypes.init(files=[])
        from pip._internal.cli.main import main
        if sys.prefix != base:
            sys.path[:] = [p for p in sys.path if p not in (base_paths["purelib"], base_paths["platlib"])]
            for key in ("purelib", "platlib"):
                if target_paths[key] not in sys.path:
                    sys.path.append(target_paths[key])
        sys.exit(main(sys.argv[1:]))
        """#, "--isolated", "--no-input", "--no-cache-dir", "--disable-pip-version-check"] + arguments
    }

    public static func validRequirement(_ requirement: String) -> Bool {
        requirement.utf8.count <= 256 && requirement.wholeMatch(of: /^[A-Za-z0-9][A-Za-z0-9._+!<>=~*\[\],-]*$/) != nil
    }

    public static func permits(_ request: ScriptRunnerRequest) -> Bool {
        guard !request.allowsNetwork, request.purpose == .packageResolution else { return false }
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return false }
        let documents = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Documents/AgRoom")
        let runtime = documents.appendingPathComponent("python-runtime").standardizedFileURL
        let space: String
        switch request.helperIdentifier {
        case "com.agroom.runner.personal": space = "personal"
        case "com.agroom.runner.work": space = "work"
        default: return false
        }
        let transfers = documents.appendingPathComponent("python/\(space)/workspace/package-downloads").standardizedFileURL
        func runRoot(_ path: String) -> URL? {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent().path == transfers.path,
                  UUID(uuidString: url.lastPathComponent) != nil, url.resolvingSymlinksInPath().path == url.path else { return nil }
            return url
        }
        let reads = Set(request.bookmarks.map(\.path))
        guard let run = reads.compactMap(runRoot).first,
              reads.isSubset(of: [run.path, runtime.path]),
              runtime.resolvingSymlinksInPath().path == runtime.path else { return false }
        if request.phase == .prepareScopes { return request.writeBookmarks.isEmpty }
        let output = run.appendingPathComponent("output").path
        let temporary = run.appendingPathComponent("tmp").path
        let scratchHome = run.appendingPathComponent("home").path
        let executable = runtime.appendingPathComponent("bin/python3")
        guard let requirement = request.arguments.last, validRequirement(requirement) else { return false }
        return request.arguments == arguments(requirement: requirement) && request.executable == executable.path
            && executable.resolvingSymlinksInPath().path.hasPrefix(runtime.path + "/")
            && request.directory == output && request.standardIO == nil
            && Set(request.writeBookmarks.map(\.path)) == [output, temporary, scratchHome]
            && request.environment == ["HOME": scratchHome, "TMPDIR": temporary, "LANG": "en_US.UTF-8",
                                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"]
    }

    // -S skips startup hooks, and only the managed base installation supplies pip.
    // The adapter never opens a socket. The host independently validates every cache miss,
    // including redirects and dependency metadata, before performing a bounded public GET.
    public static let program = #"""
    import hashlib, json, mimetypes, os, pathlib, re, sys, sysconfig
    from urllib.parse import urlsplit, unquote

    sys.path.append(sysconfig.get_path("purelib"))
    os.environ["PIP_CONFIG_FILE"] = os.devnull
    # Wheel handling only needs the built-in table. Host MIME files are outside the grant.
    mimetypes.knownfiles = []
    mimetypes.init(files=[])
    from pip._internal.cli.main import main
    from pip._internal.network.session import PipSession
    from pip._internal.operations.prepare import RequirementPreparer
    from pip._vendor.requests.adapters import HTTPAdapter
    from pip._vendor.requests.models import Response
    from pip._vendor.requests.structures import CaseInsensitiveDict

    exchange = pathlib.Path.cwd().parent / "network"
    pending = pathlib.Path("network-request.json")
    pending.unlink(missing_ok=True)

    def permitted(url, wheel_only=False):
        parts = urlsplit(url)
        if parts.scheme != "https" or parts.username or parts.password or parts.port not in (None, 443):
            return False
        if parts.hostname == "pypi.org" and not wheel_only:
            return parts.path.startswith("/simple/")
        return (parts.hostname == "files.pythonhosted.org" and parts.path.startswith("/packages/")
                and parts.path.endswith((".whl",) if wheel_only else (".whl", ".whl.metadata")))

    def send(adapter, request, **kwargs):
        if request.method not in ("GET", "HEAD") or not permitted(request.url):
            raise ValueError("Package transport refused a destination outside the wheel index.")
        headers = {key: request.headers[key] for key in ("Accept", "Range") if key in request.headers}
        headers = {key.lower(): value for key, value in headers.items()}
        identity = "\n".join((request.method, request.url, headers.get("accept", ""), headers.get("range", "")))
        key = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        metadata = exchange / (key + ".json")
        if not metadata.is_file():
            with pending.open("x", encoding="utf-8") as handle:
                json.dump({"method": request.method, "url": request.url, "headers": headers, "key": key}, handle)
            # No package code is running here. Exit before pip can retry or replace the
            # adapter; the host replays this fixed resolver with the new cached response.
            os._exit(0)
        cached = json.loads(metadata.read_bytes())
        response = Response()
        response.status_code = cached["status"]
        response.headers = CaseInsensitiveDict(cached["headers"])
        response.url, response.request = request.url, request
        response.raw = (exchange / (key + ".body")).open("rb")
        response.connection = adapter
        return response
    HTTPAdapter.send = send

    prepare_wheel = RequirementPreparer.prepare_linked_requirement
    def prepare(self, req, *args, **kwargs):
        if not req.link or not req.link.is_wheel or not permitted(req.link.url, wheel_only=True):
            raise ValueError("Only indexed HTTPS wheels can be prepared.")
        return prepare_wheel(self, req, *args, **kwargs)
    RequirementPreparer.prepare_linked_requirement = prepare

    report = pathlib.Path(os.environ["TMPDIR"]) / "resolution.json"
    status = main(["--isolated", "--disable-pip-version-check", "--no-input", "--no-cache-dir", "install",
                   "--ignore-installed", "--dry-run", "--report", str(report), "--only-binary=:all:",
                   "--index-url", "https://pypi.org/simple/", "--keyring-provider", "disabled", sys.argv[1]])
    if status:
        sys.exit(status)
    resolution = json.loads(report.read_bytes())
    items = resolution["install"]
    if resolution["version"] != "1" or not 0 < len(items) <= 256:
        raise ValueError("Unsupported package resolution.")
    names, lock, total = set(), [], 0
    with PipSession() as session:
        session.trust_env = False
        for item in items:
            info, meta = item["download_info"], item["metadata"]
            url = info["url"]
            digest = info["archive_info"]["hashes"]["sha256"]
            name, version = meta["name"], meta["version"]
            filename = unquote(urlsplit(url).path.rsplit("/", 1)[-1])
            if (item["is_direct"] or not permitted(url, wheel_only=True)
                    or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.+!-]{0,245}\.whl", filename)
                    or not re.fullmatch(r"[a-f0-9]{64}", digest) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name)
                    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.!+_-]*", version) or name.lower() in names):
                raise ValueError("Invalid wheel manifest.")
            names.add(name.lower())
            if pathlib.Path(filename).exists():
                pathlib.Path(filename).unlink()
            hasher, size = hashlib.sha256(), 0
            # Request first: a cache miss exits before creating a partial wheel.
            with session.get(url, stream=True, timeout=30) as response, open(filename, "xb") as wheel:
                response.raise_for_status()
                for chunk in response.iter_content(128 * 1024):
                    size += len(chunk)
                    total += len(chunk)
                    if size > 512 * 1024**2 or total > 1024**3:
                        raise ValueError("Wheel download exceeds the transfer budget.")
                    hasher.update(chunk)
                    wheel.write(chunk)
            if hasher.hexdigest() != digest:
                raise ValueError("Wheel checksum does not match the index.")
            lock.append(f"{name}=={version} --hash=sha256:{digest}")
    with open("requirements.lock", "x", encoding="ascii") as handle:
        handle.write("\n".join(sorted(lock)) + "\n")
    """#
}
