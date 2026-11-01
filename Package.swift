// swift-tools-version: 5.9
import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let fluentPath = environment["FLUENTKIT_PATH"] ?? ".build/dependencies/fluentkit-01c8e66/WinUI-macOS"
let rimePrefix = environment["RIME_PREFIX"] ?? (FileManager.default.fileExists(atPath: "/opt/homebrew/opt/librime") ? "/opt/homebrew/opt/librime" : "/usr/local/opt/librime")

let package = Package(
    name: "FluentIME",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FluentIME", targets: ["FluentIME"])],
    dependencies: [.package(path: fluentPath)],
    targets: [
        .target(name: "CRimeBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + rimePrefix + "/include"])],
                linkerSettings: [.unsafeFlags(["-L" + rimePrefix + "/lib"]), .linkedLibrary("rime")]),
        .target(name: "FluentIMECore", dependencies: ["CRimeBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "FluentIME", dependencies: [
            "FluentIMECore", .product(name: "FluentKit", package: "WinUI-macOS")
        ], linkerSettings: [.linkedFramework("InputMethodKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "FluentIMECoreTests", dependencies: ["FluentIMECore"])
    ]
)
