//
//  LyricsService.swift
//  LiricCore
//
//  Glue between VOXPlayerMonitor → LocalStorageManager → LyricsAPIClient → Romanizer,
//  exposing one observable `status` for the UI.
//
//  Degradation ladder for every track change:
//    1. Cache hit                       → show immediately (works offline).
//    2. Cached "miss" within 7 days     → "No lyrics" without touching the network.
//    3. Fetch (local file → LRCLIB/NetEase)
//         ok        → romanize if needed → save → show
//         not found → remember the miss  → "No lyrics"
//         offline / network / 5xx → message + retry with backoff (5 s, 10 s, 20 s)
//         rate limited            → message + retry after Retry-After (≤ 5 min)
//    4. Romanization: human (source) → on-device (Romanizer) → none, in which case the UI
//       shows the original text with a notice (never a blank screen).
//

import Foundation

@MainActor
public final class LyricsService: ObservableObject {
    public enum Status: Equatable {
        case waitingForPlayer
        case idle
        case loading(TrackInfo)
        case loaded(Lyrics, notice: String?)
        case instrumental(TrackInfo)
        case notFound(TrackInfo)
        case failed(TrackInfo?, message: String)
    }

    @Published public private(set) var status: Status = .waitingForPlayer
    @Published public var displayMode: Lyrics.DisplayMode = .both
    /// Monitor warnings (e.g. Automation permission) for the UI.
    @Published public private(set) var playerWarning: String?

    public let monitor: VOXPlayerMonitor
    private let api: LyricsAPIClient
    private let storage: LocalStorageManager?
    private let romanizer: Romanizer
    private let maxRetries = 3

    private var currentTrack: TrackInfo?
    private var loadTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    public init(monitor: VOXPlayerMonitor, api: LyricsAPIClient,
                storage: LocalStorageManager?, romanizer: Romanizer = Romanizer()) {
        self.monitor = monitor
        self.api = api
        self.storage = storage
        self.romanizer = romanizer
    }

    /// Production wiring. If the on-disk cache can't be opened (disk full, permissions),
    /// we keep working with an in-memory cache rather than failing to launch.
    public convenience init(enableNetEase: Bool = false) {
        let storage = (try? LocalStorageManager()) ?? (try? LocalStorageManager(location: .inMemory))
        self.init(monitor: VOXPlayerMonitor(),
                  api: LyricsAPIClient(configuration: .init(enableNetEase: enableNetEase)),
                  storage: storage)
    }

