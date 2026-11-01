import XCTest
@testable import FluentIMECore

final class LocalizationTests: XCTestCase {
    func testLowercasedSwiftPMResourceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        for (language, title) in [("zh-hans", "输入预览"), ("zh-hant", "輸入預覽"), ("en", "Typing preview")] {
            let folder = root.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(("\"preview.title\" = \"" + title + "\";\n").utf8).write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        let bundle = try XCTUnwrap(Bundle(url: root))
        let languages = L10n.localizedBundles(in: bundle)
        XCTAssertEqual(languages["zh-Hans"]?.localizedString(forKey: "preview.title", value: nil, table: "Localizable"), "输入预览")
        XCTAssertEqual(languages["zh-Hant"]?.localizedString(forKey: "preview.title", value: nil, table: "Localizable"), "輸入預覽")
        XCTAssertEqual(languages["en"]?.localizedString(forKey: "preview.title", value: nil, table: "Localizable"), "Typing preview")
    }
    func testModuleCatalogsResolveWithoutTheApplicationBundle() {
        XCTAssertEqual(L10n.text("preview.title", language: "zh-Hans"), "输入预览")
        XCTAssertEqual(L10n.text("preview.title", language: "en"), "Typing preview")
        XCTAssertEqual(L10n.text("mode.switchToEnglish", language: "en"), "Switch to English")
        XCTAssertEqual(L10n.text("keys.keepSelection", language: "zh-Hans"), "翻页时保留候选词高亮位置")
    }

    func testLanguagePreferencesAndFallback() {
        XCTAssertEqual(L10n.resolveLanguage(["fr-FR", "en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(L10n.resolveLanguage(["zh_CN", "en"]), "zh-Hans")
        XCTAssertEqual(L10n.resolveLanguage(["zh-Hant-HK"]), "zh-Hant")
        XCTAssertEqual(L10n.resolveLanguage(["zh_TW", "en"]), "zh-Hant")
        XCTAssertEqual(L10n.text("preview.title", language: "zh-Hant"), "輸入預覽")
        XCTAssertEqual(L10n.resolveLanguage(["ja"]), "zh-Hans")
        XCTAssertEqual(L10n.text("preview.title", language: "missing"), "输入预览")
    }

    func testPositionalFormatsPreserveUserContent() {
        let filename = "100% \"测试\".gif"
        XCTAssertEqual(L10n.format("gif.copyAccessibility", language: "en", arguments: [filename]), "Copy GIF: " + filename)
        XCTAssertEqual(L10n.format("candidate.item", language: "en", arguments: [2, "呢"]), "2, 呢")
        XCTAssertEqual(L10n.format("gif.added", language: "zh-Hans", arguments: [3]), "已添加 3 个 GIF。")
        XCTAssertEqual(L10n.format("gif.added", language: "en", arguments: [1]), "Added 1 GIF(s).")
    }
}
