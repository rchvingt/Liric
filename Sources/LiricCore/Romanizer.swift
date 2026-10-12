//
//  Romanizer.swift
//  LiricCore
//
//  Language detection + on-device romanization. No network, no dependencies.
//
//  Why on-device?
//  --------------
//  No free, reliable lyrics API returns romanization for both Korean AND Japanese.
//  (NetEase's unofficial `romalrc` field is the only free source of *human* romaji,
//  and it's patchy for K-pop.) So Liric always has a local fallback:
//
//  • Korean → Revised Romanization of Korean (the official South-Korean system,
//    "romaja"), implemented below from Hangul syllable arithmetic plus the sound-change
//    rules that matter most in lyrics (liaison, nasalization, ㄹ-assimilation,
//    aspiration, palatalization). Deterministic and exact for Hangul.
//
//  • Japanese → `CFStringTokenizer` with `kCFStringTokenizerAttributeLatinTranscription`.
//    This is the system's Japanese morphological analyser (the same one behind macOS
//    furigana/IME). It resolves *kanji readings* from a dictionary — which a plain
//    `StringTransform.toLatin` cannot (it reads kanji as Chinese pinyin!).
//    Caveat: song lyrics often use poetic readings (運命 sung as "sadame", not "unmei");
//    only a human romaji (NetEase) fixes that, hence `RomanizationOrigin`.
//

import Foundation
import NaturalLanguage

// MARK: - Language detection

public enum LanguageDetector {
    struct ScriptCounts {
        var hangul = 0, kana = 0, han = 0, latin = 0
        var letters: Int { hangul + kana + han + latin }
    }

    static func countScripts(_ text: String) -> ScriptCounts {
        var counts = ScriptCounts()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F:
                counts.hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
                counts.kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                counts.han += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                counts.latin += 1
            default:
                break
            }
        }
        return counts
    }

    /// Detects the language of a lyric body (or a title).
    ///
    /// Script counting first, because `NLLanguageRecognizer` alone is unreliable here:
    /// K-pop/J-pop lyrics are often 30–60 % English, and a kanji-heavy line looks Chinese.
    /// - Any meaningful share of Hangul ⇒ Korean.
    /// - Any meaningful share of kana ⇒ Japanese (kana only exists in Japanese).
    /// - Han without kana ⇒ most likely Chinese ⇒ `.undetermined` (not romanized).
    /// - Latin ⇒ ask NaturalLanguage whether it's English.
    public static func detect(_ text: String) -> LyricLanguage {
        let c = countScripts(text)
        guard c.letters > 0 else { return .undetermined }
        let letters = Double(c.letters)

        // A Hangul syllable carries ~2.5 Latin letters' worth of text, so 5 % is plenty.
        if c.hangul > 0, c.hangul >= c.kana, Double(c.hangul) / letters >= 0.05 {
            return .korean
        }
        if c.kana > 0, Double(c.kana + c.han) / letters >= 0.05 {
            return .japanese
        }
        if c.han > c.latin {
            return .undetermined
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .english?:
            return .english
        case nil:
            return .english // too short to tell (e.g. a title like "Ditto"); Latin either way
        default:
            // Short Latin titles are frequently mis-guessed; only trust NL on real text.
            return c.latin < 40 ? .english : .undetermined
        }
    }
}

// MARK: - Romanizer

public struct Romanizer: Sendable {
    public struct Options: Sendable, Equatable {
        /// Keep Hepburn macrons (tōkyō) instead of plain ASCII (tokyo). Fan-subbed lyric
        /// sites overwhelmingly use plain ASCII, so it's off by default.
        public var japaneseMacrons: Bool

        public init(japaneseMacrons: Bool = false) {
            self.japaneseMacrons = japaneseMacrons
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Romanizes a whole lyric variant line-by-line, preserving LRC timestamps.
    ///
    /// Returns nil when there is nothing to romanize (Latin-script song, empty text,
    /// or the output would be identical) — callers then display the original text.
    public func romanize(_ text: LyricText, language: LyricLanguage) -> LyricText? {
        guard language.needsRomanization, !text.isEmpty else { return nil }

        let plain = text.plain
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { romanizeLine($0, songLanguage: language) }
            .joined(separator: "\n")
        guard plain != text.plain else { return nil }

        var synced: String?
        if let lrc = text.synced {
            let lines = LRC.parse(lrc)
            if !lines.isEmpty {
                synced = LRC.serialize(lines.map {
                    LyricLine(time: $0.time, text: romanizeLine($0.text, songLanguage: language))
                })
            }
        }
        return LyricText(plain: plain, synced: synced)
    }

    /// Romanizes one line. Routing is per *line*, by script, because K-pop songs contain
    /// Japanese lines (and vice versa) and every Asian pop song contains English lines,
    /// which must pass through untouched.
    public func romanizeLine(_ line: String, songLanguage: LyricLanguage) -> String {
        let c = LanguageDetector.countScripts(line)
        if c.hangul > 0 && c.kana == 0 {
            return HangulRomanizer.romanize(line)
        }
        if c.kana > 0 || (c.han > 0 && songLanguage == .japanese) {
            return JapaneseRomanizer.romanize(line, keepMacrons: options.japaneseMacrons)
        }
        if c.hangul > 0 {
            // Mixed Hangul + kana in one line: do both, Hangul first (kana tokenizer
            // leaves already-Latin text alone).
            let hangulDone = HangulRomanizer.romanize(line)
            return JapaneseRomanizer.romanize(hangulDone, keepMacrons: options.japaneseMacrons)
        }
        // Latin, digits, punctuation, or Han in a non-Japanese song: leave unchanged.
        // (We never emit pinyin for kanji — a wrong reading is worse than none.)
        return line
    }
}

// MARK: - Korean (Revised Romanization)

enum HangulRomanizer {
    private struct Syllable {
        let initial: Int  // 0..<19
        let medial: Int   // 0..<21
        let final: Int    // 0..<28 (0 = no final consonant)
    }

