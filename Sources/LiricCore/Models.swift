//
//  Models.swift
//  LiricCore
//
//  Core value types shared by the player monitor, the API layer and storage.
//
//  Design notes
//  ------------
//  • Everything is a plain `Sendable` struct/enum so it can cross actor boundaries
//    freely (monitor = MainActor, API client + storage = their own actors).
//  • A song's lyrics are modelled as *variants* of one body of text:
//        original   – Korean / Japanese / English as published
//        romanized  – Romaja (ko) or Romaji (ja); nil for Latin-script songs
//        translation– optional (NetEase ships Chinese/English translations)
//    Each variant keeps both plain text and, when available, LRC-synced text, so the
//    UI can do karaoke-style highlighting later without another fetch.
//  • `romanizationOrigin` records whether a romanization was written by a human
//    (from the lyric source) or generated on-device. The UI uses it to show a
//    "generated, may be inaccurate" hint, and storage uses it to prefer human
//    versions when re-fetching.
//

import Foundation

// MARK: - Language

/// Language of a lyric body. Raw values are BCP-47 tags so they can be stored in
/// SQLite as-is and handed to NaturalLanguage / CFStringTokenizer.
public enum LyricLanguage: String, Codable, Sendable, CaseIterable {
    case korean = "ko"
    case japanese = "ja"
    case english = "en"
    /// Anything else (Spanish, Chinese, unknown, empty). Shown as-is, never romanized.
    case undetermined = "und"

    /// Only non-Latin scripts get a romanized variant.
    public var needsRomanization: Bool {
        self == .korean || self == .japanese
    }

    /// User-facing name of the romanization system for this language.
    public var romanizationName: String? {
        switch self {
        case .korean: return "Romaja"
        case .japanese: return "Romaji"
        case .english, .undetermined: return nil
        }
    }
}

// MARK: - Track

