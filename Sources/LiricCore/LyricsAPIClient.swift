//
//  LyricsAPIClient.swift
//  LiricCore
//
//  Multi-source lyric fetching with rate limiting, retries and graceful degradation.
//
//  Source strategy (see README › "Lyric API recommendation" for the full comparison)
//  ---------------------------------------------------------------------------------
//  1. LocalFileSource  – sidecar `Song.lrc` next to the audio file, or lyrics embedded in
//                        its tags (ID3 USLT / iTunes ©lyr). Free, offline, exact match.
//                        VOX users mostly play local files, so this hits more than you'd think.
//  2. LRCLIB           – https://lrclib.net. Free, no API key, open database, synced LRC.
//                        Excellent Western coverage, good mainstream K-pop/J-pop coverage.
//                        The backbone: it's the only free source that is official AND stable.
//                        No romanization (by design: one entry per recording).
//  3. NetEase (opt-in) – unofficial music.163.com endpoints. Best free coverage of J-pop and
//                        K-pop, and the only free source of *human-written* romaji
//                        (`romalrc`) + translations. Off by default because it's undocumented,
//                        can change or geo-block at any time, and its ToS don't grant API use.
//
//  Ordering: when the title/artist look Korean or Japanese we try NetEase (if enabled)
//  before LRCLIB, because one NetEase hit gives lyrics *and* romanization in a single call.
//  Otherwise LRCLIB goes first. If the winning source had no romanization for a ko/ja song,
//  NetEase is asked for romanization only; if that also fails, `Romanizer` generates one
//  on-device (in LyricsService), so the user always gets *something*.
//
//  Not used:
//  • Musixmatch – free tier returns only 30 % of each lyric; full text is a paid licence.
//  • Genius     – the API doesn't return lyric text; getting it means HTML scraping, which
//                 their ToS forbid. (Their "Genius Romanizations" pages are great, though.)
//

import AVFoundation
import Foundation

// MARK: - Source abstraction

/// What a single source returned. Any field may be nil; `LyricsAssembler` fills gaps.
public struct FetchedLyrics: Sendable, Equatable {
    public var source: LyricSourceID
    public var original: LyricText?
    public var romanized: LyricText?
    public var translation: LyricText?
    public var isInstrumental: Bool

    public init(source: LyricSourceID, original: LyricText?, romanized: LyricText? = nil,
                translation: LyricText? = nil, isInstrumental: Bool = false) {
        self.source = source
        self.original = original
        self.romanized = romanized
        self.translation = translation
        self.isInstrumental = isInstrumental
    }
}

public protocol LyricsSource: Sendable {
    var id: LyricSourceID { get }
    /// Remote sources go through the rate limiter and are skipped entirely when offline.
    var isRemote: Bool { get }
    /// Minimum spacing between two requests to this source (politeness / anti-abuse).
    var minimumRequestInterval: TimeInterval { get }
    /// Throws `LiricError.notFound` when the source simply has no lyrics.
    func fetch(_ track: TrackInfo, http: HTTPClient) async throws -> FetchedLyrics
}

// MARK: - Client

