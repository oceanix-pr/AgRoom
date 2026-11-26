import Foundation
import Darwin
import CryptoKit

/// 严格的单命令只读子集。解析通过后直接启动固定系统程序，不经过 shell、PATH 或启动脚本。
/// 不支持变量、通配符、重定向、管道、命令替换、环境赋值与复合命令。
///
/// 规则表按程序核对选项、操作数、Git 子命令或受限表达式。
/// rg 逐项放行查询/枚举选项（`--pre`、`--search-zip`、`--follow` 等仍不可用），
/// 执行侧强制追加 `--no-config`。sed 仅识别一项数字行号打印表达式。排除 awk/perl/ruby、
/// defaults（读写范围超出工作区语义）、pbcopy/open/osascript/xargs（副作用或执行入口）、
/// sort（`-o` 可覆盖写文件）以及 git 的写/联网子命令（checkout/switch/restore/clean/fetch/push 等）。
struct ShellReadOnlyCommand: Sendable {
    let executable: String
    let arguments: [String]
    let paths: [String]
    /// 执行侧拼接在 argv 前的硬化参数（git：-c core.pager=cat 等）
    let injectedPrefix: [String]
    /// 执行侧拼接在 argv 尾的硬化参数（git diff 族：--no-ext-diff --no-textconv）
    let injectedSuffix: [String]
    /// git 专用：执行侧须注入 GIT_CEILING_DIRECTORIES / GIT_CONFIG_NOSYSTEM / GIT_TERMINAL_PROMPT
    let needsRepositoryCeiling: Bool

    init(executable: String, arguments: [String], paths: [String],
         injectedPrefix: [String] = [], injectedSuffix: [String] = [],
         needsRepositoryCeiling: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.paths = paths
        self.injectedPrefix = injectedPrefix
        self.injectedSuffix = injectedSuffix
        self.needsRepositoryCeiling = needsRepositoryCeiling
    }

    func isInside(workspace: URL, directory: URL) -> Bool {
        isInside(workspaces: [workspace], directory: directory)
    }