/// What is currently playing in VOX, as far as we could tell.
public struct TrackInfo: Hashable, Codable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds. Used to pick the right version (radio edit vs. album cut) when matching.
    public var duration: TimeInterval?
    /// Local audio file VOX has open, if any (nil for streams / VOX Radio).
    public var fileURL: URL?

    public init(title: String, artist: String, album: String? = nil,
                duration: TimeInterval? = nil, fileURL: URL? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.fileURL = fileURL
    }

    /// Stable cache key: normalized `artist|title`.
    public var lookupKey: String {
        "\(Self.normalize(artist))|\(Self.normalize(title))"
    }

    /// Normalizes a title/artist for matching and caching.
    ///
    /// Deliberately conservative:
    /// - NFKC folds full-width Latin ("ＢＴＳ") and half-width katakana.
    /// - We do NOT use `.diacriticInsensitive` folding: it strips the dakuten from kana
    ///   (が → か) and would merge different Japanese titles.
    /// - We strip "(feat. …)" and "Remastered" qualifiers, but keep "(Japanese ver.)",
    ///   "(Korean ver.)" etc. — K-pop acts release the same title in several languages
    ///   with *different* lyrics, and those must not share a cache entry.
    public static func normalize(_ value: String) -> String {
        var s = value.precomposedStringWithCompatibilityMapping.lowercased()
        let patterns = [
            #"\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
            #"\s*[\(\[][^\)\]]*remaster(ed)?[^\)\]]*[\)\]]"#,
            #"\s+-\s+(\d{4}\s+)?remaster(ed)?.*$"#,
            #"\s*[\(\[](explicit|clean)[\)\]]"#,
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Lyric text

/// One line of lyrics, optionally time-stamped (from LRC).
public struct LyricLine: Hashable, Codable, Sendable {
    public var time: TimeInterval?
    public var text: String

    public init(time: TimeInterval?, text: String) {
        self.time = time
        self.text = text
    }
}

/// One variant of a song's lyrics (original, romanized or translated).
public struct LyricText: Hashable, Codable, Sendable {
    /// Unsynced text, newline separated. Always present (may be derived from `synced`).
    public var plain: String
    /// LRC text (`[mm:ss.xx]line`) when the source provides timing.
    public var synced: String?

    public init(plain: String, synced: String? = nil) {
        self.plain = plain
        self.synced = synced
    }

    /// Builds a variant from an LRC string, deriving the plain text from it.
    public init(lrc: String) {
        let lines = LRC.parse(lrc)
        if lines.isEmpty {
            // Not actually LRC — treat as plain text.
            self.init(plain: lrc, synced: nil)
        } else {
            self.init(plain: lines.map(\.text).joined(separator: "\n"), synced: lrc)
        }
    }

    public var isEmpty: Bool {
        plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Synced lines if available, otherwise plain lines without timestamps.
    public var lines: [LyricLine] {
        if let synced {
            let parsed = LRC.parse(synced)
            if !parsed.isEmpty { return parsed }
        }
        return plain
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { LyricLine(time: nil, text: $0) }
    }
}

public enum LyricVariantKind: String, Codable, Sendable, CaseIterable {
    case original
    case romanized
    case translation
}

public enum RomanizationOrigin: String, Codable, Sendable {
    /// Written by a human and supplied by the lyric source (best quality).
    case source
    /// Generated on-device by `Romanizer` (always available, may misread kanji).
    case generated
}

/// Where a set of lyrics came from.
public enum LyricSourceID: String, Codable, Sendable, CaseIterable {
    /// Sidecar `.lrc` file or lyrics embedded in the audio file's tags.
    case localFile = "local"
    /// https://lrclib.net — free, open, no API key.
    case lrclib
    /// NetEase Cloud Music (unofficial endpoint) — opt-in; best source of human romaji.
    case netease
}

// MARK: - Lyrics

/// A song's lyrics with all of its variants.
public struct Lyrics: Hashable, Codable, Sendable {
    public var track: TrackInfo
    /// Language of the *original* text (detected from the lyrics, not the title).
    public var language: LyricLanguage
    public var original: LyricText
    /// nil when the song is Latin-script, or when romanization was impossible
    /// (callers fall back to `original` — see `displayLines(_:)`).
    public var romanized: LyricText?
    public var romanizationOrigin: RomanizationOrigin?
    public var translation: LyricText?
    public var isInstrumental: Bool
    public var source: LyricSourceID
    public var fetchedAt: Date

    public init(track: TrackInfo, language: LyricLanguage, original: LyricText,
                romanized: LyricText? = nil, romanizationOrigin: RomanizationOrigin? = nil,
                translation: LyricText? = nil, isInstrumental: Bool = false,
                source: LyricSourceID, fetchedAt: Date = Date()) {
        self.track = track
        self.language = language
        self.original = original
        self.romanized = romanized
        self.romanizationOrigin = romanizationOrigin
        self.translation = translation
        self.isInstrumental = isInstrumental
        self.source = source
        self.fetchedAt = fetchedAt
    }

    /// True when the song should have a romanization but none could be produced.
    public var isMissingRomanization: Bool {
        language.needsRomanization && romanized == nil && !original.isEmpty
    }

    public enum DisplayMode: String, CaseIterable, Sendable {
        case original
        case romanized
        /// Original line with the romanization underneath.
        case both
    }

    /// Lines ready for display. Missing romanization always falls back to the original.
    public func displayLines(_ mode: DisplayMode) -> [DisplayLine] {
        let originalLines = original.lines
        let romanLines = romanized?.lines

        switch mode {
        case .original:
            return Self.makeLines(originalLines, secondary: nil)
        case .romanized:
            return Self.makeLines(romanLines ?? originalLines, secondary: nil)
        case .both:
            guard let romanLines else { return Self.makeLines(originalLines, secondary: nil) }
            if romanLines.count == originalLines.count {
                return Self.makeLines(originalLines, secondary: romanLines.map(\.text))
            }
            // Human romanizations sometimes have a different line count; pair by timestamp.
            let byTime = Dictionary(
                romanLines.compactMap { line in line.time.map { (Self.timeKey($0), line.text) } },
                uniquingKeysWith: { first, _ in first }
            )
            let paired = originalLines.map { line in line.time.flatMap { byTime[Self.timeKey($0)] } }
            return Self.makeLines(originalLines, secondary: paired)
        }
    }

    private static func timeKey(_ t: TimeInterval) -> Int { Int((t * 10).rounded()) }

    private static func makeLines(_ primary: [LyricLine], secondary: [String?]?) -> [DisplayLine] {
        primary.enumerated().map { index, line in
            var sub = secondary.flatMap { index < $0.count ? $0[index] : nil }
            // English lines inside K-pop/J-pop "romanize" to themselves — don't show them twice.
            if let s = sub, s.isEmpty || s == line.text { sub = nil }
            return DisplayLine(id: index, time: line.time, primary: line.text, secondary: sub)
        }
    }
}

public struct DisplayLine: Hashable, Sendable, Identifiable {
    public let id: Int
    public let time: TimeInterval?
    public let primary: String
    public let secondary: String?
}

// MARK: - LRC

/// Minimal LRC parser/serializer (`[mm:ss.xx]text`, multiple stamps per line allowed,
/// metadata tags like `[ar:…]` ignored).
public enum LRC {
    public static func parse(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        for rawLine in lrc.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(rawLine).drop(while: { $0 == " " || $0 == "\t" })
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = parseTime(tag) else { break } // metadata tag ([ar:], [by:] …)
                stamps.append(time)
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                result.append(LyricLine(time: stamp, text: text))
            }
        }
        // Stable sort: lines with several stamps get re-ordered into song order.
        return result.enumerated()
            .sorted { ($0.element.time ?? 0, $0.offset) < ($1.element.time ?? 0, $1.offset) }
            .map(\.element)
    }

    public static func serialize(_ lines: [LyricLine]) -> String {
        lines.map { line in
            guard let time = line.time else { return line.text }
            return "[\(format(time))]\(line.text)"
        }
        .joined(separator: "\n")
    }

    public static func format(_ time: TimeInterval) -> String {
        let centiseconds = Int((max(0, time) * 100).rounded())
        return String(format: "%02d:%02d.%02d",
                      centiseconds / 6000, (centiseconds % 6000) / 100, centiseconds % 100)
    }

    static func parseTime<S: StringProtocol>(_ tag: S) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        // Accept both mm:ss.xx and the rarer mm:ss:xx.
        let secondsText = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Double(minutes) * 60 + seconds
    }
}

