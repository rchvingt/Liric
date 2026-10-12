//
//  LyricsView.swift
//  Liric
//

import LiricCore
import SwiftUI

struct LyricsView: View {
    @ObservedObject var service: LyricsService

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let track = currentTrack {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            } else {
                Text("Liric").font(.headline)
            }
            if case let .loaded(lyrics, _) = service.status, lyrics.language.needsRomanization {
                Picker("Display", selection: $service.displayMode) {
                    Text("Original").tag(Lyrics.DisplayMode.original)
                    Text(lyrics.language.romanizationName ?? "Romanized").tag(Lyrics.DisplayMode.romanized)
                    Text("Both").tag(Lyrics.DisplayMode.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let warning = service.playerWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentTrack: TrackInfo? {
        switch service.status {
        case let .loading(track), let .instrumental(track), let .notFound(track):
            return track
        case let .loaded(lyrics, _):
            return lyrics.track
        case let .failed(track, _):
            return track
        case .waitingForPlayer, .idle:
            return nil
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch service.status {
        case .waitingForPlayer:
            placeholder("Waiting for VOX…", systemImage: "music.note", detail: "Open VOX and play a song.")
        case .idle:
            placeholder("Nothing playing", systemImage: "pause.circle", detail: nil)
        case .loading:
            ProgressView()
        case .instrumental:
            placeholder("Instrumental", systemImage: "pianokeys", detail: nil)
        case .notFound:
            VStack(spacing: 12) {
                placeholder("No lyrics found", systemImage: "text.badge.xmark", detail: nil)
                Button("Try Again") { service.retry() }
            }
        case let .failed(_, message):
            VStack(spacing: 12) {
                placeholder("Lyrics unavailable", systemImage: "wifi.exclamationmark", detail: message)
                Button("Try Again") { service.retry() }
            }
        case let .loaded(lyrics, notice):
            lyricsBody(lyrics, notice: notice)
        }
    }

    private func lyricsBody(_ lyrics: Lyrics, notice: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let notice {
                    Text(notice).font(.caption).foregroundColor(.secondary)
                        .padding(.bottom, 4)
                }
                ForEach(lyrics.displayLines(service.displayMode)) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.primary.isEmpty ? " " : line.primary)
                            .font(.body)
                        if let secondary = line.secondary {
                            Text(secondary).font(.callout).foregroundColor(.secondary)
                        }
                    }
                }
                Text("Source: \(lyrics.source.rawValue)")
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.top, 12)
            }
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placeholder(_ title: String, systemImage: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundColor(.secondary)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