public actor LyricsAPIClient {
    public struct Configuration: Sendable {
        public var enableLocalFiles: Bool
        /// Unofficial endpoint; see header comment. Enable for human romaji/romaja.
        public var enableNetEase: Bool

        public init(enableLocalFiles: Bool = true, enableNetEase: Bool = false) {
            self.enableLocalFiles = enableLocalFiles
            self.enableNetEase = enableNetEase
        }
    }

    private let http: HTTPClient
    private let limiter = RateLimiter()
    private let localSource: LocalFileSource?
    private let lrclib: LRCLibSource
    private let netease: NetEaseSource?

    public init(configuration: Configuration = Configuration(), http: HTTPClient = HTTPClient()) {
        self.http = http
        self.localSource = configuration.enableLocalFiles ? LocalFileSource() : nil
        self.lrclib = LRCLibSource()
        self.netease = configuration.enableNetEase ? NetEaseSource() : nil
    }

    /// Fetches lyrics from the best available source.
    ///
    /// - Throws: `.notFound` if every source answered "no lyrics";
    ///           `.offline` if we couldn't reach anything remote;
    ///           `.rateLimited` if the only real failure was a rate limit;
    ///           `.allSourcesFailed` for mixed failures.
    public func fetch(_ track: TrackInfo) async throws -> FetchedLyrics {
        let hint = LanguageDetector.detect("\(track.title) \(track.artist)")
        var errors: [LyricSourceID: LiricError] = [:]
        var tried: Set<LyricSourceID> = []

        for source in orderedSources(hint: hint, track: track) {
            tried.insert(source.id)
            do {
                let result = try await run(source, track)
                guard result.isInstrumental || result.original.map({ !$0.isEmpty }) == true else {
                    throw LiricError.notFound
                }
                return await supplementRomanization(result, track: track, tried: tried)
            } catch let error as CancellationError {
                throw error
            } catch let error as LiricError {
                errors[source.id] = error
                // Every remote source will fail the same way; don't waste time.
                if error == .offline { break }
            } catch {
                errors[source.id] = .decoding(source.id)
            }
        }
        throw Self.summarize(errors)
    }

    // MARK: Internals

    private func orderedSources(hint: LyricLanguage, track: TrackInfo) -> [any LyricsSource] {
        var sources: [any LyricsSource] = []
        if let localSource, track.fileURL != nil { sources.append(localSource) }
        if hint.needsRomanization, let netease {
            sources += [netease, lrclib]
        } else {
            sources.append(lrclib)
            if let netease { sources.append(netease) }
        }
        return sources
    }

    private func run(_ source: any LyricsSource, _ track: TrackInfo) async throws -> FetchedLyrics {
        if source.isRemote {
            try await limiter.acquire(source.id, spacing: source.minimumRequestInterval)
        }
        do {
            return try await source.fetch(track, http: http)
        } catch LiricError.rateLimited(let id, let retryAfter) {
            // Back off this source for a while; other sources keep working.
            await limiter.penalize(id, retryAfter: retryAfter)
            throw LiricError.rateLimited(id, retryAfter: retryAfter)
        }
    }

    /// For Korean/Japanese songs without romanization, ask NetEase for a human one.
    /// Best effort: any failure just returns the original result (on-device fallback later).
    private func supplementRomanization(_ result: FetchedLyrics, track: TrackInfo,
                                        tried: Set<LyricSourceID>) async -> FetchedLyrics {
        guard result.romanized == nil, let original = result.original,
              let netease, !tried.contains(.netease),
              LanguageDetector.detect(original.plain).needsRomanization else { return result }

        guard let extra = try? await run(netease, track), let romanized = extra.romanized,
              !romanized.isEmpty else { return result }
        var merged = result
        merged.romanized = romanized
        merged.translation = merged.translation ?? extra.translation
        return merged
    }

    static func summarize(_ errors: [LyricSourceID: LiricError]) -> LiricError {
        let failures = errors.filter { $0.value != .notFound }
        if failures.isEmpty { return .notFound }
        if failures.values.allSatisfy({ $0 == .offline }) { return .offline }
        if failures.count == 1, let only = failures.values.first { return only }
        return .allSourcesFailed(errors)
    }
}

// MARK: - HTTP

/// Thin URLSession wrapper: timeouts, User-Agent, status → `LiricError` mapping, and
/// bounded retries with exponential backoff for transient failures.
public final class HTTPClient: Sendable {
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = "Liric/0.1 (https://github.com/rchvingt/liric)",
                timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        // Our SQLite cache is the cache; skip URLCache to keep memory/disk footprint low.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        // Fail fast when offline so the UI can fall back to cached lyrics immediately.
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
    }

    public func get(_ url: URL, source: LyricSourceID, headers: [String: String] = [:],
                    maxRetries: Int = 2) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await performOnce(url, source: source, headers: headers)
            } catch let error as LiricError where Self.isRetryable(error) && attempt < maxRetries {
                attempt += 1
                let delay = 0.5 * pow(2, Double(attempt - 1)) // 0.5 s, 1 s
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func getJSON<T: Decodable>(_ type: T.Type, from url: URL, source: LyricSourceID,
                                      headers: [String: String] = [:]) async throws -> T {
        let data = try await get(url, source: source, headers: headers)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LiricError.decoding(source)
        }
    }

    /// Timeouts / dropped connections / 5xx are worth retrying immediately.
    /// Rate limits are not (the limiter handles them), and neither is "offline".
    private static func isRetryable(_ error: LiricError) -> Bool {
        switch error {
        case .network: return true
        case let .badResponse(_, status): return status >= 500
        default: return false
        }
    }

    private func performOnce(_ url: URL, source: LyricSourceID, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                throw LiricError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw LiricError.network(source, code: error.code.rawValue)
            }
        }

        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw LiricError.badResponse(source, status: -1)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 404:
            throw LiricError.notFound
        case 429:
            throw LiricError.rateLimited(source, retryAfter: Self.retryAfter(http))
        case 503 where http.value(forHTTPHeaderField: "Retry-After") != nil:
            throw LiricError.rateLimited(source, retryAfter: Self.retryAfter(http))
        default:
            throw LiricError.badResponse(source, status: http.statusCode)
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return seconds }
        // HTTP-date form
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

