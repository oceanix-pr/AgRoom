import Testing
import Foundation
@testable import AgRoomCore

@Suite("ChildProcessRunner")
struct ChildProcessRunnerTests {

    @Test("Output budgets reject fast exits, count files, and never follow a symlink root")
    func outputBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("process-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        try Data(repeating: 0, count: 1025).write(to: file)
        var budget = ChildProcessBudget(maximumResidentBytes: .max, maximumOutputBytes: 1024,
            maximumOutputFiles: 10, outputRoots: [root])
        #expect(budget.outputViolation() == "output_bytes")
        budget.maximumOutputBytes = 2048
        budget.maximumOutputFiles = 0
        #expect(budget.outputViolation() == "output_file_count")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        budget.outputRoots = [link]
        #expect(budget.outputViolation() == "output_monitor_unavailable")
        budget.outputRoots = [root]
        var spec = ChildProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
            timeout: 2, outputLimit: 1000, label: "budget-test")
        spec.resourceBudget = budget
        let result = await ChildProcessRunner.run(spec)
        #expect(result.outcome == .resourceLimited("output_file_count"))
    }

    @Test("Resident memory budget stops the process and reports a distinct failure")
    func memoryBudget() async {
        var spec = ChildProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            timeout: 5, outputLimit: 1000, label: "memory-budget-test")
        spec.resourceBudget = ChildProcessBudget(maximumResidentBytes: 1, maximumOutputBytes: 1024,
            maximumOutputFiles: 1, outputRoots: [])
        let result = await ChildProcessRunner.run(spec)
        #expect(result.outcome == .resourceLimited("resident_memory"))
        #expect(result.duration < 4)
    }

    private func request(
        _ script: String,
        timeout: TimeInterval = 5,
        outputLimit: Int = 16_384
    ) -> ChildProcessRequest {
        ChildProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: timeout,
            outputLimit: outputLimit,
            mergeStandardError: true,
            label: "tests"
        )
    }

    @Test("does not wait for pipe EOF when a background descendant keeps stdout open")
    func backgroundPipeHolderDoesNotHang() async {
        let start = Date()
        let result = await ChildProcessRunner.run(request(
            "yes x | head -c 200000; (sleep 2) &",
            timeout: 5
        ))
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.outcome.isSuccess)
        #expect(elapsed < 3, "runner must finish on process exit, not pipe EOF")
        #expect(result.stdout.contains("[truncated]"))
    }

    @Test("timeout terminates the process and is never reported as success")
    func timeoutIsDistinct() async {
        let start = Date()
        let result = await ChildProcessRunner.run(request("sleep 30", timeout: 0.2))
        #expect(result.outcome.isTimedOut)
        #expect(!result.outcome.isSuccess)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("cancellation stops the process before a later side effect runs")
    func cancellationPreventsSideEffects() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-process-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let task = Task {
            await ChildProcessRunner.run(request("sleep 30; touch \(marker.path)", timeout: 60))
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(result.outcome.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("launch failure is explicit, not an empty successful process")
    func launchFailureIsExplicit() async {
        let result = await ChildProcessRunner.run(ChildProcessRequest(
            executable: URL(fileURLWithPath: "/definitely/not/a/program-\(UUID().uuidString)"),
            arguments: [],
            timeout: 2,
            outputLimit: 1024,
            label: "tests"
        ))
        guard case .launchFailed = result.outcome else {
            Issue.record("expected launchFailed, got \(result.outcome)")
            return
        }
        #expect(!result.outcome.isSuccess)
    }

    @Test("Fast concurrent exits retain complete stdout and stderr")
    func fastExitOutputIsComplete() async {
        await withTaskGroup(of: ChildProcessResult.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    var spec = request("printf stdout; printf stderr >&2; exit 7")
                    spec.mergeStandardError = false
                    return await ChildProcessRunner.run(spec)
                }
            }
            for await result in group {
                #expect(result.exitCode == 7)
                #expect(result.stdout == "stdout")
                #expect(result.stderr == "stderr")
            }
        }
    }
}