    func operandURLs(in directory: URL) -> [URL] {
        paths.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : directory.appendingPathComponent($0) }
    }

    func isInside(workspaces: [URL], directory: URL) -> Bool {
        guard let current = workspaces.filter({ FileAreaService.isInside(directory, root: $0) })
            .max(by: { $0.path.count < $1.path.count }) else { return false }
        if needsRepositoryCeiling, !GitRepositoryInspector.isConfined(directory: directory, workspace: current) { return false }
        let roots = needsRepositoryCeiling ? [current] : workspaces
        return operandURLs(in: directory).allSatisfy { url in roots.contains { FileAreaService.isInside(url, root: $0) } }
    }

    // MARK: 规则表

    /// 操作数策略：none=禁止；ignored=不校验（程序名/文本/变量名等非路径参数）；
    /// paths=收集并校验工作区；plusFormat=date 专用（至多 1 个且必须 "+" 开头——裸数字会设置系统时钟）；
    /// any=git 专用（ref/pathspec 混合，不校验，越界防护在执行侧）
    private enum OperandRule: Sendable {
        case none, ignored, paths(required: Bool), plusFormat, any

        /// 标准输入已由管道或 `< /dev/null` 提供时，路径操作数不再必需
        var allowingStdin: OperandRule {
            if case .paths = self { return .paths(required: false) }
            return self
        }
    }

    private enum ProgramRule: Sendable {
        case simple(executable: String, options: String, numericOptions: [Character: ClosedRange<Int>], operand: OperandRule)
        case git(executable: String)
        case find(executable: String)
        case grep(executable: String, options: String)
        case sedLines
        case ripgrep

        var executable: String {
            switch self {
            case .simple(let executable, _, _, _), .git(let executable), .find(let executable), .grep(let executable, _):
                return executable
            case .ripgrep:
                return ShellReadOnlyCommand.resolvedRipgrepExecutable()
            case .sedLines:
                return "/usr/bin/sed"
            }
        }
    }

    /// git 子命令规则：options 为允许的单字符选项集（含数字位，覆盖 `-5`/`-U3` 粘连形态——
    /// 数字不是选项字母、不引入新语义）；操作数计数区间约束读形态
    private struct GitSubcommandRule: Sendable {
        var options: String = ""
        var minOperands = 0
        var maxOperands: Int = .max
        /// diff 族（diff/log/show/stash show）：执行侧追加 --no-ext-diff --no-textconv
        var diffCapable = false
    }

    private static let rules: [String: ProgramRule] = [
        "pwd": .simple(executable: "/bin/pwd", options: "LP", numericOptions: [:], operand: .none),
        "printf": .simple(executable: "/usr/bin/printf", options: "", numericOptions: [:], operand: .ignored),
        "ls": .simple(executable: "/bin/ls", options: "aAbBcCdFfGghiklmnopqRrSstTuUvw1@", numericOptions: [:], operand: .paths(required: false)),
        "cat": .simple(executable: "/bin/cat", options: "benstuv", numericOptions: [:], operand: .paths(required: true)),
        "head": .simple(executable: "/usr/bin/head", options: "", numericOptions: ["n": 0...100_000], operand: .paths(required: true)),
        "tail": .simple(executable: "/usr/bin/tail", options: "", numericOptions: ["n": 0...100_000], operand: .paths(required: true)),
        "wc": .simple(executable: "/usr/bin/wc", options: "clmwL", numericOptions: [:], operand: .paths(required: true)),
        "stat": .simple(executable: "/usr/bin/stat", options: "", numericOptions: [:], operand: .paths(required: true)),
        "du": .simple(executable: "/usr/bin/du", options: "ahkmsc", numericOptions: [:], operand: .paths(required: false)),
        "file": .simple(executable: "/usr/bin/file", options: "biIL", numericOptions: [:], operand: .paths(required: true)),
        "uname": .simple(executable: "/usr/bin/uname", options: "amnprsv", numericOptions: [:], operand: .none),
        "sw_vers": .simple(executable: "/usr/bin/sw_vers", options: "", numericOptions: [:], operand: .none),
        "which": .simple(executable: "/usr/bin/which", options: "as", numericOptions: [:], operand: .ignored),
        "echo": .simple(executable: "/bin/echo", options: "n", numericOptions: [:], operand: .ignored),
        // date：plusFormat 防止 `date 0712123456` 裸数字设置系统时钟
        "date": .simple(executable: "/bin/date", options: "nu", numericOptions: [:], operand: .plusFormat),
        // hostname：禁操作数，防改主机名
        "hostname": .simple(executable: "/bin/hostname", options: "", numericOptions: [:], operand: .none),
        "whoami": .simple(executable: "/usr/bin/whoami", options: "", numericOptions: [:], operand: .none),
        "printenv": .simple(executable: "/usr/bin/printenv", options: "", numericOptions: [:], operand: .ignored),
        // md5：剔除 -s（字符串参数）与 -p（stdin）
        "md5": .simple(executable: "/sbin/md5", options: "qr", numericOptions: [:], operand: .paths(required: true)),
        // shasum：剔除 -c 校验模式（会读取清单文件里列出的任意路径）；无效算法值由 shasum 自身报错，无安全影响
        "shasum": .simple(executable: "/usr/bin/shasum", options: "", numericOptions: ["a": 1...512], operand: .paths(required: true)),
        // df：操作数仅选择文件系统，行为只读，不做路径校验
        "df": .simple(executable: "/bin/df", options: "hin", numericOptions: [:], operand: .ignored),
        "uptime": .simple(executable: "/usr/bin/uptime", options: "", numericOptions: [:], operand: .none),
        "git": .git(executable: "/usr/bin/git"),
        "find": .find(executable: "/usr/bin/find"),
        // BSD grep 无执行类选项；带参选项（-m -A -B -C -e -f）第一版不放行
        "grep": .grep(executable: "/usr/bin/grep", options: "inrRvclwEFqxhHos"),
        "sed": .sedLines,
        // 每次解析重新核对安装位置，Homebrew 升级后不能继续使用旧的程序身份。
        "rg": .ripgrep,
    ]

    /// rg 可能位于 Homebrew 或 MacPorts 前缀；解析符号链接后应落在 Cellar 等只读根内。
    static func resolvedRipgrepExecutable() -> String {
        let candidates = [
            "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/opt/local/bin/rg", "/usr/bin/rg",
        ]
        return candidates.lazy
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .path ?? ""
    }

    private static let gitSubcommands: [String: GitSubcommandRule] = [
        "status": GitSubcommandRule(options: "sbvzuno"),
        "diff": GitSubcommandRule(options: "puswbcRMU0123456789", diffCapable: true),
        "log": GitSubcommandRule(options: "puswbcnU0123456789", diffCapable: true),
        "show": GitSubcommandRule(options: "puswbcnU0123456789", diffCapable: true),
        "rev-parse": GitSubcommandRule(),
        "rev-list": GitSubcommandRule(options: "cn0123456789"),
        "ls-files": GitSubcommandRule(options: "cdmosz"),
        "ls-tree": GitSubcommandRule(options: "rzdlt"),
        // blame：-L 带独立参数，不放行
        "blame": GitSubcommandRule(options: "bewMC", minOperands: 1),
        "shortlog": GitSubcommandRule(options: "sne0123456789"),
        "describe": GitSubcommandRule(),
        "cat-file": GitSubcommandRule(options: "ptse", minOperands: 1, maxOperands: 2),
        // reflog 的 delete/drop/expire/write 均会修改引用日志，不能作为普通 ref 放行。
        "reflog": GitSubcommandRule(options: "0123456789", maxOperands: 0),
        "name-rev": GitSubcommandRule(),
        "merge-base": GitSubcommandRule(options: "a", minOperands: 2),
        // git grep：-e/-f 带参数，不放行
        "grep": GitSubcommandRule(options: "nrivwlEFh", minOperands: 1),
        "count-objects": GitSubcommandRule(options: "sv", maxOperands: 0),
        // branch/tag/remote：零操作数即只允许列举形态——创建、删除、改名形态全部拒绝
        // （-d -D -m -M -a -s -c -u -t 等写选项本就不在选项集内）
        "branch": GitSubcommandRule(options: "arv", maxOperands: 0),
        "tag": GitSubcommandRule(options: "ln0123456789", maxOperands: 0),
        "remote": GitSubcommandRule(options: "v", maxOperands: 0),
        // config：双形态——`config -l`（有选项时零操作数）或 `config user.name`（无选项恰 1 个）；
        // 2 个操作数是写入，拒绝
        "config": GitSubcommandRule(options: "l", maxOperands: 1),
        // stash 仅 list / show（见 parseGit 特判；stash@{n} 被元字符禁令中的 {} 天然挡掉）
    ]

    /// find 带 1 参数谓词；-newer 的参数是参照文件，须进 paths 校验
    private static let findOneArgPredicates: Set<String> = [
        "-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth", "-size",
        "-newer", "-mtime", "-atime", "-ctime", "-mmin", "-amin", "-cmin",
        "-perm", "-user", "-group",
    ]
    private static let findNoArgPredicates: Set<String> = [
        "-empty", "-print", "-print0", "-prune", "-ls", "-depth", "-d", "-x", "-o", "-a",
    ]
    // 纵深防御：-delete -exec -execdir -ok -okdir -fprint -fprintf 不在白名单即拒
    // （`-exec … +` 的 `+` 终结符不含元字符，元字符禁令挡不住，只能靠谓词白名单）

    /// 复合脚本里禁止出现的字符：变量、命令替换、通配、子 shell、花括号、转义与历史展开一律不解释。
    /// `<` `>` `&` `|` `;` 由词法器按语法处理，不在此闸门内
    private static let scriptForbiddenCharacters: Set<Character> = [
        "$", "`", "(", ")", "{", "}", "[", "]", "*", "?", "!", "\\", "~", "#",
    ]

    /// BSD 计数简写 `-5`（仅 head/tail）：等价于 `-n 5`
    private static let bareCountPrograms: Set<String> = ["head", "tail"]

    /// 没有路径操作数时从标准输入读取的程序：管道下游或 `< /dev/null` 时放宽路径要求
    private static let stdinPrograms: Set<String> = ["cat", "head", "tail", "wc", "md5", "shasum"]

    // MARK: 解析入口与分派

    static func parse(_ script: String) -> Self? {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, script.count <= 8192,
              !script.contains(where: { "$`;&|><(){}[]*?!\\~\n\r".contains($0) || $0.isASCII && $0.asciiValue! < 32 && $0 != "\t" }),
              let words = words(script) else { return nil }
        return parseCommand(words: words, stdinAvailable: false)
    }

    /// 已分词参数只解释程序选项；正则、美元符号等字面数据不再经过 Shell 词法闸门。
    static func parse(arguments: [String], stdinAvailable: Bool = false) -> Self? {
        guard arguments.count <= 256,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 8192,
              arguments.allSatisfy({ !$0.contains("\0") }) else { return nil }
        return parseCommand(words: arguments, stdinAvailable: stdinAvailable)
    }

    /// 单条命令的规则分派。`stdinAvailable` = 管道或 `< /dev/null` 已提供标准输入，
    /// 此时只读程序可以不写路径操作数（`cat | head -5`、`... | wc -l`）。
    private static func parseCommand(words: [String], stdinAvailable: Bool) -> Self? {
        guard let first = words.first else { return nil }
        // zsh 的 `=cmd` 会展开成同名命令的路径，不能按字面路径核对
        guard !words.contains(where: { $0.hasPrefix("=") }) else { return nil }
        let name = (first as NSString).lastPathComponent
        guard let rule = rules[name], first == name || first.hasPrefix("/") else { return nil }
        let configured = rule.executable
        guard !configured.isEmpty else { return nil }
        // 识别与执行共用固定解析器；允许同一可信程序的安装链接，拒绝同名替身。
        let directory = URL(fileURLWithPath: "/")
        guard let expected = ShellRunTool.resolveExecutable(configured, workingDirectory: directory),
              let actual = ShellRunTool.resolveExecutable(first, workingDirectory: directory),
              actual == expected else { return nil }
        let executable = actual.path
        let arguments = Array(words.dropFirst())
        let readsStdin = stdinAvailable && stdinPrograms.contains(name)
        switch rule {
        case .simple(_, let options, let numericOptions, let operand):
            return parseSimple(
                name: name,
                executable: executable,
                options: options,
                numericOptions: numericOptions,
                operand: readsStdin ? operand.allowingStdin : operand,
                arguments: arguments
            )
        case .git:
            return parseGit(executable: executable, arguments: arguments)
        case .find:
            return parseFind(executable: executable, arguments: arguments)
        case .sedLines:
            guard arguments.count == 3, arguments[0] == "-n",
                  arguments[1].range(of: #"\A[1-9][0-9]{0,8}(,[1-9][0-9]{0,8})?p\z"#, options: .regularExpression) != nil,
                  !arguments[2].isEmpty, !arguments[2].hasPrefix("-") else { return nil }
            return Self(executable: executable, arguments: arguments, paths: [arguments[2]])
        case .grep(_, let options):
            return parseGrep(
                executable: executable, options: options, arguments: arguments,
                stdinAvailable: stdinAvailable
            )
        case .ripgrep:
            return parseRipgrep(executable: executable, arguments: arguments, stdinAvailable: stdinAvailable)
        }
    }

    private static func parseSimple(name: String, executable: String, options: String, numericOptions: [Character: ClosedRange<Int>], operand: OperandRule, arguments: [String]) -> Self? {
        var paths: [String] = []
        var operandCount = 0
        var operands = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if !operands, arg == "--" { operands = true; continue }
            if !operands, arg.hasPrefix("-") {
                // 独立数字参数选项：head/tail `-n 10`、shasum `-a 256`
                if arg.count == 2, let letter = arg.dropFirst().first, let range = numericOptions[letter] {
                    guard index < arguments.count, let value = Int(arguments[index]), range.contains(value) else { return nil }
                    index += 1
                    continue
                }
                // BSD 计数简写 `-5`（仅 head/tail）：等价于 `-n 5`
                if bareCountPrograms.contains(name), arg.count > 1,
                   arg.dropFirst().allSatisfy({ $0.isNumber }),
                   let count = Int(arg.dropFirst()), (0...100_000).contains(count) {
                    continue
                }
                guard arg.count > 1, !arg.hasPrefix("--"),
                      arg.dropFirst().allSatisfy({ options.contains($0) }) else { return nil }
            } else {
                operandCount += 1
                switch operand {
                case .none:
                    return nil
                case .ignored, .any:
                    continue
                case .paths:
                    guard !arg.isEmpty, arg != "-" else { return nil }
                    paths.append(arg)
                case .plusFormat:
                    guard operandCount == 1, arg.hasPrefix("+") else { return nil }
                }
            }
        }
        if case .paths(let required) = operand, required, paths.isEmpty { return nil }
        return Self(executable: executable, arguments: arguments, paths: paths)
    }

    /// git 只读子命令。硬化依据：只读子命令仍可能执行仓库配置里的外部程序——
    /// pager、status 的 fsmonitor hook、diff 路径的 external driver 与 attributes textconv 驱动。
    /// 执行侧以 `-c core.pager=cat -c core.fsmonitor=false` 注入 argv 前、diff 族追加
    /// `--no-ext-diff --no-textconv`，并注入 GIT_CONFIG_NOSYSTEM / GIT_CEILING_DIRECTORIES /
    /// GIT_TERMINAL_PROMPT 环境变量（见 DispatcherTools.execute 快速通道）。
    /// 操作数不做路径校验：git 自身只访问仓库对象与工作树文件，仓库发现范围被 ceiling 限定。
    private static func parseGit(executable: String, arguments: [String]) -> Self? {
        // 子命令不得以 `-` 开头——天然拒绝 git -C dir、git -c k=v、git --git-dir=… 全局选项形态
        guard let sub = arguments.first, !sub.hasPrefix("-") else { return nil }
        var rule: GitSubcommandRule
        var rest: [String]
        if sub == "reflog", arguments.count >= 2, arguments[1] == "show" {
            rule = GitSubcommandRule(options: "0123456789", maxOperands: 1)
            rest = Array(arguments.dropFirst(2))
        } else if sub == "stash" {
            // 仅 list / show 两种形态，mode 后不带操作数
            guard arguments.count >= 2 else { return nil }
            let mode = arguments[1]
            guard mode == "list" || mode == "show" else { return nil }
            rule = mode == "show"
                ? GitSubcommandRule(options: "pu0123456789", maxOperands: 0, diffCapable: true)
                : GitSubcommandRule(maxOperands: 0)
            rest = Array(arguments.dropFirst(2))
        } else {
            guard let found = gitSubcommands[sub] else { return nil }
            rule = found
            rest = Array(arguments.dropFirst())
        }
        // 只扩展显示选项；--output、外部 diff、配置入口与未知长选项仍不放行。
        let displayOptions: Set<String> = ["--stat", "--numstat", "--shortstat", "--name-only", "--name-status", "--no-color"]
        let longOptions: Set<String>
        switch sub {
        case "status": longOptions = ["--short", "--branch", "--porcelain"]
        case "diff": longOptions = displayOptions.union(["--cached", "--staged", "--check", "--no-ext-diff", "--no-textconv"])
        case "log", "show": longOptions = displayOptions.union(["--oneline", "--no-decorate", "--no-ext-diff", "--no-textconv"])
        default: longOptions = []
        }
        var hasOptions = false
        var operandCount = 0
        var readingPaths = false
        var paths: [String] = []
        for arg in rest {
            if readingPaths { paths.append(arg); continue }
            if arg == "--" {
                guard rule.diffCapable else { return nil }
                readingPaths = true
                continue
            }
            if longOptions.contains(arg) {
                hasOptions = true
                continue
            }
            if arg.hasPrefix("-") {
                guard arg.count > 1, !arg.hasPrefix("--"),
                      arg.dropFirst().allSatisfy({ rule.options.contains($0) }) else { return nil }
                hasOptions = true
            } else {
                operandCount += 1
            }
        }
        guard operandCount >= rule.minOperands, operandCount <= rule.maxOperands else { return nil }
        // config 双形态：-l 带操作数即拒
        if sub == "config", hasOptions, operandCount > 0 { return nil }
        var hardenedArguments = arguments
        var suffix = rule.diffCapable ? ["--no-ext-diff", "--no-textconv"] : []
        if let separator = hardenedArguments.firstIndex(of: "--") {
            // 分隔符后的参数都是路径；安全选项必须在分隔符之前生效。
            hardenedArguments.insert(contentsOf: suffix, at: separator)
            suffix = []
        }
        return Self(
            executable: executable,
            arguments: hardenedArguments,
            paths: paths,
            injectedPrefix: ["-c", "core.pager=cat", "-c", "core.fsmonitor=false"],
            injectedSuffix: suffix,
            needsRepositoryCeiling: true
        )
    }

    private static func parseFind(executable: String, arguments: [String]) -> Self? {
        var paths: [String] = []
        var index = 0
        // 前导全局选项（-H/-L/-P 组合）。`-L` 会让 find 跟随目录内符号链接，
        // 起始路径校验无法阻止它读取外部目标，因此只读快速通道拒绝 -L。
        while index < arguments.count {
            let arg = arguments[index]
            guard arg.hasPrefix("-"), arg.count > 1, !arg.hasPrefix("--"),
                  arg.dropFirst().allSatisfy({ "HLP".contains($0) }) else { break }
            if arg.contains("L") { return nil }
            index += 1
        }
        // 起始路径：至少一个，全部校验
        while index < arguments.count, !arguments[index].hasPrefix("-") {
            paths.append(arguments[index])
            index += 1
        }
        guard !paths.isEmpty else { return nil }
        // 谓词流逐 token 解析；白名单外一律拒
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if findOneArgPredicates.contains(token) {
                guard index < arguments.count else { return nil }
                let parameter = arguments[index]
                index += 1
                if token == "-newer" { paths.append(parameter) }
            } else if findNoArgPredicates.contains(token) {
                continue
            } else {
                return nil
            }
        }
        return Self(executable: executable, arguments: arguments, paths: paths)
    }

    private static func parseGrep(
        executable: String, options: String, arguments: [String], stdinAvailable: Bool
    ) -> Self? {
        var flags: [String] = []
        var operands: [String] = []
        var optionsEnded = false
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            if !optionsEnded, arg == "--" {
                optionsEnded = true
            } else if !optionsEnded, arg == "--include" {
                guard let glob = iterator.next(), !glob.isEmpty else { return nil }
                flags.append("--include=" + glob)
            } else if !optionsEnded, arg.hasPrefix("--include=") {
                guard arg != "--include=" else { return nil }
                flags.append(arg)
            } else if !optionsEnded, arg.hasPrefix("-") {
                guard arg.count > 1, arg.dropFirst().allSatisfy({ options.contains($0) }) else { return nil }
                flags.append(arg)
            } else {
                operands.append(arg)
            }
        }
        let paths = Array(operands.dropFirst())
        guard !operands.isEmpty, stdinAvailable || !paths.isEmpty,
              paths.allSatisfy({ !$0.isEmpty && $0 != "-" }) else { return nil }
        // BSD grep -p skips symlinks during recursion. Keep glob/regexp as data and
        // terminate option parsing before passing the exact pattern and checked paths.
        return Self(executable: executable, arguments: flags + ["--"] + operands,
                    paths: paths, injectedPrefix: ["-p"])
    }

    /// 查询模式和文件枚举共用路径校验；glob/type/regexp 是字面数据，不是文件入口。
    /// 配置文件、预处理器、解压器和跟随链接均不在白名单中。
    static func parseRipgrep(executable: String, arguments: [String], stdinAvailable: Bool = false) -> Self? {
        let flags: Set<String> = ["--files", "--hidden", "--line-number", "--no-heading", "--with-filename",
            "--files-with-matches", "--files-without-match", "--only-matching", "--fixed-strings",
            "--ignore-case", "--case-sensitive", "--smart-case", "--word-regexp", "--count",
            "--count-matches", "--quiet", "--null", "--no-config"]
        let values: Set<String> = ["--glob", "--iglob", "--type", "--type-not", "--regexp", "--max-count",
            "--after-context", "--before-context", "--context", "--max-depth"]
        let numeric: Set<String> = ["--max-count", "--after-context", "--before-context", "--context", "--max-depth", "m", "A", "B", "C"]
        let shortValues: Set<Character> = ["g", "t", "T", "e", "m", "A", "B", "C"]
        var positionals: [String] = []
        var operandsOnly = false
        var files = false
        var explicitPattern = false
        var index = 0
        func validValue(_ value: String, option: String) -> Bool {
            if numeric.contains(option) { return Int(value).map { (0...100_000).contains($0) } ?? false }
            return option == "--regexp" || option == "e" || !value.isEmpty
        }
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if !operandsOnly, arg == "--" { operandsOnly = true; continue }
            if !operandsOnly, arg.hasPrefix("--") {
                if flags.contains(arg) { files = files || arg == "--files"; continue }
                let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let option = parts[0]
                guard values.contains(option) else { return nil }
                let value: String
                if parts.count == 2 { value = parts[1] }
                else { guard index < arguments.count else { return nil }; value = arguments[index]; index += 1 }
                guard validValue(value, option: option) else { return nil }
                explicitPattern = explicitPattern || option == "--regexp"
            } else if !operandsOnly, arg.hasPrefix("-") {
                guard arg.count > 1 else { return nil }
                var letters = arg.dropFirst()[...]
                while let letter = letters.first {
                    letters = letters.dropFirst()
                    if shortValues.contains(letter) {
                        let value: String
                        if !letters.isEmpty { value = String(letters) }
                        else { guard index < arguments.count else { return nil }; value = arguments[index]; index += 1 }
                        guard validValue(value, option: String(letter)) else { return nil }
                        explicitPattern = explicitPattern || letter == "e"
                        break
                    }
                    guard "invclowFqxhHsS0".contains(letter) else { return nil }
                }
            } else { positionals.append(arg) }
        }
        if files { guard !explicitPattern else { return nil } }
        else if !explicitPattern {
            guard !positionals.isEmpty else { return nil }
            positionals.removeFirst() // 查询模式的首个操作数是 pattern。
        }
        guard positionals.allSatisfy({ !$0.isEmpty && $0 != "-" }) else { return nil }
        let defaultPath = positionals.isEmpty && (files || !stdinAvailable)
        return Self(executable: executable, arguments: arguments, paths: defaultPath ? ["."] : positionals,
            injectedPrefix: ["--no-config"], injectedSuffix: defaultPath ? ["."] : [])
    }

    private static func words(_ script: String) -> [String]? {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var started = false
        for character in script {
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { result.append(token); token = ""; started = false }
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil else { return nil }
        if started { result.append(token) }
        return result.isEmpty ? nil : result
    }

    // MARK: 只读复合脚本（连接符 / 管道 / 工作区内 cd / 白名单重定向）

    private enum Separator: Sendable {
        case sequence, and, or, pipe
    }

    private struct ScriptSegment: Sendable {
        var words: [String] = []
        /// 该段上的重定向数量（目标已逐个校验；cd 不允许带重定向）
        var redirects = 0
        /// 该段带 `< /dev/null`：标准输入已确定为空流
        var stdinFromNull = false
    }

    private struct LexedScript: Sendable {
        var segments: [ScriptSegment] = []
        /// separators[i] 是 segments[i] 之后的分隔符
        var separators: [Separator] = []
    }

    /// 解析只读复合脚本：一条或多条白名单只读命令，以换行 / `;` / `&&` / `||` / `|` 连接，
    /// 可带 `cd <工作区内目录> &&` 前缀，以及只写入 /dev/null、/dev/stdout、/dev/stderr 的重定向。
    ///
    /// 只在整段脚本能被完全确定解释时返回非 nil：写文件重定向、变量、命令替换、通配、
    /// 后台执行、工作区外路径等任何未知或歧义写法都返回 nil（转人工）。
    /// git 只读子命令不参与复合形态——它们的免确认依赖执行侧注入硬化参数，
    /// 复合脚本经 zsh 执行拿不到这层注入，因此一律不给资格。
    static func parseScript(_ script: String, workspaceRoot: URL, initialDirectory: URL) -> ShellReadOnlyScript? {
        let script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, script.count <= 8192,
              !script.contains(where: { character in
                  if scriptForbiddenCharacters.contains(character) { return true }
                  guard character.isASCII, let value = character.asciiValue else { return false }
                  return value < 32 && character != "\t" && character != "\n"
              }),
              let lexed = lex(script) else { return nil }

        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var directory = initialDirectory.standardizedFileURL.resolvingSymlinksInPath()
        // 起始目录本身也必须在工作区内：否则相对路径的核对基准不可信
        guard FileAreaService.isInside(directory, root: root) else { return nil }

        var steps: [ShellReadOnlyScript.Step] = []
        for (index, segment) in lexed.segments.enumerated() {
            let separatorBefore = index > 0 ? lexed.separators[index - 1] : nil
            let separatorAfter = index < lexed.separators.count ? lexed.separators[index] : nil
            guard !segment.words.isEmpty else { continue }   // 尾随分行符 / 连续分隔符
            let first = segment.words[0]
            // 必须是内建 cd 本身：`./cd`、`/tmp/cd` 是工作区里的可执行文件，按字面当成 cd
            // 会把任意程序当成换目录放行
            if first == "cd" {
                // 只允许 `cd <工作区内目录> &&`（或脚本末尾）：&& 失败即不执行后续命令，
                // 目录跟踪才是确定的。`;`/换行/`||` 之后 cd 可能没有生效，不能按新目录核对路径；
                // 管道里的 cd 在子 shell 执行，同样不可能影响后续命令
                guard segment.redirects == 0, segment.words.count == 2,
                      separatorBefore != .or, separatorBefore != .pipe,
                      separatorAfter == nil || separatorAfter == .and else { return nil }
                let raw = segment.words[1]
                guard !raw.hasPrefix("-"), !raw.hasPrefix("=") else { return nil }
                let target = raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw)
                    : directory.appendingPathComponent(raw)
                let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
                guard FileAreaService.isInside(resolved, root: root) else { return nil }
                directory = resolved
                continue
            }
            let stdinAvailable = separatorBefore == .pipe || segment.stdinFromNull
            guard let command = parseCommand(words: segment.words, stdinAvailable: stdinAvailable),
                  !command.needsRepositoryCeiling,
                  command.isInside(workspace: root, directory: directory) else { return nil }
            steps.append(ShellReadOnlyScript.Step(command: command, directory: directory.path))
        }
        guard !steps.isEmpty else { return nil }
        return ShellReadOnlyScript(steps: steps)
    }

    /// 词法分析：只识别白名单语法，遇到任何未知结构返回 nil。
    /// 支持引号内的字面量（引号本身剥离），不解释任何展开。
    private static func lex(_ script: String) -> LexedScript? {
        let characters = Array(script)
        var lexed = LexedScript()
        var segment = ScriptSegment()
        var word = ""
        var wordStarted = false
        var wordQuoted = false
        var quote: Character?
        var index = 0

        func flushWord() {
            guard wordStarted else { return }
            segment.words.append(word)
            word = ""
            wordStarted = false
            wordQuoted = false
        }

        func flushSegment() {
            flushWord()
            lexed.segments.append(segment)
            segment = ScriptSegment()
        }

        func appendSeparator(_ separator: Separator) {
            flushSegment()
            lexed.separators.append(separator)
        }

        /// 解析一个重定向操作符（`>`、`>>`、`<`、`2>&1` 形态）。
        /// 只接受无副作用目标：写 /dev/null、/dev/stdout、/dev/stderr，读 /dev/null。
        func lexRedirect(at start: Int) -> (next: Int, stdinFromNull: Bool)? {
            let operatorCharacter = characters[start]
            // 紧贴操作符的未加引号单数字词是 fd 前缀（`2>`）；多位数形态语义不确定，直接拒绝
            var fd = operatorCharacter == "<" ? 0 : 1
            if wordStarted, !wordQuoted, !word.isEmpty, word.allSatisfy({ $0.isNumber }) {
                guard word.count == 1, let value = Int(word) else { return nil }
                fd = value
                word = ""
                wordStarted = false
            } else {
                // 重定向前面的普通词仍然是命令参数（`ls -la 2>/dev/null`）
                flushWord()
            }
            var cursor = start + 1
            var isAppend = false
            if operatorCharacter == ">", cursor < characters.count, characters[cursor] == ">" {
                isAppend = true
                cursor += 1
            }
            guard cursor < characters.count else { return nil }
            if characters[cursor] == "&" {
                // fd 复制（`2>&1`）：只允许 stdout/stderr 之间互换
                guard operatorCharacter == ">", !isAppend, fd == 1 || fd == 2 else { return nil }
                cursor += 1
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                guard let targetFD = Int(digits), targetFD == 1 || targetFD == 2 else { return nil }
                guard cursor == characters.count || !Self.isWordCharacter(characters[cursor]) else { return nil }
                return (cursor, false)
            }
            while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
                cursor += 1
            }
            guard cursor < characters.count,
                  let target = Self.readRedirectTarget(characters, from: cursor),
                  Self.isSafeRedirect(target.word, writing: operatorCharacter == ">", appending: isAppend, fd: fd) else {
                return nil
            }
            return (target.next, !isAppend && operatorCharacter == "<")
        }

        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
                index += 1
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                wordStarted = true
                wordQuoted = true
                index += 1
            case " ", "\t":
                flushWord()
                index += 1
            case "\n", ";":
                appendSeparator(.sequence)
                index += 1
            case "&":
                // 只支持 `&&`；单独 `&` 是后台执行，不能自动放行
                guard index + 1 < characters.count, characters[index + 1] == "&" else { return nil }
                appendSeparator(.and)
                index += 2
            case "|":
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    appendSeparator(.or)
                    index += 2
                } else {
                    appendSeparator(.pipe)
                    index += 1
                }
            case ">", "<":
                guard let redirect = lexRedirect(at: index) else { return nil }
                segment.redirects += 1
                if redirect.stdinFromNull { segment.stdinFromNull = true }
                index = redirect.next
            default:
                word.append(character)
                wordStarted = true
                index += 1
            }
        }
        guard quote == nil else { return nil }
        flushSegment()
        return lexed
    }

    /// 读重定向目标：引号内按字面量，遇到空白或语法操作符结束
    private static func readRedirectTarget(_ characters: [Character], from start: Int) -> (word: String, next: Int)? {
        var word = ""
        var quote: Character?
        var index = start
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index += 1
                continue
            }
            guard isWordCharacter(character) else { break }
            word.append(character)
            index += 1
        }
        guard quote == nil, !word.isEmpty else { return nil }
        return (word, index)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        switch character {
        case " ", "\t", "\n", ";", "&", "|", "<", ">": return false
        default: return true
        }
    }

    /// 重定向目标白名单：写只允许丢弃/回显，读只允许 /dev/null。
    /// 写文件、写裸设备（/dev/disk0）都必须人工确认
    private static func isSafeRedirect(_ target: String, writing: Bool, appending: Bool, fd: Int) -> Bool {
        if writing {
            guard fd == 1 || fd == 2 else { return false }
            return target == "/dev/null" || target == "/dev/stdout" || target == "/dev/stderr"
        }
        guard fd == 0, !appending else { return false }
        return target == "/dev/null"
    }
}

