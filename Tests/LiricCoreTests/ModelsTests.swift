@testable import LiricCore
import XCTest

final class ModelsTests: XCTestCase {
    func testLRCParsing() {
        let lrc = """
        [ar:NewJeans]
        [00:12.34]Line one
        [00:20.00][01:00.50]Chorus
        """
        let lines = LRC.parse(lrc)
        XCTAssertEqual(lines.map(\.text), ["Line one", "Chorus", "Chorus"])
        XCTAssertEqual(lines.first?.time ?? 0, 12.34, accuracy: 0.001)
        XCTAssertEqual(LRC.format(60.5), "01:00.50")
    }

    func testLookupKeyNormalization() {
        let a = TrackInfo(title: "Ditto (feat. Someone)", artist: "NewJeans")
        let b = TrackInfo(title: "ditto", artist: "ＮｅｗＪｅａｎｓ")
        XCTAssertEqual(a.lookupKey, b.lookupKey)

        // Language versions of the same K-pop song must stay distinct.
        let jp = TrackInfo(title: "Dynamite (Japanese ver.)", artist: "BTS")
        let en = TrackInfo(title: "Dynamite", artist: "BTS")
        XCTAssertNotEqual(jp.lookupKey, en.lookupKey)

        // Dakuten must not be folded away (が ≠ か).
        XCTAssertNotEqual(TrackInfo.normalize("がく"), TrackInfo.normalize("かく"))
    }

    func testDisplayFallsBackToOriginalWhenRomanizationMissing() {
        let lyrics = Lyrics(track: TrackInfo(title: "t", artist: "a"), language: .korean,
                            original: LyricText(plain: "사랑해"), source: .lrclib)
        XCTAssertTrue(lyrics.isMissingRomanization)
        XCTAssertEqual(lyrics.displayLines(.romanized).map(\.primary), ["사랑해"])
        XCTAssertEqual(lyrics.displayLines(.both).map(\.secondary), [nil])
    }

    func testAssemblerPrefersSourceRomanization() {
        let fetched = FetchedLyrics(source: .netease,
                                    original: LyricText(plain: "君が好き"),
                                    romanized: LyricText(plain: "kimi ga suki"))
        let lyrics = LyricsAssembler.assemble(fetched, for: TrackInfo(title: "t", artist: "a"), romanizer: Romanizer())
        XCTAssertEqual(lyrics.language, .japanese)
        XCTAssertEqual(lyrics.romanizationOrigin, .source)
        XCTAssertEqual(lyrics.romanized?.plain, "kimi ga suki")
    }

    func testAssemblerGeneratesRomanizationWhenMissing() {
        let fetched = FetchedLyrics(source: .lrclib, original: LyricText(plain: "사랑해"))
        let lyrics = LyricsAssembler.assemble(fetched, for: TrackInfo(title: "t", artist: "a"), romanizer: Romanizer())
        XCTAssertEqual(lyrics.romanizationOrigin, .generated)
        XCTAssertEqual(lyrics.romanized?.plain, "saranghae")
    }

    func testErrorSummary() {
        XCTAssertEqual(LyricsAPIClient.summarize([.lrclib: .notFound, .localFile: .notFound]), .notFound)
        XCTAssertEqual(LyricsAPIClient.summarize([.localFile: .notFound, .lrclib: .offline]), .offline)
        let limited = LiricError.rateLimited(.lrclib, retryAfter: 10)
        XCTAssertEqual(LyricsAPIClient.summarize([.localFile: .notFound, .lrclib: limited]), limited)
    }

    func testFilenameGuessing() {
        let url = URL(fileURLWithPath: "/Music/IU/Palette/03 - IU - Palette.flac")
        let guess = MetadataReader.guessFromPath(url)
        XCTAssertEqual(guess.title, "Palette")
        XCTAssertEqual(guess.artist, "IU")
    }
}