    public func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let updates = self?.monitor.updates() else { return }
            for await state in updates {
                self?.handle(state)
            }
        }
        monitor.start()
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        loadTask?.cancel()
        monitor.stop()
    }

    /// Re-fetch the current track, ignoring cached misses (e.g. a "Retry" button).
    public func retry() {
        guard let track = currentTrack else { return }
        load(track, skipMissCache: true)
    }

    // MARK: State handling

    private func handle(_ state: VOXPlayerMonitor.State) {
        playerWarning = monitor.lastError?.errorDescription
        switch state {
        case .playerNotRunning:
            reset(to: .waitingForPlayer)
        case .noTrack:
            reset(to: .idle)
        case let .nowPlaying(track):
            guard track.lookupKey != currentTrack?.lookupKey else { return }
            currentTrack = track
            load(track, skipMissCache: false)
        }
    }

    private func reset(to newStatus: Status) {
        loadTask?.cancel()
        loadTask = nil
        currentTrack = nil
        status = newStatus
    }

    private func load(_ track: TrackInfo, skipMissCache: Bool) {
        loadTask?.cancel()
        status = .loading(track)
        loadTask = Task { [weak self] in
            await self?.resolve(track, attempt: 0, skipMissCache: skipMissCache)
        }
    }

    private func resolve(_ track: TrackInfo, attempt: Int, skipMissCache: Bool) async {
        // 1. Cache
        if let storage, let cached = try? await storage.lyrics(for: track) {
            let lyrics = await backfillRomanization(cached)
            publish(lyrics.isInstrumental ? .instrumental(track) : .loaded(lyrics, notice: Self.notice(for: lyrics)),
                    for: track)
            return
        }
        // 2. Known miss
        if !skipMissCache, let storage, (try? await storage.isRecentMiss(track)) == true {
            publish(.notFound(track), for: track)
            return
        }
        // 3. Fetch
        do {
            let fetched = try await api.fetch(track)
            let romanizer = self.romanizer
            // Romanizing a whole song is a few ms of CPU — keep it off the main thread.
            let lyrics = await Task.detached(priority: .utility) {
                LyricsAssembler.assemble(fetched, for: track, romanizer: romanizer)
            }.value
            try? await storage?.save(lyrics) // cache failure must not hide the lyrics
            publish(lyrics.isInstrumental ? .instrumental(track) : .loaded(lyrics, notice: Self.notice(for: lyrics)),
                    for: track)
        } catch is CancellationError {
            return
        } catch let error as LiricError {
            await handleFailure(error, track: track, attempt: attempt)
        } catch {
            publish(.failed(track, message: error.localizedDescription), for: track)
        }
    }

    private func handleFailure(_ error: LiricError, track: TrackInfo, attempt: Int) async {
        if error == .notFound {
            try? await storage?.recordMiss(track)
            publish(.notFound(track), for: track)
            return
        }
        guard error.isTransient, attempt < maxRetries else {
            publish(.failed(track, message: error.errorDescription ?? "Couldn't load lyrics."), for: track)
            return
        }

        let delay: TimeInterval
        let message: String
        if case let .rateLimited(_, retryAfter) = error {
            delay = min(max(retryAfter ?? 30, 5), 300)
            message = "Lyric sources are busy (rate limited). Retrying in \(Int(delay))s…"
        } else {
            delay = 5 * pow(2, Double(attempt)) // 5, 10, 20 s
            message = error == .offline
                ? "Offline — will retry in \(Int(delay))s."
                : "Couldn't reach lyric sources. Retrying in \(Int(delay))s…"
        }
        publish(.failed(track, message: message), for: track)

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled, currentTrack?.lookupKey == track.lookupKey else { return }
        await resolve(track, attempt: attempt + 1, skipMissCache: true)
    }

    /// Rows cached before a romanization was possible (or before the romanizer improved)
    /// get one generated lazily, and the cache is updated.
    private func backfillRomanization(_ lyrics: Lyrics) async -> Lyrics {
        guard lyrics.isMissingRomanization else { return lyrics }
        let romanizer = self.romanizer
        let updated = await Task.detached(priority: .utility) { () -> Lyrics in
            var copy = lyrics
            if let generated = romanizer.romanize(lyrics.original, language: lyrics.language) {
                copy.romanized = generated
                copy.romanizationOrigin = .generated
            }
            return copy
        }.value
        if updated.romanized != nil { try? await storage?.save(updated) }
        return updated
    }

    /// Only publish results for the track that's still current.
    private func publish(_ newStatus: Status, for track: TrackInfo) {
        guard !Task.isCancelled, currentTrack?.lookupKey == track.lookupKey else { return }
        status = newStatus
    }

    static func notice(for lyrics: Lyrics) -> String? {
        guard lyrics.language.needsRomanization, let name = lyrics.language.romanizationName else { return nil }
        switch lyrics.romanizationOrigin {
        case nil:
            return "\(name) unavailable — showing original lyrics."
        case .generated?:
            return "\(name) generated on-device; readings may differ from the official version."
        case .source?:
            return nil
        }
    }
}

// MARK: - Assembly (pure, testable)

public enum LyricsAssembler {
    /// Turns a raw source result into a `Lyrics` value with language + romanization.
    ///
    /// Language is detected from the *lyrics* (titles of K-pop songs are often English).
    /// Romanization preference: human (from source) → on-device → nil (UI shows original).
    public static func assemble(_ fetched: FetchedLyrics, for track: TrackInfo,
                                romanizer: Romanizer, now: Date = Date()) -> Lyrics {
        let original = fetched.original ?? LyricText(plain: "")
        let language = original.isEmpty ? .undetermined : LanguageDetector.detect(original.plain)

        var romanized: LyricText?
        var origin: RomanizationOrigin?
        if language.needsRomanization {
            if let provided = fetched.romanized, !provided.isEmpty {
                romanized = provided
                origin = .source
            } else if let generated = romanizer.romanize(original, language: language) {
                romanized = generated
                origin = .generated
            }
        }

        return Lyrics(track: track, language: language, original: original,
                      romanized: romanized, romanizationOrigin: origin,
                      translation: fetched.translation,
                      isInstrumental: fetched.isInstrumental && original.isEmpty,
                      source: fetched.source, fetchedAt: now)
    }
}