// MARK: - Git Repository Inspector

/// 快速通道执行 git 前检查实际仓库位置：`.git` 目录可以是普通仓库；
/// `.git` 文件（linked worktree / submodule / gitdir 重定向）必须指向工作区内，
/// 且其 `commondir` 也不能逃逸。没有 `.git` 时仍允许快速通道——执行侧注入
/// GIT_CEILING_DIRECTORIES，外层仓库不会被发现。
enum GitRepositoryInspector {
    static func isConfined(directory: URL, workspace: URL) -> Bool {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        guard FileAreaService.isInside(directory, root: root) else { return false }
        var current = directory.standardizedFileURL.resolvingSymlinksInPath()
        while FileAreaService.isInside(current, root: root) {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let resolved = dotGit.standardizedFileURL.resolvingSymlinksInPath()
                guard FileAreaService.isInside(resolved, root: root) else { return false }
                if isDirectory.boolValue { return true }
                guard let text = try? String(contentsOf: resolved, encoding: .utf8) else {
                    return false
                }
                let prefix = "gitdir:"
                guard let line = text.split(whereSeparator: \.isNewline)
                    .first(where: { $0.hasPrefix(prefix) }) else { return false }
                let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                let target = raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw)
                    : current.appendingPathComponent(raw)
                let gitDir = target.standardizedFileURL.resolvingSymlinksInPath()
                guard FileAreaService.isInside(gitDir, root: root) else { return false }
                // linked worktree 的对象库在 commondir；它也必须留在工作区内。
                let common = gitDir.appendingPathComponent("commondir")
                if let commonText = try? String(contentsOf: common, encoding: .utf8) {
                    let commonRaw = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !commonRaw.isEmpty else { return false }
                    let commonURL = commonRaw.hasPrefix("/")
                        ? URL(fileURLWithPath: commonRaw)
                        : gitDir.appendingPathComponent(commonRaw)
                    return FileAreaService.isInside(
                        commonURL.standardizedFileURL.resolvingSymlinksInPath(),
                        root: root
                    )
                }
                return true
            }
            guard current.path != root.path else { break }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return true
    }
}

