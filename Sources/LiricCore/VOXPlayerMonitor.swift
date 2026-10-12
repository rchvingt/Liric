//
//  VOXPlayerMonitor.swift
//  LiricCore
//
//  Detects what VOX Player is playing — without Music.app / MediaRemote.
//
//  Why file monitoring?
//  --------------------
//  VOX doesn't publish a "now playing" file or a documented notification, and macOS's
//  system Now Playing data lives in the private MediaRemote framework (locked down for
//  third-party apps since macOS 15.4). What VOX *does* do, like every local player, is keep
//  the audio file it's playing open. So:
//
//  1. Primary — open-file inspection (no permission prompt):
//     `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` list the
//     files VOX's process has open (the same mechanism as `lsof`). We keep the audio ones,
//     then read title/artist/album/duration from the file's tags with AVFoundation
//     (falling back to "Artist - Title.ext" / folder names for formats AVFoundation can't
//     parse, e.g. Ogg, APE). This also hands us the file URL, which enables sidecar `.lrc`
//     and embedded-lyrics lookup and exact duration matching.
//
//  2. Fallback — AppleScript (VOX has a scripting dictionary):
//     Used only when no local audio file is open (VOX Radio, streams, cloud). Costs a
//     one-time "Liric wants to control VOX" Automation prompt; if denied we stop asking
//     and surface `LiricError.automationDenied`.
//
//  Cost: when VOX isn't running we don't poll at all — NSWorkspace launch/terminate
//  notifications wake us up. While it runs, one poll every 1.5 s is a couple of syscalls
//  on a background thread; tags are re-read only when the open file changes.
//
//  Requires a non-sandboxed app (see Config/Liric.entitlements).
//

import AppKit
import AVFoundation
import Darwin
import Foundation

@MainActor
public final class VOXPlayerMonitor: ObservableObject {
    public enum State: Equatable, Sendable {
        /// VOX isn't running (the app waits for it to launch — no polling).
        case playerNotRunning
        /// VOX is running but nothing is loaded, or the track couldn't be identified.
        case noTrack
        /// A track is loaded (playing or paused — VOX keeps the file open either way).
        case nowPlaying(TrackInfo)
    }

    /// Bundle IDs to watch. Add the Setapp edition's ID here if you use that build.
    public nonisolated static let defaultBundleIdentifiers = ["com.coppertino.Vox"]

    @Published public private(set) var state: State = .playerNotRunning {
        didSet {
            guard state != oldValue else { return }
            for continuation in continuations.values { continuation.yield(state) }
        }
    }
    /// Non-fatal problems worth showing (e.g. Automation permission denied).
    @Published public private(set) var lastError: LiricError?

    public var pollInterval: TimeInterval
    public var useAppleScriptFallback: Bool
    private let bundleIdentifiers: [String]