    private static let initials = [
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s",
        "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    ]
    private static let medials = [
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae",
        "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    ]
    // Final consonants as pronounced before a pause / another consonant.
    private static let finals = [
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k",     //  ㄱ ㄲ ㄳ ㄴ ㄵ ㄶ ㄷ ㄹ ㄺ
        "m", "l", "l", "l", "p", "l", "m", "p", "p", "t",    // ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅁ ㅂ ㅄ ㅅ
        "t", "ng", "t", "t", "k", "t", "p", "t",             // ㅆ ㅇ ㅈ ㅊ ㅋ ㅌ ㅍ ㅎ
    ]

    // Initial-consonant indices used by the sound-change rules.
    private static let iG = 0, iN = 2, iD = 3, iR = 5, iM = 6, iSilent = 11, iJ = 12, iH = 18
    private static let vowelI = 20

    // Final-consonant classes by how they assimilate.
    private static let kClass: Set<Int> = [1, 2, 3, 9, 24]        // ㄱ ㄲ ㄳ ㄺ ㅋ
    private static let tClass: Set<Int> = [7, 19, 20, 22, 23, 25] // ㄷ ㅅ ㅆ ㅈ ㅊ ㅌ
    private static let pClass: Set<Int> = [14, 17, 18, 26]        // ㄿ ㅂ ㅄ ㅍ

    /// Liaison (연음): a final consonant followed by a silent ㅇ moves into the next
    /// syllable. Compound finals split: the first half stays, the second moves.
    private static let liaison: [Int: (keep: String, carry: String)] = [
        1: ("", "g"), 2: ("", "kk"), 3: ("k", "s"), 4: ("", "n"), 5: ("n", "j"),
        6: ("", "n"), 7: ("", "d"), 8: ("", "r"), 9: ("l", "g"), 10: ("l", "m"),
        11: ("l", "b"), 12: ("l", "s"), 13: ("l", "t"), 14: ("l", "p"), 15: ("", "r"),
        16: ("", "m"), 17: ("", "b"), 18: ("p", "s"), 19: ("", "s"), 20: ("", "ss"),
        22: ("", "j"), 23: ("", "ch"), 24: ("", "k"), 25: ("", "t"), 26: ("", "p"),
        27: ("", ""), // ㅎ is silent before a vowel: 좋아 → joa
    ]

    private static func decompose(_ scalar: Unicode.Scalar) -> Syllable? {
        let value = Int(scalar.value)
        guard (0xAC00...0xD7A3).contains(value) else { return nil }
        let index = value - 0xAC00
        return Syllable(initial: index / 588, medial: (index % 588) / 28, final: index % 28)
    }

    static func romanize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        output.reserveCapacity(scalars.count * 3)
        var carriedInitial: String?

        for (index, scalar) in scalars.enumerated() {
            guard let syllable = decompose(scalar) else {
                carriedInitial = nil
                output.unicodeScalars.append(scalar)
                continue
            }
            let onset = carriedInitial ?? initials[syllable.initial]
            carriedInitial = nil

            var coda = finals[syllable.final]
            // Sound changes only apply inside a word (adjacent syllables, no space).
            if index + 1 < scalars.count, let next = decompose(scalars[index + 1]),
               let change = soundChange(final: syllable.final, next: next) {
                coda = change.coda
                carriedInitial = change.nextOnset
            }
            output += onset + medials[syllable.medial] + coda
        }
        return output
    }

    /// Returns how the final consonant and the next onset are pronounced, or nil if
    /// both keep their default romanization.
    private static func soundChange(final t: Int, next: Syllable) -> (coda: String, nextOnset: String?)? {
        guard t != 0 else { return nil }
        let nextInitial = next.initial

        switch nextInitial {
        case iSilent:
            // Palatalization: 같이 → gachi, 굳이 → guji
            if next.medial == vowelI {
                if t == 7 { return ("", "j") }
                if t == 25 { return ("", "ch") }
            }
            guard let move = liaison[t] else { return nil } // ㅇ final: 사랑이 → sarangi
            return (move.keep, move.carry)

        case iN, iM:
            // Nasalization: 합니다 → hamnida, 작년 → jangnyeon, 있는 → inneun
            if kClass.contains(t) { return ("ng", nil) }
            if tClass.contains(t) || t == 27 { return ("n", nil) }
            if pClass.contains(t) { return ("m", nil) }
            if t == 8 && nextInitial == iN { return ("l", "l") } // ㄹ+ㄴ → ll
            return nil

        case iR:
            if t == 4 || t == 8 { return ("l", "l") }            // 신라 → silla, 몰라 → molla
            if t == 16 || t == 21 { return (finals[t], "n") }    // 종로 → jongno
            if kClass.contains(t) { return ("ng", "n") }         // 독립 → dongnip
            if pClass.contains(t) { return ("m", "n") }          // 협력 → hyeomnyeok
            return nil

        case iH:
            // Aspiration: 축하 → chuka, 입학 → ipak
            if kClass.contains(t) { return ("", "k") }
            if t == 22 || t == 23 { return ("", "ch") }
            if tClass.contains(t) { return ("", "t") }
            if pClass.contains(t) { return ("", "p") }
            return nil

        case iG, iD, iJ:
            // ㅎ final aspirates the next consonant: 좋다 → jota, 많고 → manko
            let aspirated = nextInitial == iG ? "k" : (nextInitial == iD ? "t" : "ch")
            switch t {
            case 27: return ("", aspirated)
            case 6: return ("n", aspirated)
            case 15: return ("l", aspirated)
            default: return nil
            }

        default:
            return nil
        }
    }
}

// MARK: - Japanese (Hepburn via the system tokenizer)

enum JapaneseRomanizer {
    static func romanize(_ text: String, keepMacrons: Bool) -> String {
        guard !text.isEmpty else { return text }
        let ns = text as NSString
        let locale = CFLocaleCreate(kCFAllocatorDefault, "ja" as CFString)
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString,
            CFRange(location: 0, length: ns.length),
            CFOptionFlags(kCFStringTokenizerUnitWord), locale
        )