/// 只读复合脚本：每一步记录执行时的绝对工作目录。
/// 仅当整段脚本能被完全确定解释时才存在——未知写法一律解析失败（转人工）。
struct ShellReadOnlyScript: Sendable {
    struct Step: Sendable {
        let command: ShellReadOnlyCommand
        /// 该命令执行时的工作目录（`cd` 链解析后的绝对路径）
        let directory: String
    }

    let steps: [Step]

    /// 每一步的工作目录与路径操作数都必须落在会话工作区内
    func isInside(workspace: URL) -> Bool {
        steps.allSatisfy {
            $0.command.isInside(workspace: workspace, directory: URL(fileURLWithPath: $0.directory))
        }
    }
}

// MARK: - Approval Route（审批路由）

/// 工具按实际参数声明的审批路由，默认「仅人工」。
///
/// 路由只说明“谁有资格批准”，不说明“模式是否允许”：
/// - `.manualOnly`：只能由用户批准，自动审核不能翻盘；
/// - `.deterministic`：可由确定性规则直接批准；
/// - `.modelReviewable`：规则不能直接批准时，可交给无工具的审核模型判断。
public enum ApprovalRoute: String, Codable, Sendable, Equatable {
    case manualOnly
    case deterministic
    case modelReviewable
}

/// 确定性规则结果。`.needsModelReview` 只对 `.modelReviewable` 生效；
/// 对 `.deterministic` 路由，它等价于转人工，绝不能顺便调用模型。
public enum AutoReviewRuleResult: Sendable, Equatable {
    case approve(reason: String)
    case needsModelReview(reason: String)
    case manual(reason: String)
    case reject(reason: String)
}

