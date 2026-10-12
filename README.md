# Liric

A lightweight macOS lyrics app for **VOX Player**. It's tuned for K-pop, J-pop and Western music, and shows **romanization** (Romaja / Romaji) next to the original lyrics.

- macOS 12+, SwiftUI, Swift concurrency (async/await, actors)
- **No third-party dependencies.** It uses SQLite3, AVFoundation, NaturalLanguage and CFStringTokenizer, which all ship with macOS.
- Everything is stored locally. There's no account and no cloud sync.

---

## Getting started

```bash
mkdir -p ~/Projects
git clone https://github.com/rchvingt/liric.git ~/Projects/liric
cd ~/Projects/liric

# Option A: quickest. Xcode opens the Swift package directly.
open Package.swift            # then run the "Liric" scheme, or: swift run Liric

# Option B: a real .app bundle (Info.plist, entitlements, Automation prompt text)
brew install xcodegen
xcodegen generate             # creates Liric.xcodeproj from project.yml (git-ignored)
open Liric.xcodeproj
```

Tests: `swift test`, or ⌘U in Xcode.

```
liric/
├── Package.swift                 SwiftPM manifest (library + app + tests)
├── project.yml                   XcodeGen spec → Liric.xcodeproj
├── Config/                       Info.plist, entitlements (not sandboxed, see below)
├── Sources/
│   ├── LiricCore/              all logic, unit-testable
│   │   ├── Models.swift              TrackInfo, Lyrics (original/romanized/translation), LRC, errors
│   │   ├── VOXPlayerMonitor.swift    VOX track detection (open-file inspection + AppleScript fallback)
│   │   ├── LyricsAPIClient.swift     multi-source fetching, rate limiting, retries
│   │   ├── LocalStorageManager.swift SQLite cache
│   │   ├── Romanizer.swift           language detection + on-device Romaja/Romaji
│   │   └── LyricsService.swift       orchestration + degradation ladder, observable for SwiftUI
│   └── Liric/                  SwiftUI app shell (LiricApp, LyricsView)
└── Tests/LiricCoreTests/
```

---

## Recommendation 1: lyric APIs

**Short answer:** no single free API covers K-pop, J-pop and Western music *and* returns romanization. The best free setup combines several sources, with romanization generated on your Mac:

