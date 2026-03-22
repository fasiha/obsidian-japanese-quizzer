// RomajiConverter.swift
// Converts ASCII romaji to hiragana for lenient answer matching on pair-discrimination quizzes.
// Handles the standard Hepburn romanization for Japanese verb dictionary forms.
// Uses greedy longest-match scanning.

import Foundation

/// Convert a romaji string to hiragana. Returns nil if the input contains
/// characters that cannot be mapped (e.g. non-ASCII letters not in the table).
func romajiToHiragana(_ romaji: String) -> String? {
    // Table ordered longest-match first within each initial consonant group.
    let table: [(String, String)] = [
        // Digraphs and special combos first
        ("shi", "し"), ("chi", "ち"), ("tsu", "つ"),
        ("sha", "しゃ"), ("shu", "しゅ"), ("sho", "しょ"),
        ("cha", "ちゃ"), ("chu", "ちゅ"), ("cho", "ちょ"),
        ("tya", "ちゃ"), ("tyu", "ちゅ"), ("tyo", "ちょ"),
        ("dzu", "づ"), ("dji", "ぢ"),
        ("kya", "きゃ"), ("kyu", "きゅ"), ("kyo", "きょ"),
        ("gya", "ぎゃ"), ("gyu", "ぎゅ"), ("gyo", "ぎょ"),
        ("nya", "にゃ"), ("nyu", "にゅ"), ("nyo", "にょ"),
        ("hya", "ひゃ"), ("hyu", "ひゅ"), ("hyo", "ひょ"),
        ("bya", "びゃ"), ("byu", "びゅ"), ("byo", "びょ"),
        ("pya", "ぴゃ"), ("pyu", "ぴゅ"), ("pyo", "ぴょ"),
        ("mya", "みゃ"), ("myu", "みゅ"), ("myo", "みょ"),
        ("rya", "りゃ"), ("ryu", "りゅ"), ("ryo", "りょ"),
        ("ja", "じゃ"), ("ju", "じゅ"), ("jo", "じょ"),
        // Double consonants → small tsu + rest
        // (handled separately via nn check)
        // Single-character vowels
        ("a", "あ"), ("i", "い"), ("u", "う"), ("e", "え"), ("o", "お"),
        // ka-row
        ("ka", "か"), ("ki", "き"), ("ku", "く"), ("ke", "け"), ("ko", "こ"),
        // ga-row
        ("ga", "が"), ("gi", "ぎ"), ("gu", "ぐ"), ("ge", "げ"), ("go", "ご"),
        // sa-row
        ("sa", "さ"), ("si", "し"), ("su", "す"), ("se", "せ"), ("so", "そ"),
        // za-row
        ("za", "ざ"), ("zi", "じ"), ("zu", "ず"), ("ze", "ぜ"), ("zo", "ぞ"),
        ("ji", "じ"),
        // ta-row
        ("ta", "た"), ("ti", "ち"), ("tu", "つ"), ("te", "て"), ("to", "と"),
        // da-row
        ("da", "だ"), ("di", "ぢ"), ("du", "づ"), ("de", "で"), ("do", "ど"),
        // na-row
        ("na", "な"), ("ni", "に"), ("nu", "ぬ"), ("ne", "ね"), ("no", "の"),
        // ha-row
        ("ha", "は"), ("hi", "ひ"), ("hu", "ふ"), ("he", "へ"), ("ho", "ほ"),
        ("fu", "ふ"),
        // ba-row
        ("ba", "ば"), ("bi", "び"), ("bu", "ぶ"), ("be", "べ"), ("bo", "ぼ"),
        // pa-row
        ("pa", "ぱ"), ("pi", "ぴ"), ("pu", "ぷ"), ("pe", "ぺ"), ("po", "ぽ"),
        // ma-row
        ("ma", "ま"), ("mi", "み"), ("mu", "む"), ("me", "め"), ("mo", "も"),
        // ya-row
        ("ya", "や"), ("yu", "ゆ"), ("yo", "よ"),
        // ra-row
        ("ra", "ら"), ("ri", "り"), ("ru", "る"), ("re", "れ"), ("ro", "ろ"),
        // wa-row
        ("wa", "わ"), ("wi", "ゐ"), ("we", "ゑ"), ("wo", "を"),
        // n
        ("nn", "ん"), ("n'", "ん"),
    ]

    var result = ""
    var s = romaji.lowercased()
    while !s.isEmpty {
        // Handle double consonants (っ + rest), e.g. "kku" → っく
        // "nn" is already in table as ん, so skip n.
        let first = s.unicodeScalars.first!
        if first.value >= 97 && first.value <= 122 && first != "n" {
            let ch = Character(first)
            let secondIdx = s.index(after: s.startIndex)
            if secondIdx < s.endIndex && s[secondIdx] == ch {
                // double consonant → っ, then continue with remaining (still doubled? no, one consumed)
                // e.g. "kku" → っ then "ku"
                result += "っ"
                s = String(s[secondIdx...])
                continue
            }
        }

        var matched = false
        for (rom, hira) in table {
            if s.hasPrefix(rom) {
                result += hira
                s = String(s.dropFirst(rom.count))
                matched = true
                break
            }
        }
        if !matched {
            // Try standalone 'n' before a consonant or end of string
            if s.hasPrefix("n") {
                let after = s.dropFirst()
                if after.isEmpty || "bcdfghjklmpqrstvwxyz".contains(after.first!) {
                    result += "ん"
                    s = String(after)
                    continue
                }
            }
            return nil // unrecognized
        }
    }
    return result
}