/// 确定性规则自动批准事件：只用于审计，不改变执行结果。
public struct AutomaticApprovalEvent: Sendable, Equatable {
    public let callId: String
    public let toolName: String
    public let reason: String
    public let route: ApprovalRoute
    public let taskID: String?
    public let taskScopeDigest: String?
    public let callDigest: String?

    public init(
        callId: String,
        toolName: String,
        reason: String,
        route: ApprovalRoute,
        taskID: String?,
        taskScopeDigest: String?,
        callDigest: String?
    ) {
        self.callId = callId
        self.toolName = toolName
        self.reason = reason
        self.route = route
        self.taskID = taskID
        self.taskScopeDigest = taskScopeDigest
        self.callDigest = callDigest
    }
}

// MARK: - Auto Review Decision（审核结论）

/// 自动审核结论：放行 / 转人工 / 明确拒绝。
/// reason 是稳定标识（非本地化文案），供审核记录与 UI 本地化展示使用。
public enum AutoReviewDecision: Sendable, Equatable {
    /// 自动放行：交给引擎复核队首后按确认流执行
    case approve(reason: String)
    /// 转人工：保留原确认卡与完整参数，等用户决定
    case manual(reason: String)
    /// 明确违反规则：写回对应 toolResult（模型据此改用其他方式）
    case reject(reason: String)
}

public struct AutoReviewEvaluation: Sendable {
    public let request: AutoReviewRequest
    public let decision: AutoReviewDecision

    public init(request: AutoReviewRequest, decision: AutoReviewDecision) {
        self.request = request
        self.decision = decision
    }

    public func annotating(_ outcome: DispatcherOutcome) -> DispatcherOutcome {
        guard case .manual(let reason) = decision,
              case .needsConfirmation(let name, let arguments, let preview, let requirement) = outcome else {
            return outcome
        }
        return .needsConfirmation(toolName: name, argumentsDisplay: arguments, changePreview: preview,
                                  requirement: requirement.withAutoReviewReason(reason))
    }
}

// MARK: - Auto Review Request（审核请求）

