// swift-tools-version: 5.9
import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
// Local overrides are optional; normal builds resolve the public Swift package.
let fluentDependency: Package.Dependency = environment["FLUENTKIT_PATH"].map { .package(path: $0) }
    ?? .package(url: "https://github.com/egysoloman/FluentKit.git", from: "0.2.0")
let fluentIdentity = environment["FLUENTKIT_PATH"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "FluentKit"
let rimePrefix = environment["RIME_PREFIX"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/rime-runtime").path

let package = Package(
    name: "FluentIME",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FluentIME", targets: ["FluentIME"])],
    dependencies: [fluentDependency],
    targets: [
        .target(name: "CRimeBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + rimePrefix + "/include"])],
                linkerSettings: [.unsafeFlags(["-L" + rimePrefix + "/lib", "-Xlinker", "-rpath", "-Xlinker", rimePrefix + "/lib"]), .linkedLibrary("rime")]),
        .target(name: "FluentIMECore", dependencies: ["CRimeBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "FluentIME", dependencies: [
            "FluentIMECore", .product(name: "FluentKit", package: fluentIdentity)
        ], linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "FluentIMECoreTests", dependencies: ["FluentIMECore"])
    ]
)