// MARK: - Rate limiting

/// Per-source request spacing + cool-down after 429s.
///
/// When a source is cooling down we throw immediately instead of waiting, so the client
/// moves on to the next source and the UI never hangs behind a rate limit.
actor RateLimiter {
    private var nextSlot: [LyricSourceID: Date] = [:]
    private var cooldownUntil: [LyricSourceID: Date] = [:]

    func acquire(_ id: LyricSourceID, spacing: TimeInterval) async throws {
        let now = Date()
        if let until = cooldownUntil[id], until > now {
            throw LiricError.rateLimited(id, retryAfter: until.timeIntervalSince(now))
        }
        // Reserve the slot *before* sleeping so concurrent callers queue up correctly
        // (actor re-entrancy).
        let slot = max(now, nextSlot[id] ?? now)
        nextSlot[id] = slot.addingTimeInterval(spacing)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    func penalize(_ id: LyricSourceID, retryAfter: TimeInterval?) {
        // Respect Retry-After, but clamp: at least 5 s, at most 1 h; default 60 s.
        let backoff = min(max(retryAfter ?? 60, 5), 3600)
        cooldownUntil[id] = Date().addingTimeInterval(backoff)
    }
}

// MARK: - Local files (.lrc sidecar / embedded tags)

struct LocalFileSource: LyricsSource {
    let id = LyricSourceID.localFile
    let isRemote = false
    let minimumRequestInterval: TimeInterval = 0

    func fetch(_ track: TrackInfo, http: HTTPClient) async throws -> FetchedLyrics {
        guard let url = track.fileURL else { throw LiricError.notFound }

        // 1. Sidecar "Song.lrc" (also covers "Song.txt" for plain lyrics).
        for ext in ["lrc", "txt"] {
            let sidecar = url.deletingPathExtension().appendingPathExtension(ext)
            if let text = Self.readText(sidecar), !text.isEmpty {
                return FetchedLyrics(source: id, original: LyricText(lrc: text))
            }
        }

        // 2. Lyrics embedded in tags. AVFoundation can't read Ogg/APE/WavPack tags; those
        //    just fall through to the remote sources.
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { throw LiricError.notFound }
        let lyricIDs: Set<AVMetadataIdentifier> = [.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics]
        for item in items where item.identifier.map({ lyricIDs.contains($0) }) == true {
            if let value = try? await item.load(.stringValue),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return FetchedLyrics(source: id, original: LyricText(lrc: value))
            }
        }
        throw LiricError.notFound
    }

    /// Old .lrc files from K/J lyric sites are often EUC-KR or Shift-JIS, not UTF-8.
    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        for encoding: String.Encoding in [.utf8, .utf16, .shiftJIS, eucKR, .japaneseEUC] {
            if let text = String(data: data, encoding: encoding) {
                return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            }
        }
        return nil
    }
}

// MARK: - LRCLIB

/// https://lrclib.net/docs — free, no key. Asks clients to send a descriptive User-Agent.
struct LRCLibSource: LyricsSource {
    let id = LyricSourceID.lrclib
    let isRemote = true
    let minimumRequestInterval: TimeInterval = 0.25

    private struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let base = URL(string: "https://lrclib.net/api")!

    func fetch(_ track: TrackInfo, http: HTTPClient) async throws -> FetchedLyrics {
        // 1. Exact signature lookup (cheapest for the server) when we know album + duration.
        if let album = track.album, let duration = track.duration {
            let url = Self.url("get", [
                "track_name": track.title,
                "artist_name": track.artist,
                "album_name": album,
                "duration": String(Int(duration.rounded())),
            ])
            do {
                let record = try await http.getJSON(Record.self, from: url, source: id)
                if let result = convert(record) { return result }
            } catch LiricError.notFound {
                // Album names differ between releases — fall back to search.
            }
        }

        // 2. Search by title + artist, then pick the closest duration.
        let url = Self.url("search", ["track_name": track.title, "artist_name": track.artist])
        let records = try await http.getJSON([Record].self, from: url, source: id)
        guard let best = Self.bestMatch(records, for: track), let result = convert(best) else {
            throw LiricError.notFound
        }
        return result
    }

    private func convert(_ record: Record) -> FetchedLyrics? {
        if record.instrumental == true {
            return FetchedLyrics(source: id, original: nil, isInstrumental: true)
        }
        let synced = record.syncedLyrics.flatMap { $0.isEmpty ? nil : $0 }
        let plain = record.plainLyrics.flatMap { $0.isEmpty ? nil : $0 }
        if let synced {
            var text = LyricText(lrc: synced)
            if let plain { text.plain = plain }
            return FetchedLyrics(source: id, original: text)
        }
        if let plain {
            return FetchedLyrics(source: id, original: LyricText(plain: plain))
        }
        return nil
    }