/// 引擎按队首待确认调用生成的审核请求：携带调用 ID、真实参数、
/// 确认类型（普通/硬）、工具副作用类别与自动审核资格。
public struct AutoReviewRequest: Sendable, Equatable {
    /// 待确认调用的 toolCallId（自动放行提交时引擎据此复核队首）
    public let callId: String
    public let toolName: String
    /// 真实（原始）参数 JSON——审核依据，非展示文本
    public let argumentsJSON: String
    /// 确认需求：含类型/范围/硬确认原因
    public let requirement: ConfirmationRequirement
    /// 工具声明的审批路由
    public let route: ApprovalRoute
    /// 工具副作用分类（供审核记录；不作为放行的唯一依据）
    public let sideEffectClass: ToolSideEffectClass
    /// 本次任务的执行范围。没有范围时不能自动批准文件写或代码执行。
    public let taskScope: TaskExecutionScope?
    /// 宿主从真实文件/环境读取的审核证据（脚本正文、依赖摘要、执行档等）。
    /// 执行 Agent 自述不能填入这里。
    public let evidence: [String: String]
    /// 绑定本次调用的摘要；模型输出必须回显同一摘要。
    public let callDigest: String
    /// Resolved write targets declared by the installed tool, never by the reviewer.
    public let writeTargets: [String]
    public let readTargets: [String]
    public let authorizationGeneration: UInt64

    public init(
        callId: String,
        toolName: String,
        argumentsJSON: String,
        requirement: ConfirmationRequirement,
        route: ApprovalRoute,
        sideEffectClass: ToolSideEffectClass,
        taskScope: TaskExecutionScope? = nil,
        evidence: [String: String] = [:],
        writeTargets: [String] = [],
        readTargets: [String] = [],
        callDigest: String? = nil,
        authorizationGeneration: UInt64 = 0
    ) {
        self.callId = callId
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.requirement = requirement
        self.route = route
        self.sideEffectClass = sideEffectClass
        self.taskScope = taskScope
        self.evidence = evidence
        self.writeTargets = writeTargets
        self.readTargets = readTargets
        self.authorizationGeneration = authorizationGeneration
        self.callDigest = callDigest ?? AutoReviewDigest.make(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            taskScope: taskScope,
            policyVersion: AutoReviewService.ruleVersion,
            evidence: evidence,
            authorizationGeneration: authorizationGeneration
        )
    }

    /// 原始用户请求（有界）；没有任务范围时为空。
    public var userRequest: String { taskScope?.userRequest ?? "" }
}

