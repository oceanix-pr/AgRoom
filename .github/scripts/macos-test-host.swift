import Foundation
import Testing

/// AppKit may stop the main run loop between test steps. Keep serving the main
/// actor until Swift Testing finishes the selected suite and exits with its status.
@main
enum MacOSTestHost {
    static func main() throws {
        guard let path = ProcessInfo.processInfo.environment["AGROOM_TEST_BUNDLE"],
              let bundle = Bundle(path: path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try bundle.loadAndReturnError()

        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        Task { await Testing.__swiftPMEntryPoint() as Never }
        while true { CFRunLoopRun() }
    }
}