    private static func bestMatch(_ records: [Record], for track: TrackInfo) -> Record? {
        func score(_ r: Record) -> Double {
            var s = 0.0
            if r.syncedLyrics?.isEmpty == false { s += 2 } else if r.plainLyrics?.isEmpty == false { s += 1 }
            if let a = track.duration, let b = r.duration { s -= abs(a - b) / 2 }
            if TrackInfo.normalize(r.trackName ?? "") == TrackInfo.normalize(track.title) { s += 1 }
            return s
        }
        let candidates = records.filter { r in
            // ±4 s tolerates different encodes; more usually means a live/remix version.
            if let a = track.duration, let b = r.duration { return abs(a - b) <= 4 }
            return true
        }
        return candidates.max { score($0) < score($1) }
    }

    private static func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}

// MARK: - NetEase Cloud Music (unofficial, opt-in)

struct NetEaseSource: LyricsSource {
    let id = LyricSourceID.netease
    let isRemote = true
    // Undocumented API with aggressive anti-crawling: be very polite.
    let minimumRequestInterval: TimeInterval = 1.0

    private static let headers = ["Referer": "https://music.163.com/"]

    private struct SearchResponse: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String }
            let id: Int
            let name: String
            let duration: Int? // ms
            let artists: [Artist]?
        }
        let code: Int
        let result: Result?
    }

    private struct LyricResponse: Decodable {
        struct Body: Decodable { let lyric: String? }
        let code: Int
        let lrc: Body?
        let tlyric: Body?   // translation (usually Chinese)
        let romalrc: Body?  // human romanization (romaji, sometimes romaja)
        let nolyric: Bool?
        let uncollected: Bool?
    }

    func fetch(_ track: TrackInfo, http: HTTPClient) async throws -> FetchedLyrics {
        var search = URLComponents(string: "https://music.163.com/api/search/get")!
        search.queryItems = [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        let found = try await http.getJSON(SearchResponse.self, from: search.url!, source: id, headers: Self.headers)
        try checkCode(found.code)
        guard let song = Self.bestMatch(found.result?.songs ?? [], for: track) else {
            throw LiricError.notFound
        }

        var lyric = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyric.queryItems = [
            URLQueryItem(name: "id", value: String(song.id)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "rv", value: "-1"),
        ]
        let body = try await http.getJSON(LyricResponse.self, from: lyric.url!, source: id, headers: Self.headers)
        try checkCode(body.code)

        if body.nolyric == true {
            return FetchedLyrics(source: id, original: nil, isInstrumental: true)
        }
        guard let original = Self.clean(body.lrc?.lyric) else { throw LiricError.notFound }
        if original.plain.contains("纯音乐") { // "pure music, please enjoy"
            return FetchedLyrics(source: id, original: nil, isInstrumental: true)
        }
        return FetchedLyrics(source: id, original: original,
                             romanized: Self.clean(body.romalrc?.lyric),
                             translation: Self.clean(body.tlyric?.lyric))
    }

    private func checkCode(_ code: Int) throws {
        switch code {
        case 200: return
        case -460, -462, 405: // anti-crawl / "too frequent"
            throw LiricError.rateLimited(id, retryAfter: 600)
        default:
            throw LiricError.badResponse(id, status: code)
        }
    }

    private static func bestMatch(_ songs: [SearchResponse.Song], for track: TrackInfo) -> SearchResponse.Song? {
        let title = TrackInfo.normalize(track.title)
        return songs.first { song in
            let titleOK = TrackInfo.normalize(song.name).contains(title) || title.contains(TrackInfo.normalize(song.name))
            guard titleOK else { return false }
            if let a = track.duration, let ms = song.duration { return abs(a - Double(ms) / 1000) <= 4 }
            return true
        }
    }

    /// NetEase prefixes lyrics with credit lines ("作词 : …"); drop them.
    private static let creditPattern = try! NSRegularExpression(
        pattern: #"^\s*(作词|作曲|编曲|制作人|作詞|編曲|製作|和声|混音|母带|录音|监制|Lyrics|Composer|Arranger)\s*[:：]"#,
        options: [.caseInsensitive])

    private static func clean(_ lrc: String?) -> LyricText? {
        guard let lrc, !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = LRC.parse(lrc).filter { line in
            let range = NSRange(line.text.startIndex..., in: line.text)
            return creditPattern.firstMatch(in: line.text, range: range) == nil
        }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return LyricText(lrc: LRC.serialize(lines))
    }
}
