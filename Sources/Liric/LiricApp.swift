//
//  LiricApp.swift
//  Liric
//
//  App entry point. Kept deliberately tiny: all logic lives in LiricCore so it can be
//  unit-tested and reused (e.g. a future menu-bar-only variant on macOS 13+).
//

import LiricCore
import SwiftUI

@main
struct LiricApp: App {
    // NetEase is off by default (unofficial API). Flip to `true` for human romaji/romaja.
    @StateObject private var service = LyricsService(enableNetEase: false)

    var body: some Scene {
        WindowGroup("Liric") {
            LyricsView(service: service)
                .frame(minWidth: 320, idealWidth: 380, minHeight: 420, idealHeight: 640)
                .onAppear { service.start() }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Retry Lyrics") { service.retry() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
