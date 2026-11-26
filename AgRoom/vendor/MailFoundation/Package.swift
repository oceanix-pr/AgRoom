// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// AgRoom uses Network.framework on Apple platforms. SwiftPM discovers even
// unused system-library targets, so declare OpenSSL only on Linux, where needed.
// See AGROOM-PATCH.md for the upstream revision and local patch boundary.
var mailDependencies: [Target.Dependency] = ["MimeFoundation"]
var mailTargets: [Target] = []
#if os(Linux)
mailTargets.append(
    .systemLibrary(
        name: "COpenSSL",
        pkgConfig: "openssl",
        providers: [.apt(["libssl-dev"])]
    )
)
mailDependencies.append("COpenSSL")
#endif
mailTargets += [
    .target(name: "MailFoundation", dependencies: mailDependencies),
    .testTarget(
        name: "MailFoundationTests",
        dependencies: ["MailFoundation"],
        resources: [.process("Fixtures")]
    )
]

let package = Package(
    name: "MailFoundation",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MailFoundation",
            targets: ["MailFoundation"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/MimeFoundation", revision: "dcb6746729d20cf00c42ad6453b4637a075f7d0b")
    ],
    targets: mailTargets
)