        var output = ""
        var cursor = 0
        var previousWasJapanese = false

        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > cursor {
                // Whitespace / punctuation between tokens is copied through.
                output += normalizePunctuation(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            let surface = ns.substring(with: NSRange(location: range.location, length: range.length))
            let isJapanese = containsJapanese(surface)
            let latin = isJapanese ? transcribe(surface, tokenizer: tokenizer, keepMacrons: keepMacrons) : surface

            // Japanese has no spaces between words; romaji needs them.
            if (isJapanese || previousWasJapanese), let last = output.last,
               !last.isWhitespace, !"([\"'“‘".contains(last) {
                output += " "
            }
            output += latin
            previousWasJapanese = isJapanese
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            output += normalizePunctuation(ns.substring(from: cursor))
        }
        return output
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func transcribe(_ surface: String, tokenizer: CFStringTokenizer, keepMacrons: Bool) -> String {
        // Particles: the tokenizer gives the kana reading, Hepburn uses the pronunciation.
        switch surface {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        default: break
        }

        var latin: String?
        let attribute = CFOptionFlags(kCFStringTokenizerAttributeLatinTranscription)
        if let value = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, attribute) as? String, !value.isEmpty {
            latin = value
        } else if !containsHan(surface) {
            // Pure kana the dictionary didn't know (slang, onomatopoeia): kana→Latin is exact.
            latin = surface.applyingTransform(.toLatin, reverse: false)
        }
        // Unknown kanji: keep it rather than emit a Chinese (pinyin) reading.
        guard var result = latin else { return surface }
        if !keepMacrons {
            result = result.applyingTransform(.stripDiacritics, reverse: false) ?? result
        }
        return result.lowercased()
    }

    private static func containsJapanese(_ s: String) -> Bool {
        let c = LanguageDetector.countScripts(s)
        return c.kana > 0 || c.han > 0
    }

    private static func containsHan(_ s: String) -> Bool {
        LanguageDetector.countScripts(s).han > 0
    }

    private static func normalizePunctuation(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "、": out += ","
            case "。": out += "."
            case "「", "」", "『", "』": out += "\""
            case "・": out += " "
            case "〜", "～": out += "~"
            case "\u{3000}": out += " " // ideographic space
            default:
                if (0xFF01...0xFF5E).contains(scalar.value),
                   let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
                    out.unicodeScalars.append(ascii) // full-width ！？（） → ASCII
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
