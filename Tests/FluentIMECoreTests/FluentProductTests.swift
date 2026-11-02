import XCTest
@testable import FluentIMECore

final class FluentProductTests: XCTestCase {
    func testProductsNeverShareIdentityDataOrAssets() {
        let pinyin = FluentProduct.pinyin, zhuyin = FluentProduct.zhuyin
        for key in [\FluentProduct.bundleID, \.sourceID, \.appName, \.supportFolder, \.installerID, \.maintenanceID,
                    \.installerName, \.maintenanceName, \.connectionName, \.assetPrefix, \.clipboardKeychainService] {
            XCTAssertNotEqual(pinyin[keyPath: key], zhuyin[keyPath: key])
        }
        // Fluent 拼音 keeps the identifiers it shipped with.
        XCTAssertEqual(pinyin.bundleID, "org.fluentime.inputmethod.FluentIME")
        XCTAssertEqual(pinyin.appFileName, "Fluent IME.app")
        XCTAssertEqual(pinyin.supportFolder, "FluentIME")
        XCTAssertEqual(zhuyin.keyboard, .zhuyin)
        XCTAssertEqual(FluentProduct.current, .pinyin, "Bundles without FluentIMEProduct are Fluent 拼音")
        let home = URL(fileURLWithPath: "/tmp/fluent-home")
        XCTAssertNotEqual(InstallationFiles(home: home, product: pinyin).application, InstallationFiles(home: home, product: zhuyin).application)
        XCTAssertNotEqual(InstallationFiles(home: home, product: pinyin).support, InstallationFiles(home: home, product: zhuyin).support)
    }

    func testEachProductFindsOnlyItsOwnAssetsInASharedRelease() throws {
        let names = ["Fluent-IME-0.8.0-Setup.dmg", "Fluent-IME-0.8.0-Full-Setup.dmg", "Fluent-Zhuyin-0.8.0-Setup.dmg",
                     "release.json", "release-full.json", "release-zhuyin.json"]
        let release = GitHubRelease(tag_name: "v0.8.0", draft: false, prerelease: false, assets: names.map {
            .init(name: $0, size: 8, browser_download_url: URL(string: "https://github.com/egysoloman/Fluent-IME/releases/download/v0.8.0/" + $0)!, digest: nil)
        })
        XCTAssertEqual(release.installer(for: .lite, product: .pinyin)?.name, "Fluent-IME-0.8.0-Setup.dmg")
        XCTAssertEqual(release.installer(for: .full, product: .pinyin)?.name, "Fluent-IME-0.8.0-Full-Setup.dmg")
        XCTAssertEqual(release.manifest(for: .full, product: .pinyin)?.name, "release-full.json")
        XCTAssertEqual(release.installer(for: .lite, product: .zhuyin)?.name, "Fluent-Zhuyin-0.8.0-Setup.dmg")
        XCTAssertEqual(release.manifest(for: .lite, product: .zhuyin)?.name, "release-zhuyin.json")
        let pinyinOnly = GitHubRelease(tag_name: "v0.7.0", draft: false, prerelease: false, assets: release.assets.filter { !$0.name.contains("Zhuyin") && !$0.name.contains("zhuyin") })
        XCTAssertNil(pinyinOnly.installer(for: .lite, product: .zhuyin), "A release without a Zhuyin package offers Zhuyin nothing")
    }

    func testZhuyinSharesCatalogsUnderItsOwnName() {
        XCTAssertEqual(L10n.zhuyinNames("欢迎使用 Fluent 拼音"), "欢迎使用 Fluent 注音")
        XCTAssertEqual(L10n.zhuyinNames("Welcome to Fluent Pinyin"), "Welcome to Fluent Zhuyin")
    }
}