    private var pollTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var currentPath: String?
    private var cachedMetadata: (path: String, track: TrackInfo)?
    private var appleScriptDenied = false
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]

    private lazy var appleScript: NSAppleScript? = {
        // `tell application id` never launches VOX by itself here because we only run it
        // while VOX is running. Each property is wrapped in `try` so a missing property in
        // some VOX version doesn't fail the whole query.
        let id = bundleIdentifiers.first ?? "com.coppertino.Vox"
        let source = """
        tell application id "\(id)"
            set t to ""
            set a to ""
            set al to ""
            try
                set t to track
            end try
            try
                set a to artist
            end try
            try
                set al to album
            end try
            return {t, a, al}
        end tell
        """
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }()

    public init(pollInterval: TimeInterval = 1.5,
                useAppleScriptFallback: Bool = true,
                bundleIdentifiers: [String] = VOXPlayerMonitor.defaultBundleIdentifiers) {
        self.pollInterval = pollInterval
        self.useAppleScriptFallback = useAppleScriptFallback
        self.bundleIdentifiers = bundleIdentifiers
    }

    deinit {
        pollTask?.cancel()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for continuation in continuations.values { continuation.finish() }
    }

    // MARK: Public API

    /// State changes as an async sequence (current state is delivered first).
    public func updates() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    public func start() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let ids = bundleIdentifiers
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard Self.isPlayer(note, ids: ids) else { return }
                Task { @MainActor in self?.startPolling() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard Self.isPlayer(note, ids: ids) else { return }
                Task { @MainActor in self?.playerDidQuit() }
            },
        ]
        if runningPlayer() != nil {
            startPolling()
        } else {
            state = .playerNotRunning
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
    }

    /// Forces an immediate check (e.g. from a "Refresh" button).
    public func refresh() async {
        await poll()
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func playerDidQuit() {
        pollTask?.cancel()
        pollTask = nil
        currentPath = nil
        cachedMetadata = nil
        state = .playerNotRunning
    }

    private func poll() async {
        guard let app = runningPlayer() else {
            playerDidQuit()
            return
        }
        let pid = app.processIdentifier

        // 1. Open-file inspection, off the main thread.
        let openFiles = await Task.detached(priority: .utility) {
            OpenFileInspector.audioFiles(openedBy: pid)
        }.value

        if let path = choose(openFiles) {
            currentPath = path
            let track: TrackInfo
            if let cached = cachedMetadata, cached.path == path {
                track = cached.track
            } else {
                track = await MetadataReader.track(for: URL(fileURLWithPath: path))
                cachedMetadata = (path, track)
            }
            state = .nowPlaying(track)
            return
        }
        currentPath = nil

        // 2. AppleScript fallback for streams / radio.
        if useAppleScriptFallback, !appleScriptDenied, let track = queryViaAppleScript() {
            state = .nowPlaying(track)
            return
        }
        state = .noTrack
    }

    /// Picks the playing file among VOX's open audio files.
    ///
    /// VOX pre-opens the *next* file for gapless playback, so "most recently opened" alone
    /// would jump ahead a few seconds early. Rule: stick with the current file while it's
    /// still open; otherwise take the most recently opened one (highest fd number).
    private func choose(_ files: [OpenFileInspector.OpenFile]) -> String? {
        if let currentPath, files.contains(where: { $0.path == currentPath }) {
            return currentPath
        }
        return files.max { $0.fd < $1.fd }?.path
    }

    private func runningPlayer() -> NSRunningApplication? {
        for id in bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    private nonisolated static func isPlayer(_ note: Notification, ids: [String]) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier.map { ids.contains($0) } ?? false
    }

    // MARK: AppleScript fallback

    private func queryViaAppleScript() -> TrackInfo? {
        guard let script = appleScript else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { // errAEEventNotPermitted: user said "Don't Allow"
                appleScriptDenied = true
                lastError = .automationDenied
            }
            // -600 (app not running) / -1728 (no such property): treat as no track.
            return nil
        }
        guard result.numberOfItems >= 3 else { return nil }
        // AppleScript lists are 1-indexed.
        let title = result.atIndex(1)?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let artist = result.atIndex(2)?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let album = result.atIndex(3)?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return nil }
        return TrackInfo(title: title, artist: artist.isEmpty ? "Unknown Artist" : artist,
                         album: album.isEmpty ? nil : album)
    }
}

// MARK: - Open file inspection (libproc)

enum OpenFileInspector {
    struct OpenFile: Sendable, Equatable {
        let fd: Int32
        let path: String
    }

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "aifc", "caf",
        "ogg", "oga", "opus", "ape", "wv", "dsf", "dff", "mpc", "wma", "tta",
    ]

    /// Audio files currently open in `pid`. Empty if the process is gone or not inspectable.
    static func audioFiles(openedBy pid: pid_t) -> [OpenFile] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        // A little headroom in case files are opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }

        var result: [OpenFile] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }

            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let ext = (path as NSString).pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                result.append(OpenFile(fd: fd.proc_fd, path: path))
            }
        }
        return result
    }
}

// MARK: - Tag reading

enum MetadataReader {
    static func track(for url: URL) async -> TrackInfo {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval?

        let asset = AVURLAsset(url: url)
        if let loaded = try? await asset.load(.commonMetadata, .duration) {
            let (metadata, length) = loaded
            title = await string(metadata, .commonIdentifierTitle)
            artist = await string(metadata, .commonIdentifierArtist)
            album = await string(metadata, .commonIdentifierAlbumName)
            let seconds = CMTimeGetSeconds(length)
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
        // Unsupported containers (Ogg, APE, WavPack…) or untagged files.
        let guess = guessFromPath(url)
        return TrackInfo(title: title ?? guess.title,
                         artist: artist ?? guess.artist ?? "Unknown Artist",
                         album: album ?? guess.album,
                         duration: duration,
                         fileURL: url)
    }

    private static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Artist - Title.flac", "01 - Title.flac", "01. Title.flac" in ".../Artist/Album/".
    static func guessFromPath(_ url: URL) -> (title: String, artist: String?, album: String?) {
        let base = url.deletingPathExtension().lastPathComponent
        let stripped = base.replacingOccurrences(of: #"^\d{1,3}[\s._-]+"#, with: "", options: .regularExpression)
        let parts = stripped.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }

        let albumDir = url.deletingLastPathComponent()
        let artistDir = albumDir.deletingLastPathComponent()
        let folderArtist = artistDir.lastPathComponent
        let folderAlbum = albumDir.lastPathComponent

        if parts.count >= 2, let title = parts.last, !title.isEmpty {
            return (title, parts[parts.count - 2], folderAlbum)
        }
        return (stripped.isEmpty ? base : stripped, folderArtist.isEmpty ? nil : folderArtist, folderAlbum)
    }
}