// MARK: - Errors

public enum LiricError: Error, Equatable, Sendable, LocalizedError {
    /// VOX isn't running. Not really an error — the UI shows a waiting state.
    case playerNotRunning
    /// The user declined "Liric wants to control VOX" (AppleScript fallback only).
    case automationDenied
    /// No source has lyrics for this track.
    case notFound
    /// HTTP 429 / provider anti-abuse response. `retryAfter` in seconds when known.
    case rateLimited(LyricSourceID, retryAfter: TimeInterval?)
    /// No network connection at all.
    case offline
    /// Transport error (timeout, DNS, TLS…). `code` is a `URLError.Code` raw value.
    case network(LyricSourceID, code: Int)
    /// Unexpected HTTP status or provider error code.
    case badResponse(LyricSourceID, status: Int)
    /// Response didn't match the expected JSON shape (API changed?).
    case decoding(LyricSourceID)
    case storage(String)
    /// Several sources failed for different reasons.
    case allSourcesFailed([LyricSourceID: LiricError])

    public var errorDescription: String? {
        switch self {
        case .playerNotRunning:
            return "VOX isn't running."
        case .automationDenied:
            return "Liric isn't allowed to control VOX. Enable it in System Settings › Privacy & Security › Automation."
        case .notFound:
            return "No lyrics found for this track."
        case let .rateLimited(source, retryAfter):
            let wait = retryAfter.map { " Try again in \(Int($0.rounded(.up)))s." } ?? ""
            return "\(source.rawValue) is rate-limiting requests.\(wait)"
        case .offline:
            return "You're offline. Showing cached lyrics only."
        case let .network(source, code):
            return "Couldn't reach \(source.rawValue) (error \(code))."
        case let .badResponse(source, status):
            return "\(source.rawValue) returned an unexpected response (\(status))."
        case let .decoding(source):
            return "\(source.rawValue) returned data Liric doesn't understand."
        case let .storage(message):
            return "Lyrics cache error: \(message)"
        case .allSourcesFailed:
            return "All lyric sources failed. Will retry shortly."
        }
    }

    /// Worth an automatic retry with backoff (as opposed to a definitive answer).
    public var isTransient: Bool {
        switch self {
        case .offline, .network, .rateLimited:
            return true
        case let .badResponse(_, status):
            return status >= 500
        case let .allSourcesFailed(errors):
            return errors.values.contains { $0.isTransient }
        case .playerNotRunning, .automationDenied, .notFound, .decoding, .storage:
            return false
        }
    }
}