/// 审核调用摘要：参数、任务范围和策略版本任一项变化都会产生新摘要。
public enum AutoReviewDigest {
    public static func make(
        toolName: String,
        argumentsJSON: String,
        taskScope: TaskExecutionScope?,
        policyVersion: String,
        evidence: [String: String] = [:],
        authorizationGeneration: UInt64 = 0
    ) -> String {
        struct Identity: Encodable {
            let tool: String
            let arguments: String
            let scope: String
            let policyVersion: String
            let evidence: [String: String]
            let authorizationGeneration: UInt64
        }
        let identity = Identity(
            tool: toolName,
            arguments: argumentsJSON,
            scope: taskScope?.digest ?? "none",
            policyVersion: policyVersion,
            evidence: evidence,
            authorizationGeneration: authorizationGeneration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Auto Review Environment（审核环境）

/// 审核上下文的空间与工作区：规则据此核对调用是否落在会话写范围内
public struct AutoReviewEnvironment: Sendable {
    public let space: AppSpace
    /// 会话工作区绝对路径（空 = 未选定，规则无法核对 → 转人工）
    public let workspacePath: String

    public init(space: AppSpace, workspacePath: String) {
        self.space = space
        self.workspacePath = workspacePath
    }
}

// MARK: - Auto Review Reviewer（可选的模型复核）

/// 可选的模型复核：只出建议，不能覆盖硬确认或规则拒绝。
/// 返回 nil（解析失败/服务不可用）时上层转人工
public protocol AutoReviewReviewer: Sendable {
    func reviewCandidate(
        _ request: AutoReviewRequest,
        environment: AutoReviewEnvironment
    ) async -> AutoReviewDecision?
}

// MARK: - Auto Review Service（规则 + 可选模型）

/// 自动审核服务：先运行确定性规则；规则明确要求模型审核时，才调用无工具的审核模型。
/// 硬确认、模式拒绝、任务范围失效和规则拒绝都不能被模型翻盘。
/// 超时、取消、解析失败或服务不可用一律转人工。
public struct AutoReviewService: Sendable {

    /// 规则版本：写进审核记录，规则变更后可追溯。
    public static let ruleVersion = "auto-review/v11"

    /// 模型审核兜底超时（默认 20 秒；到期转人工）。
    public static let defaultTimeout: Duration = .seconds(20)

    /// 纵深防御：即使工具误声明路由，这些工具也永不自动放行。
    static let neverAutoApproveTools: Set<String> = [
        "project_build",
        "mail_send", "mail_delete", "mail_mark",
        "browser_fill", "browser_evaluate",
        "skill_export_zip"
    ]

    /// 需要按会话工作区核对写入目标的低风险文件写入工具。
    static let scopedWriteTools: Set<String> = [
        "files_write", "files_mkdir", "file_write", "files_edit", "files_apply_changes",
        "files_copy", "files_move", "files_rename", "files_delete"
    ]

    private let reviewer: (any AutoReviewReviewer)?
    private let timeout: Duration
    private let cache: AutoReviewDecisionCache

    public init(
        reviewer: (any AutoReviewReviewer)? = nil,
        timeout: Duration = Self.defaultTimeout,
        cache: AutoReviewDecisionCache = AutoReviewDecisionCache()
    ) {
        self.reviewer = reviewer
        self.timeout = timeout
        self.cache = cache
    }

    /// 审核一次待确认调用。
    public func review(
        _ request: AutoReviewRequest,
        environment: AutoReviewEnvironment
    ) async -> AutoReviewDecision {
        switch Self.ruleResult(request, environment: environment) {
        case .approve(let reason):
            return .approve(reason: reason)
        case .reject(let reason):
            return .reject(reason: reason)
        case .manual(let reason):
            return .manual(reason: reason)
        case .needsModelReview(let reason):
            guard request.route == .modelReviewable else {
                return .manual(reason: "model_review_disallowed")
            }
            guard let reviewer else { return .manual(reason: "review_unavailable") }
            if let cached = await cache.decision(for: request.callDigest) {
                return cached
            }
            let modelDecision = await Self.withTimeout(timeout) {
                await reviewer.reviewCandidate(request, environment: environment)
            }
            guard let modelDecision else { return .manual(reason: "review_unavailable") }
            switch modelDecision {
            case .approve(let modelReason):
                let decision = AutoReviewDecision.approve(reason: modelReason.isEmpty ? reason : modelReason)
                await cache.store(decision, for: request.callDigest)
                return decision
            case .manual(let modelReason):
                return .manual(reason: modelReason)
            case .reject(let modelReason):
                let decision = AutoReviewDecision.reject(reason: modelReason)
                await cache.store(decision, for: request.callDigest)
                return decision
            }
        }
    }

    // MARK: - Deterministic Rules（纯函数，可测）

    /// 兼容旧测试/调用方的布尔化入口：把“需要模型审核”视为人工，
    /// 生产路径必须使用 `ruleResult`，否则会丢失模型审核。
    static func ruleDecision(
        _ request: AutoReviewRequest,
        environment: AutoReviewEnvironment
    ) -> AutoReviewDecision {
        switch ruleResult(request, environment: environment) {
        case .approve(let reason): return .approve(reason: reason)
        case .reject(let reason): return .reject(reason: reason)
        case .manual(let reason): return .manual(reason: reason)
        case .needsModelReview(let reason): return .manual(reason: reason)
        }
    }

    /// 确定性规则：
    /// 1) 硬确认永不自动放行；
    /// 2) 路由为仅人工 → 人工；
    /// 3) 低风险文件写/严格只读 Shell → 规则直接批准；
    /// 4) 离线 Python/技能脚本 → 只返回“需要模型审核”，不直接放行；
    /// 5) 任务范围缺失、过期、目录身份变化或能力不足 → 人工。
    static func ruleResult(
        _ request: AutoReviewRequest,
        environment: AutoReviewEnvironment
    ) -> AutoReviewRuleResult {
        if request.requirement.kind == .hard {
            return .manual(reason: manualReason(for: request))
        }
        if neverAutoApproveTools.contains(request.toolName) {
            return .manual(reason: "denylisted_tool")
        }
        switch request.route {
        case .manualOnly:
            return .manual(reason: request.requirement.autoReviewReason ?? manualReason(for: request.toolName))
        case .deterministic:
            if scopedWriteTools.contains(request.toolName) {
                return scopedWriteDecision(request, environment: environment)
            }
            if request.toolName == "shell_run" {
                return map(shellReadDecision(request, environment: environment))
            }
            return .manual(reason: "not_eligible")
        case .modelReviewable:
            return modelReviewRule(request, environment: environment)
        }
    }

    private static func modelReviewRule(
        _ request: AutoReviewRequest,
        environment: AutoReviewEnvironment
    ) -> AutoReviewRuleResult {
        guard let scope = request.taskScope else {
            return .manual(reason: "task_scope_unavailable")
        }
        guard scope.autoReviewEnabled else { return .manual(reason: "auto_review_disabled") }
        guard scope.isActive() else { return .manual(reason: "task_scope_inactive") }
        guard request.userRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .manual(reason: "user_request_unavailable")
        }
        if request.toolName.hasPrefix("mcp_") {
            return MCPQueryReviewPolicy.reviewRule(request, environment: environment)
        }
        if request.toolName == "browser_click" {
            guard environment.space == scope.space,
                  scope.permissionMode != .readOnly,
                  request.evidence["space"] == scope.space.rawValue,
                  request.evidence["execution_profile"] == "browser_structured",
                  request.evidence["browser_policy"] == "structured/v1",
                  ["browser_navigation", "browser_query", "browser_control"].contains(request.evidence["operation"] ?? ""),
                  request.evidence["execution_identity"]?.isEmpty == false else {
                return .manual(reason: "browser_unverified")
            }
            guard request.evidence["origin"]?.hasPrefix("https://") == true else {
                return .manual(reason: "browser_https_required")
            }
            if request.evidence["evidence_truncated"] == "true" {
                return .manual(reason: "browser_evidence_truncated")
            }
            guard request.evidence["evidence_truncated"] == "false" else {
                return .manual(reason: "browser_unverified")
            }
            guard request.evidence.values.reduce(0, { $0 + $1.utf8.count }) <= 24 * 1024 else {
                return .manual(reason: "browser_evidence_too_large")
            }
            return .needsModelReview(reason: "browser_structured")
        }
        guard scope.allows(.confinedCodeExecution) else {
            return .manual(reason: "task_code_prohibited")
        }
        switch request.toolName {
        case "python_execute":
            guard request.evidence["execution_profile"] == "offline_artifacts",
                  request.evidence["network"] == "false",
                  request.evidence["child_processes"] == "false",
                  request.evidence["executor_verified"] == "true" else {
                return .manual(reason: "unverified_executor")
            }
            guard let code = request.evidence["code"], !code.isEmpty,
                  code.utf8.count <= 32 * 1024,
                  request.evidence["evidence_truncated"] != "true" else {
                return .manual(reason: "evidence_unavailable")
            }
            return .needsModelReview(reason: "offline_python")
        case "skill_run_script":
            guard request.evidence["execution_profile"] == "skill_snapshot",
                  request.evidence["network"] == "false",
                  request.evidence["child_processes"] == "false",
                  request.evidence["executor_verified"] == "true" else {
                return .manual(reason: "unverified_executor")
            }
            guard let digest = request.evidence["package_digest"], !digest.isEmpty,
                  let script = request.evidence["script_text"], !script.isEmpty,
                  request.evidence["evidence_truncated"] != "true" else {
                return .manual(reason: "evidence_unavailable")
            }
            return .needsModelReview(reason: "skill_script")
        default:
            return .manual(reason: "not_eligible")
        }
    }

    private static func map(_ decision: AutoReviewDecision) -> AutoReviewRuleResult {
        switch decision {
        case .approve(let reason): return .approve(reason: reason)
        case .manual(let reason): return .manual(reason: reason)
        case .reject(let reason): return .reject(reason: reason)
        }
    }

    public static func manualReason(for request: AutoReviewRequest) -> String {
        if let reason = request.requirement.autoReviewReason { return reason }
        if request.requirement.kind == .hard {
            switch request.requirement.hardReason {
            case .hostExecution: return "host_execution"
            case .directoryWrite: return "directory_write"
            case .highRiskCommand: return "high_risk_command"
            case .irreversible: return "irreversible"
            default: return "hard_confirmation"
            }
        }
        if ["files_edit", "files_apply_changes"].contains(request.toolName), request.evidence["recovery_store"] == "false" {
            return "recovery_unavailable"
        }
        if request.route == .deterministic, scopedWriteTools.contains(request.toolName) {
            guard let scope = request.taskScope else { return "task_scope_unavailable" }
            let environment = AutoReviewEnvironment(space: scope.space, workspacePath: scope.workspacePath)
            switch scopedWriteDecision(request, environment: environment) {
            case .manual(let reason), .reject(let reason): return reason
            default: return "workspace_authorization_unavailable"
            }
        }
        if request.toolName.hasPrefix("mcp_") { return "external_effect" }
        return manualReason(for: request.toolName)
    }

    private static func manualReason(for name: String) -> String {
        switch name {
        case "shell_run": return "unverified_shell"
        case "python_execute", "skill_run_script": return "code_execution"
        case "files_edit": return "file_mutation"
        case "browser_click", "browser_evaluate": return "browser_action"
        case "mail_send", "mail_delete": return "external_effect"
        case "files_delete", "files_rename", "files_move", "files_copy": return "file_mutation"
        default: return "not_eligible"
        }
    }

    private static func shellReadDecision(_ request: AutoReviewRequest, environment: AutoReviewEnvironment) -> AutoReviewDecision {
        let args = ToolArguments.parse(request.argumentsJSON)
        if let raw = args["execution_mode"], raw as? String != "sandbox" {
            return .manual(reason: "host_execution")
        }
        guard !ShellFileRedirection.isRequested(args) else { return .manual(reason: "unverified_shell") }
        guard let root = FileAreaService.expandHome(environment.workspacePath) else {
            return .manual(reason: "unverified_scope")
        }
        let explicit = ToolArguments.string(args, "working_directory").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let directory = explicit.isEmpty ? root : FileAreaService.expandHome(explicit) else {
            return .manual(reason: "unverified_scope")
        }
        let roots: [URL]
        if let scope = request.taskScope {
            guard scope.space == environment.space, scope.isActive() else { return .manual(reason: "task_scope_inactive") }
            roots = scope.readRoots.map { URL(fileURLWithPath: $0) }
        } else {
            roots = [root]
        }
        if let command = ShellRunTool.readOnlyCommand(args) {
            return command.isInside(workspaces: roots, directory: directory)
                ? .approve(reason: "read_only_command")
                : .manual(reason: "unverified_scope")
        }
        return .manual(reason: "unverified_shell")
    }

    /// Workspace authority comes from the current task and the tool's resolved targets.
    /// The model-review preference only controls calls routed to a reviewer.
    private static func scopedWriteDecision(
        _ request: AutoReviewRequest, environment: AutoReviewEnvironment
    ) -> AutoReviewRuleResult {
        guard let scope = request.taskScope, scope.workspaceIdentity != nil,
              scope.space == environment.space else { return .manual(reason: "unverified_scope") }
        guard scope.approvalPolicyVersion == ruleVersion, scope.allowsDeterministicApproval else { return .manual(reason: "deterministic_disabled") }
        guard scope.isActive() else { return .manual(reason: "task_scope_inactive") }
        guard scope.permissionMode != .readOnly, scope.allowsTool(named: request.toolName),
              scope.allows(.workspaceMutation) else { return .manual(reason: "task_write_prohibited") }
        guard !request.writeTargets.isEmpty else { return .manual(reason: "missing_path") }
        guard scope.containsReadTargets(request.readTargets), scope.containsWriteTargets(request.writeTargets) else { return .reject(reason: "outside_workspace") }
        if request.toolName == "files_edit" || request.toolName == "files_apply_changes" {
            guard request.evidence["recovery_store"] == "true" else { return .manual(reason: "recovery_unavailable") }
            // Both installed tools validate their versioned edit arguments before approval
            // and check the actual bytes again at publication.
            return .approve(reason: "task_scope_edit")
        }
        return .approve(reason: "inside_workspace")
    }

    /// 模型复核超时保护：到期返回转人工（不阻塞工具循环）
    private static func withTimeout(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async -> AutoReviewDecision?
    ) async -> AutoReviewDecision? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AutoReviewDecision?, Never>) in
            let gate = AutoReviewRaceGate(continuation)
            // 评审放在非结构化任务里：如果放进 task group，作用域退出时会等待所有
            // 子任务结束——一个不响应取消的复核器仍会把超时拖成无限等待。
            let reviewerTask = Task {
                let decision = await operation()
                gate.resolve(decision)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resolve(.manual(reason: "review_timeout"))
                reviewerTask.cancel()
            }
        }
    }
}

