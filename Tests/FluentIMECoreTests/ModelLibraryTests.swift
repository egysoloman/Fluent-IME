import XCTest
@testable import FluentIMECore

final class ModelLibraryTests: XCTestCase {
    private func grammar() -> Data {
        var data = Data(repeating: 0, count: 44 + 256 * 4)
        data.replaceSubrange(0..<17, with: "Rime::Grammar/1.0\0".utf8)
        data[37] = 1 // 256 uint32 units
        data[40] = 4 // relative offset from byte 40 to byte 44
        return data
    }
    func testImportRestoreAndUnownedOverrideBackup() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let library = ModelLibrary(root: temp.appendingPathComponent("Models")), user = temp.appendingPathComponent("Rime")
        let source = temp.appendingPathComponent("source.gram")
        try grammar().write(to: source)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let override = user.appendingPathComponent("wanxiang-lts-zh-hans.gram")
        try Data("old user override".utf8).write(to: override)
        let imported = try library.importGrammar(from: source)
        XCTAssertEqual(library.selection.grammar, imported.lastPathComponent)
        try library.prepareGrammar(in: user)
        XCTAssertEqual(try Data(contentsOf: override), grammar())
        let backup = try FileManager.default.contentsOfDirectory(at: user, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("previous-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), Data("old user override".utf8))
        try library.restoreBundled(grammar: true)
        try library.prepareGrammar(in: user)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
    }
    func testRejectedImportKeepsSelectionAndCleansStaging() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let library = ModelLibrary(root: temp.appendingPathComponent("Models")), source = temp.appendingPathComponent("model.gram")
        try grammar().write(to: source); try library.importGrammar(from: source)
        let previous = library.selection
        var corrupt = grammar(); corrupt[40] = 255
        try corrupt.write(to: source)
        XCTAssertThrowsError(try library.importGrammar(from: source))
        XCTAssertEqual(library.selection, previous)
        corrupt = grammar(); corrupt[46] = 0xFF // node offset outside the array
        try corrupt.write(to: source)
        XCTAssertThrowsError(try library.importGrammar(from: source))
        XCTAssertThrowsError(try library.importTransformer(from: temp))
        XCTAssertEqual(library.selection, previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.path).count, 2)
        XCTAssertNil(library.directory(for: "../../escape"))
    }
}