| Priority | Source | Cost | 🇰🇷 K-pop | 🇯🇵 J-pop | 🇺🇸 Western | Synced | Romanization | Reliability |
|---|---|---|---|---|---|---|---|---|
| 1 | **Local file** (`Song.lrc` sidecar or embedded USLT/©lyr tags) | Free | whatever you have | ← | ← | ✅ | if the file has it | ★★★★★ offline, exact |
| 2 | **[LRCLIB](https://lrclib.net)** | Free, no key | Good (mainstream) | Good | Excellent | ✅ LRC | ❌ | ★★★★☆ official, open DB, stable |
| 3 | **NetEase Cloud Music** (unofficial, opt-in) | Free, no key | Very good | **Excellent** | Good | ✅ LRC | ✅ **human** romaji (`romalrc`), some romaja; translations | ★★☆☆☆ undocumented, may change or geo-block |
| — | On-device `Romanizer` | Free | ✅ Romaja (rule-based, exact for Hangul) | ✅ Romaji (system dictionary) | n/a | keeps timestamps | ✅ always available | ★★★★★ |

Ruled out:
- **Musixmatch**: the free tier returns only 30% of each lyric. Full text and transliteration require a commercial licence (paid).
- **Genius**: the API doesn't return lyric text. Getting it means scraping HTML, which their ToS forbid. Their "Genius Romanizations" pages are good, but only if you read them manually.
- **lyrics.ovh and similar wrappers**: Western-only and flaky.

**Do you need a paid tier?** No, not for a personal app. LRCLIB plus on-device romanization covers all three genres for free. Lyrics are copyrighted, though. If you ever **distribute Liric commercially**, license the lyrics through Musixmatch or LyricFind instead of relying on community or unofficial sources.

**How romanization works, in order of preference:**
1. **Human-written, from the source** (NetEase `romalrc`, if enabled). This is the only option that gets poetic readings right. For example, 運命 is often sung *sadame*, but a dictionary gives *unmei*.
2. **Generated on your Mac** (`Romanizer.swift`):
   - **Korean:** Revised Romanization, computed from Hangul syllable structure plus the sound-change rules that matter in lyrics. For example, 감사합니다 → *gamsahamnida*, 같이 → *gachi*, 좋아 → *joa*. It's deterministic and needs no dictionary.
   - **Japanese:** `CFStringTokenizer` with `kCFStringTokenizerAttributeLatinTranscription`. This is macOS's own Japanese morphological analyser, so kanji get Japanese readings. (`StringTransform.toLatin` would give Chinese pinyin instead.) Particles are corrected (は→wa, を→o) and macrons are optional.
3. **None.** The UI shows the original lyrics with a notice, so you never get an empty screen.

Romanization is decided **per line by script**. That means English lines in K-pop pass through unchanged, and a Japanese verse in a Korean song gets Romaji.

To turn on NetEase, use `LyricsService(enableNetEase: true)` in `LiricApp.swift`.

---

## Recommendation 2: local storage → **SQLite**

For 5–10k songs with 1–3 text variants each (about 30–150 MB):

| | Memory | Lookup | Multiple variants | Complexity | Verdict |
|---|---|---|---|---|---|
| One JSON file | ❌ whole file in RAM, rewritten on every save | O(n) after load | nested JSON | low | ✗ breaks the low-memory goal |
| JSON file per song | ✅ | ✅ by filename | ✅ | low, but no queries (LRU eviction, stats), no atomic writes, 10k inodes | ✗ |
| Core Data | ok | ✅ | ✅ | **high**: model file, contexts, threading rules, migrations. It's SQLite underneath anyway | ✗ overkill without object graphs or CloudKit |
| **SQLite (system libsqlite3)** | ✅ only touched pages, cache capped at 2 MB | ✅ indexed, < 1 ms | ✅ `lyric_variants` rows | low with a ~100-line wrapper | **✓ chosen** |

Schema: one `tracks` row per song, with `lyric_variants` rows keyed by kind (`original`, `romanized` or `translation`). Each variant stores its language (`ko`, `ko-Latn`, `ja-Latn`, and so on), plain text, synced LRC, and the `origin` of the romanization (`source` or `generated`). A `misses` table remembers "no lyrics anywhere" for 7 days. Old songs are evicted (least recently used first) once you pass 10k. The single `actor` connection runs in WAL mode.

---

## How VOX detection works

VOX has no "now playing" file. The system Now Playing data sits in the private MediaRemote framework, which is locked down for third-party apps since macOS 15.4. So `VOXPlayerMonitor` works like this:

1. **Open-file inspection (main path, no permission prompt).** `proc_pidinfo` and `proc_pidfdinfo` list the audio files VOX has open, the same way `lsof` does. Tags are read with AVFoundation, falling back to `Artist - Title.ext` and folder names. VOX opens the next file early for gapless playback, so the monitor stays on the current file until VOX closes it.
2. **AppleScript (fallback for streams and VOX Radio).** This asks VOX for `{track, artist, album}`. macOS shows a one-time "Liric wants to control VOX" prompt. If you deny it, Liric stops asking and shows a hint.
3. **When VOX isn't running, nothing polls.** NSWorkspace launch and quit notifications wake the monitor when VOX starts.

Because of (1), the app is **not sandboxed**. That's fine for direct or notarized distribution. A Mac App Store build would have to use only the AppleScript path.

## Error handling

| Situation | Behaviour |
|---|---|
| VOX not running | "Waiting for VOX…", no polling, resumes automatically when VOX launches |
| Automation denied | AppleScript disabled, warning shown, file-based detection keeps working |
| HTTP 429 or NetEase anti-crawl codes | Source cools down (respects `Retry-After`, 5 s–1 h), the next source is tried immediately, and the UI retries after the delay |
| Offline | Fails fast (`waitsForConnectivity = false`), cached lyrics still work, retries after 5, 10 and 20 s |
| Timeouts or 5xx | Up to 2 quick retries (0.5 s, 1 s), then the next source |
| Not found anywhere | Remembered for 7 days so the APIs aren't hit again; "Try Again" ignores this |
| Missing romanization | Human → on-device → original text plus a notice |
| Kanji with no known reading | Kept as kanji. Liric never outputs pinyin |
| Cache can't open (disk or permissions) | Falls back to an in-memory cache |

## Roadmap ideas
- Karaoke-style highlighting: get the playback position via AppleScript and use the synced LRC that's already stored.
- A menu bar mode (`MenuBarExtra`, macOS 13+).
- Settings UI for NetEase, macrons and display mode.
