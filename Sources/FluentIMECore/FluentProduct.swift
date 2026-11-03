import Foundation

/// Fluent 拼音 and Fluent 注音 are separate input methods built from one binary.
/// Each bundle (input method, installer and maintenance app) names its product with
/// `FluentIMEProduct` in Info.plist; each product touches only its own app, data,
/// preferences and release assets. Pinyin keeps the identifiers it shipped with.
public struct FluentProduct: Equatable {
    public enum Kind: String { case pinyin, zhuyin }
    public let kind: Kind
    public let bundleID: String
    public let sourceID: String
    public let appName: String
    public let supportFolder: String
    public let installerID: String
    public let maintenanceID: String
    public let installerName: String
    public let maintenanceName: String
    public let connectionName: String
    public let assetPrefix: String
    public var keyboard: InputKeyboard { kind == .zhuyin ? .zhuyin : .pinyin }
    public var appFileName: String { appName + ".app" }
    public var clipboardKeychainService: String { kind == .zhuyin ? "org.fluentime.zhuyin.clipboard.v1" : "org.fluentime.clipboard.v1" }

    public static let pinyin = FluentProduct(kind: .pinyin, bundleID: "org.fluentime.inputmethod.FluentIME",
        sourceID: "org.fluentime.inputmethod.FluentIME.Hans", appName: "Fluent IME", supportFolder: "FluentIME",
        installerID: "org.fluentime.installer", maintenanceID: "org.fluentime.maintenance",
        installerName: "Fluent IME Setup", maintenanceName: "Fluent IME Maintenance",
        connectionName: "FluentIME_Connection", assetPrefix: "Fluent-IME")
    public static let zhuyin = FluentProduct(kind: .zhuyin, bundleID: "org.fluentime.inputmethod.FluentZhuyin",
        sourceID: "org.fluentime.inputmethod.FluentZhuyin.Bopomofo", appName: "Fluent Zhuyin", supportFolder: "FluentZhuyin",
        installerID: "org.fluentime.zhuyin.installer", maintenanceID: "org.fluentime.zhuyin.maintenance",
        installerName: "Fluent Zhuyin Setup", maintenanceName: "Fluent Zhuyin Maintenance",
        connectionName: "FluentZhuyin_Connection", assetPrefix: "Fluent-Zhuyin")
    public static let all = [pinyin, zhuyin]

    public static let current: FluentProduct = (Bundle.main.object(forInfoDictionaryKey: "FluentIMEProduct") as? String) == Kind.zhuyin.rawValue ? zhuyin : pinyin

    /// Zhuyin ships one edition; Pinyin has Lite, Full and Update.
    public func installerAsset(version: String, edition: ReleaseEdition) -> String {
        kind == .zhuyin ? "\(assetPrefix)-\(version)-Setup.dmg" : "\(assetPrefix)-\(version)\(edition == .full ? "-Full" : edition == .update ? "-Update" : "")-Setup.dmg"
    }
    public func manifestAsset(edition: ReleaseEdition) -> String {
        kind == .zhuyin ? "release-zhuyin.json" : edition == .full ? "release-full.json" : edition == .update ? "release-update.json" : "release.json"
    }
    public func support(in home: URL) -> URL { home.appendingPathComponent("Library/Application Support/" + supportFolder) }
    public var supportDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(supportFolder) }
}
