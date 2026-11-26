// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgRoom",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AgRoomCore",
            targets: ["AgRoomCore"]
        ),
        .library(
            name: "AgRoomUI",
            targets: ["AgRoomUI"]
        ),
        .executable(
            name: "AgRoom",
            targets: ["AgRoom"]
        ),
        .executable(
            name: "AgRoomDaemon",
            targets: ["AgRoomDaemon"]
        ),
        .executable(
            name: "AgRoomScriptRunner",
            targets: ["AgRoomScriptRunner"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "0.18.0"),
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", revision: "1cb484af5e69d3c7803c1eb0b3b5ab8041e0e911"),
        .package(path: "vendor/mysql-nio"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(path: "vendor/swift-nio-ssl"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0"),
        // 与 Markdown 一起固定，保持工程现有工具链兼容性。
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.6.0"),
        // 邮件协议栈使用固定的本地副本；来源与 manifest 补丁见 vendor/MailFoundation/AGROOM-PATCH.md。
        // 与固定副本及 XcodeGen 使用同一 revision，避免解析时更新 main 分支。
        .package(path: "vendor/MailFoundation"),
        .package(url: "https://github.com/migueldeicaza/MimeFoundation", revision: "dcb6746729d20cf00c42ad6453b4637a075f7d0b")
    ],
    targets: [
        .target(name: "AgRoomScriptIPC", path: "Sources/AgRoomScriptIPC"),
        .executableTarget(name: "AgRoomScriptRunner", dependencies: ["AgRoomScriptIPC"],
                          path: "Sources/AgRoomScriptRunner"),
        .target(
            name: "AgRoomCore",
            dependencies: [
                "AgRoomScriptIPC",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MailFoundation", package: "MailFoundation"),
                .product(name: "MimeFoundation", package: "MimeFoundation")
            ],
            path: "Sources/AgRoomCore"
        ),
        .target(
            name: "AgRoomUI",
            dependencies: ["AgRoomCore", .product(name: "Markdown", package: "swift-markdown")],
            path: "Sources/AgRoomUI",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AgRoom",
            dependencies: ["AgRoomUI"],
            path: "Sources/AgRoom",
            exclude: ["Info.plist"],
            resources: [.copy("EmbeddingRuntime"), .copy("Notices")]
        ),
        .executableTarget(
            name: "AgRoomDaemon",
            dependencies: ["AgRoomCore"],
            path: "Sources/AgRoomDaemon"
        ),
        .testTarget(
            name: "AgRoomCoreTests",
            dependencies: ["AgRoomCore", "AgRoomUI", "AgRoomScriptIPC"],
            path: "Tests/AgRoomCoreTests"
        )
    ]
)
