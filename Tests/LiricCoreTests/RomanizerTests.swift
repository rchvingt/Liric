@testable import LiricCore
import XCTest

final class RomanizerTests: XCTestCase {
    // MARK: Korean (Revised Romanization + sound changes)

    func testKoreanBasics() {
        XCTAssertEqual(HangulRomanizer.romanize("안녕하세요"), "annyeonghaseyo")
        XCTAssertEqual(HangulRomanizer.romanize("사랑해"), "saranghae")
    }

    func testKoreanSoundChanges() {
        XCTAssertEqual(HangulRomanizer.romanize("감사합니다"), "gamsahamnida") // nasalization
        XCTAssertEqual(HangulRomanizer.romanize("좋아"), "joa")                // silent ㅎ
        XCTAssertEqual(HangulRomanizer.romanize("읽어"), "ilgeo")              // compound final liaison
        XCTAssertEqual(HangulRomanizer.romanize("같이"), "gachi")              // palatalization
        XCTAssertEqual(HangulRomanizer.romanize("몰라"), "molla")              // ㄹㄹ
        XCTAssertEqual(HangulRomanizer.romanize("좋다"), "jota")               // aspiration
        XCTAssertEqual(HangulRomanizer.romanize("없어"), "eopseo")
    }

    func testKoreanKeepsEnglishAndSpacing() {
        XCTAssertEqual(HangulRomanizer.romanize("Baby 보고 싶어!"), "Baby bogo sipeo!")
    }

    // MARK: Japanese (system tokenizer — readings depend on the macOS dictionary)

    func testJapaneseKanaProducesRomaji() {
        let result = JapaneseRomanizer.romanize("ありがとう", keepMacrons: false)
        XCTAssertTrue(result.hasPrefix("arigat"), result)
        XCTAssertTrue(result.unicodeScalars.allSatisfy(\.isASCII), result)
    }

    func testJapaneseKanjiIsNotPinyin() {
        // 東京 must come out as Japanese "tokyo"-ish, never Chinese "dong jing".
        let result = JapaneseRomanizer.romanize("東京", keepMacrons: false)
        XCTAssertFalse(result.contains("dong"), result)
        XCTAssertTrue(result.hasPrefix("to"), result)
    }

    func testJapaneseParticleWa() {
        let result = JapaneseRomanizer.romanize("私は", keepMacrons: false)
        XCTAssertTrue(result.hasSuffix("wa"), result)
    }

    // MARK: Romanizer routing + fallbacks

    func testEnglishSongIsNotRomanized() {
        let text = LyricText(plain: "Hello darkness my old friend")
        XCTAssertNil(Romanizer().romanize(text, language: .english))
    }

    func testMixedKpopLinePassesEnglishThrough() {
        let line = Romanizer().romanizeLine("Oh my love 너를", songLanguage: .korean)
        XCTAssertEqual(line, "Oh my love neoreul")
    }

    func testSyncedTimestampsArePreserved() throws {
        let text = LyricText(lrc: "[00:01.00]사랑해\n[00:05.50]Love you")
        let romanized = try XCTUnwrap(Romanizer().romanize(text, language: .korean))
        let lines = LRC.parse(try XCTUnwrap(romanized.synced))
        XCTAssertEqual(lines.map(\.time), [1.0, 5.5])
        XCTAssertEqual(lines.map(\.text), ["saranghae", "Love you"])
    }

    // MARK: Language detection

    func testLanguageDetection() {
        XCTAssertEqual(LanguageDetector.detect("너를 사랑해 I love you so much baby"), .korean)
        XCTAssertEqual(LanguageDetector.detect("君が好きだよ forever"), .japanese)
        XCTAssertEqual(LanguageDetector.detect("I want to hold your hand"), .english)
        XCTAssertEqual(LanguageDetector.detect("我爱你中国"), .undetermined) // Han only → not Japanese
    }
}
