@testable import LiricCore
import XCTest

final class LocalStorageManagerTests: XCTestCase {
    private func makeLyrics(_ title: String, romanized: Bool = true) -> Lyrics {
        Lyrics(track: TrackInfo(title: title, artist: "IU", album: "Palette", duration: 217),
               language: .korean,
               original: LyricText(lrc: "[00:01.00]이상하게도"),
               romanized: romanized ? LyricText(lrc: "[00:01.00]isanghagedo") : nil,
               romanizationOrigin: romanized ? .generated : nil,
               source: .lrclib)
    }

    func testRoundTripKeepsAllVariants() async throws {
        let store = try LocalStorageManager(location: .inMemory)
        let lyrics = makeLyrics("Palette")
        try await store.save(lyrics)

        let loaded = try await store.lyrics(for: lyrics.track)
        XCTAssertEqual(loaded?.original, lyrics.original)
        XCTAssertEqual(loaded?.romanized, lyrics.romanized)
        XCTAssertEqual(loaded?.romanizationOrigin, .generated)
        XCTAssertEqual(loaded?.language, .korean)
    }

    func testSaveReplacesVariants() async throws {
        let store = try LocalStorageManager(location: .inMemory)
        try await store.save(makeLyrics("Palette"))
        try await store.save(makeLyrics("Palette", romanized: false))
        let loaded = try await store.lyrics(for: TrackInfo(title: "Palette", artist: "IU"))
        XCTAssertNil(loaded?.romanized)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testMissCache() async throws {
        let store = try LocalStorageManager(location: .inMemory)
        let track = TrackInfo(title: "Unknown", artist: "Nobody")
        var miss = try await store.isRecentMiss(track)
        XCTAssertFalse(miss)
        try await store.recordMiss(track)
        miss = try await store.isRecentMiss(track)
        XCTAssertTrue(miss)
    }

    func testPruneKeepsMostRecentlyUsed() async throws {
        let store = try LocalStorageManager(location: .inMemory, maxEntries: 2)
        for title in ["A", "B", "C"] {
            try await store.save(makeLyrics(title))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await store.prune()
        let count = try await store.count()
        XCTAssertEqual(count, 2)
        let oldest = try await store.lyrics(for: TrackInfo(title: "A", artist: "IU"))
        XCTAssertNil(oldest)
    }
}