/// 模型审核结果缓存：只缓存 approve/reject，且键包含调用参数、任务范围和策略版本
/// （由 `AutoReviewDigest` 生成）。manual、超时和服务不可用不缓存。
public actor AutoReviewDecisionCache {
    private struct Entry: Sendable {
        let decision: AutoReviewDecision
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let limit: Int

    public init(ttl: TimeInterval = 120, limit: Int = 256) {
        self.ttl = max(1, ttl)
        self.limit = max(1, limit)
    }

    public func decision(for key: String) -> AutoReviewDecision? {
        prune()
        guard let entry = entries[key], entry.expiresAt > Date() else {
            entries[key] = nil
            return nil
        }
        return entry.decision
    }

    public func store(_ decision: AutoReviewDecision, for key: String) {
        switch decision {
        case .approve, .reject:
            break
        case .manual:
            return
        }
        prune()
        if entries.count >= limit, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries[oldest] = nil
        }
        entries[key] = Entry(decision: decision, expiresAt: Date().addingTimeInterval(ttl))
    }

    public func removeAll() {
        entries.removeAll()
    }

    private func prune() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

/// 超时竞速的单次完成闸门：复核任务与超时定时器可能同时想回复，
/// 只允许第一个生效（CheckedContinuation 双 resume 会触发运行时崩溃）。
private final class AutoReviewRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AutoReviewDecision?, Never>?

    init(_ continuation: CheckedContinuation<AutoReviewDecision?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ decision: AutoReviewDecision?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: decision)
    }
}

// MARK: - Auto Review Audit（审核记录）

/// 自动审核记录条目：调用 ID、工具、规则版本、决策、简短原因与时间。
/// 只记稳定标识与短原因，不写完整敏感参数（与副作用日志同一脱敏原则）
public struct AutoReviewAuditEntry: Codable, Sendable, Equatable {
    public let callId: String
    public let toolName: String
    public let ruleVersion: String
    /// 决策：approved / manual / rejected
    public let decision: String
    /// 简短原因标识（非本地化文案）
    public let reason: String
    public let time: Date
    /// 任务身份（旧记录缺省为 nil）。
    public let taskID: String?
    /// 审批路由：manualOnly / deterministic / modelReviewable。
    public let route: String?
    /// 任务范围摘要（不写用户原文）。
    public let taskScopeDigest: String?
    /// 调用摘要：参数、任务范围和策略版本变化后不再相同。
    public let callDigest: String?
    /// 执行档/能力档（如 offline_artifacts、skill_snapshot）；未知为 nil。
    public let executionProfile: String?

    public init(
        callId: String,
        toolName: String,
        ruleVersion: String,
        decision: String,
        reason: String,
        time: Date = Date(),
        taskID: String? = nil,
        route: String? = nil,
        taskScopeDigest: String? = nil,
        callDigest: String? = nil,
        executionProfile: String? = nil
    ) {
        self.callId = callId
        self.toolName = toolName
        self.ruleVersion = ruleVersion
        self.decision = decision
        self.reason = reason
        self.time = time
        self.taskID = taskID
        self.route = route
        self.taskScopeDigest = taskScopeDigest
        self.callDigest = callDigest
        self.executionProfile = executionProfile
    }

    /// 审批链路的独立记录：manual / revoked / expired 等状态不需要伪造一个
    /// AutoReviewDecision，仍保留稳定标识与短原因。
    public init(
        callId: String,
        toolName: String,
        decision: String,
        reason: String,
        ruleVersion: String = "approval/v1",
        time: Date = Date(),
        taskID: String? = nil,
        route: String? = nil,
        taskScopeDigest: String? = nil,
        callDigest: String? = nil,
        executionProfile: String? = nil
    ) {
        self.callId = callId
        self.toolName = toolName
        self.decision = decision
        self.reason = reason
        self.ruleVersion = ruleVersion
        self.time = time
        self.taskID = taskID
        self.route = route
        self.taskScopeDigest = taskScopeDigest
        self.callDigest = callDigest
        self.executionProfile = executionProfile
    }

    /// 由审核结论生成记录（时间取当前）
    public init(request: AutoReviewRequest, decision: AutoReviewDecision, time: Date = Date()) {
        self.callId = request.callId
        self.toolName = request.toolName
        self.ruleVersion = AutoReviewService.ruleVersion
        switch decision {
        case .approve(let reason):
            self.decision = "approved"
            self.reason = reason
        case .manual(let reason):
            self.decision = "manual"
            self.reason = reason
        case .reject(let reason):
            self.decision = "rejected"
            self.reason = reason
        }
        self.time = time
        self.taskID = request.taskScope?.id.uuidString
        self.route = request.route.rawValue
        self.taskScopeDigest = request.taskScope?.digest
        self.callDigest = request.callDigest
        self.executionProfile = request.evidence["execution_profile"]
    }
}

/// 审核记录：按空间存 JSON 文件（`<space>/auto-review.json`），
/// 跨进程锁保护读-改-写；损坏或不可用时停止追加并保留原文件。
public final class AutoReviewAuditLog: @unchecked Sendable {

    public enum LoadResult: Sendable {
        case missing
        case loaded([AutoReviewAuditEntry])
        case corrupt
        case unavailable
    }

    static let maxEntries = 500

    let fileURL: URL
    private let fileManager = FileManager.default
    /// 所有实例共用串行 I/O 队列，避免同空间多个会话并发追加时覆盖记录。
    private static let ioQueue = DispatchQueue(label: "com.agroom.auto-review-audit.io")

    public init(spaceDirectoryURL: URL) {
        self.fileURL = spaceDirectoryURL.appendingPathComponent("auto-review.json")
    }

    /// 便捷构造：从技能库目录（`<space>/skills/`）推出空间目录
    public convenience init(skillsDirectoryURL: URL) {
        self.init(spaceDirectoryURL: skillsDirectoryURL.deletingLastPathComponent())
    }

    /// 追加一条审核记录（失败记日志，不影响工具主流程）
    @discardableResult
    public func record(_ entry: AutoReviewAuditEntry) -> Bool {
        let saved = Self.ioQueue.sync {
            withFileLock {
                var entries: [AutoReviewAuditEntry]
                switch readLocked() {
                case .missing: entries = []
                case .loaded(let value): entries = value
                case .corrupt, .unavailable: return false
                }
                entries.append(entry)
                if entries.count > Self.maxEntries {
                    entries = Array(entries.suffix(Self.maxEntries))
                }
                do {
                    let data = try JSONEncoder().encode(entries)
                    try data.write(to: fileURL, options: .atomic)
                    return true
                } catch {
                    return false
                }
            } ?? false
        }
        if !saved { HubLogger.shared.warning("Approval audit unavailable; existing records were preserved.") }
        return saved
    }

    /// 全部记录（新→旧）
    public func entries() -> [AutoReviewAuditEntry] {
        if case .loaded(let entries) = loadResult() { return entries.sorted { $0.time > $1.time } }
        return []
    }

    public func loadResult() -> LoadResult {
        Self.ioQueue.sync { withFileLock { readLocked() } ?? .unavailable }
    }

    private func withFileLock<T>(_ body: () -> T) -> T? {
        do { try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return nil }
        let descriptor = open(fileURL.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private func readLocked() -> LoadResult {
        var info = stat()
        if lstat(fileURL.path, &info) != 0 { return errno == ENOENT ? .missing : .unavailable }
        let data: Data
        do { data = try ScriptFileIdentity.read(fileURL, limit: 4 * 1024 * 1024) }
        catch { return .unavailable }
        do {
            return .loaded(try JSONDecoder().decode([AutoReviewAuditEntry].self, from: data))
        } catch {
            return .corrupt
        }
    }
}
