import XCTest
@testable import FluentIMECore

final class NeuralRankingTests: XCTestCase {
    func testRankingIsConservativeAndNeverCrossesLengthOrEmojiGroups() {
        let words = [Candidate("知道"),Candidate("指导"),Candidate("指"),Candidate("👋")]
        XCTAssertEqual(CandidateRanking.order(candidates: words, scores: [-3,-2.9,-1,0]), [0,1,2,3])
        XCTAssertEqual(CandidateRanking.order(candidates: words, scores: [-5,-1,-1,0]), [1,0,2,3])
        XCTAssertEqual(CandidateRanking.order(candidates: words, scores: [.nan,-1,nil,nil]), [0,1,2,3])
    }
    func testTokenizerMatchesPinnedBertVocabularyForChineseAndMixedText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tokenizer = try ChineseTokenizer(vocabularyURL: root.appendingPathComponent("Resources/Models/rbt3-vocab.txt"))
        XCTAssertEqual(tokenizer.encode("你好，世界！"), [872,1962,8024,686,4518,8013])
        XCTAssertEqual(tokenizer.encode("HELLO"), tokenizer.encode("hello"))
        XCTAssertEqual(tokenizer.encode("café"), tokenizer.encode("cafe"))
        XCTAssertEqual(tokenizer.encode("你\n好"), tokenizer.encode("你 好"))
        XCTAssertEqual(tokenizer.encode("🐍"), [tokenizer.unknown])
        XCTAssertEqual(tokenizer.encode(String(repeating: "a", count: 101)), [tokenizer.unknown])
    }
}
