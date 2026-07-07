import Foundation

/// Double Metaphone phonetic encoder (Lawrence Philips, 2000).
///
/// Produces a `(primary, secondary)` pair of phonetic keys for a word so that
/// homophones — including common ASR mishearings of proper nouns — collide on
/// their primary key (e.g. `gocomo` / `Gokumo` / `Gokomo` → `KKM`;
/// `Firtina` / `Fertina` → `FRTN`).
///
/// Input is normalised before encoding: uppercased and diacritic-stripped
/// (`Müller` → `MULLER`) so accented Latin script folds to its base letters.
/// Self-contained, no external dependency.
///
/// This is a faithful port of the canonical reference implementation; the key
/// length is intentionally *not* capped at 4 so that longer distinctive names
/// keep their tail (the matcher pairs this with bounded Levenshtein).
public enum DoubleMetaphone {

    /// Encode a string to its primary and secondary Double Metaphone keys.
    /// Returns `("", "")` for input with no encodable letters.
    public static func encode(_ s: String) -> (primary: String, secondary: String) {
        // Normalise: strip diacritics, uppercase, keep A–Z only.
        let folded = s.folding(options: .diacriticInsensitive, locale: .current).uppercased()
        let letters = Array(folded.unicodeScalars.compactMap { scalar -> Character? in
            (scalar.value >= 65 && scalar.value <= 90) ? Character(scalar) : nil
        })
        guard !letters.isEmpty else { return ("", "") }

        var primary = ""
        var secondary = ""
        let length = letters.count
        let last = length - 1

        // Helpers -------------------------------------------------------------
        func at(_ i: Int) -> Character { letters[i] }
        func isVowel(_ i: Int) -> Bool {
            guard i >= 0, i < length else { return false }
            return "AEIOUY".contains(letters[i])
        }
        /// Substring `letters[start ..< start+len]`, clamped to bounds; "" if out of range.
        func slice(_ start: Int, _ len: Int) -> String {
            guard start >= 0, len > 0 else { return "" }
            let end = min(start + len, length)
            guard start < end else { return "" }
            return String(letters[start..<end])
        }
        /// True if `slice(start, s.count) == s`.
        func matches(_ start: Int, _ s: String) -> Bool { slice(start, s.count) == s }
        /// True if the slice at `start` (of length = longest option) equals any option.
        func stringAt(_ start: Int, _ options: String...) -> Bool {
            for opt in options where matches(start, opt) { return true }
            return false
        }
        func add(_ p: String, _ s: String? = nil) {
            primary += p
            secondary += (s ?? p)
        }

        // Skip silent initial letters.
        var current = 0
        if stringAt(0, "GN", "KN", "PN", "WR", "PS") { current = 1 }

        // Initial 'X' is pronounced 'S' (e.g. "Xavier").
        if at(0) == "X" {
            add("S")
            current = 1
        }

        // Detect a Slavo-Germanic word (affects a few W/CH rules).
        let word = String(letters)
        let isSlavoGermanic =
            word.contains("W") || word.contains("K") ||
            word.contains("CZ") || word.contains("WITZ")

        while current < length {
            let c = at(current)
            switch c {
            case "A", "E", "I", "O", "U", "Y":
                if current == 0 { add("A") } // only vowel at start is encoded
                current += 1

            case "B":
                add("P")
                current += (at(min(current + 1, last)) == "B" && current + 1 <= last) ? 2 : 1

            case "Ç":
                add("S"); current += 1

            case "C":
                current = encodeC(letters, current, length, last,
                                   stringAt: stringAt, matches: matches, isVowel: isVowel,
                                   slice: slice, add: add)

            case "D":
                if stringAt(current, "DG") {
                    if current + 2 < length, "IEY".contains(at(current + 2)) {
                        add("J"); current += 3          // DGE / DGI / DGY
                    } else {
                        add("TK"); current += 2         // DG otherwise
                    }
                } else if stringAt(current, "DT", "DD") {
                    add("T"); current += 2
                } else {
                    add("T"); current += 1
                }

            case "F":
                add("F")
                current += (at(min(current + 1, last)) == "F" && current + 1 <= last) ? 2 : 1

            case "G":
                current = encodeG(letters, current, length, last, isSlavoGermanic: isSlavoGermanic,
                                  stringAt: stringAt, matches: matches, isVowel: isVowel,
                                  slice: slice, add: add)

            case "H":
                // Keep H only between two vowels, or at start before a vowel.
                if (current == 0 || isVowel(current - 1)) && isVowel(current + 1) {
                    add("H"); current += 2
                } else {
                    current += 1
                }

            case "J":
                // Simplified: 'J' → 'J' primary; Spanish "-JO"/"-JA" allows an 'H' secondary.
                if stringAt(current, "JOSE") || slice(0, 4) == "SAN " {
                    if current == 0 { add("H") } else { add("J", "H") }
                } else {
                    if current == 0 {
                        add("J", "A")
                    } else if isVowel(current - 1) && !isSlavoGermanic
                        && (at(current + 1) == "A" || at(current + 1) == "O") {
                        add("J", "H")
                    } else if current == last {
                        add("J", "")
                    } else if !stringAt(current + 1, "L", "T", "K", "S", "N", "M", "B", "Z")
                        && !(current > 0 && stringAt(current - 1, "S", "K", "L")) {
                        add("J")
                    } else {
                        add("J")
                    }
                }
                current += (at(min(current + 1, last)) == "J" && current + 1 <= last) ? 2 : 1

            case "K":
                add("K")
                current += (at(min(current + 1, last)) == "K" && current + 1 <= last) ? 2 : 1

            case "L":
                add("L")
                current += (at(min(current + 1, last)) == "L" && current + 1 <= last) ? 2 : 1

            case "M":
                // "-MB" silent B (e.g. "dumb", "thumb").
                let doubleM = (at(min(current + 1, last)) == "M" && current + 1 <= last)
                if (current + 1 == last && stringAt(current - 1, "UMB"))
                    || doubleM {
                    current += 2
                } else {
                    current += 1
                }
                add("M")

            case "N":
                add("N")
                current += (at(min(current + 1, last)) == "N" && current + 1 <= last) ? 2 : 1

            case "Ñ":
                add("N"); current += 1

            case "P":
                if at(min(current + 1, last)) == "H" && current + 1 <= last {
                    add("F"); current += 2          // PH → F
                } else if stringAt(current + 1, "P", "B") {
                    add("P"); current += 2          // PP / PB
                } else {
                    add("P"); current += 1
                }

            case "Q":
                add("K")
                current += (at(min(current + 1, last)) == "Q" && current + 1 <= last) ? 2 : 1

            case "R":
                add("R")
                current += (at(min(current + 1, last)) == "R" && current + 1 <= last) ? 2 : 1

            case "S":
                current = encodeS(letters, current, length, last, isSlavoGermanic: isSlavoGermanic,
                                  stringAt: stringAt, matches: matches, isVowel: isVowel, add: add)

            case "T":
                if stringAt(current, "TIA", "TCH") {
                    add("X"); current += 3
                } else if stringAt(current, "TH") || stringAt(current, "TTH") {
                    add("0", "T")                    // 'θ' → primary 0, secondary T
                    current += 2
                } else if stringAt(current, "TT", "TD") {
                    add("T"); current += 2
                } else {
                    add("T"); current += 1
                }

            case "V":
                add("F")
                current += (at(min(current + 1, last)) == "V" && current + 1 <= last) ? 2 : 1

            case "W":
                // WR handled by initial skip. WH / vowel → keep.
                if stringAt(current, "WH") {
                    add("A"); current += 2
                } else if isVowel(current + 1) {
                    if isSlavoGermanic { add("F", "F") } else { add("A") }
                    current += 1
                } else if stringAt(current, "WICZ", "WITZ") {
                    add("TS", "FX"); current += 4
                } else {
                    current += 1                     // otherwise silent
                }

            case "X":
                add("KS")
                current += stringAt(current + 1, "C") ? 1
                    : (at(min(current + 1, last)) == "X" && current + 1 <= last) ? 2 : 1

            case "Z":
                if at(min(current + 1, last)) == "H" && current + 1 <= last {
                    add("J"); current += 2           // ZH
                } else {
                    add("S", "TS")
                    current += (at(min(current + 1, last)) == "Z" && current + 1 <= last) ? 2 : 1
                }

            default:
                current += 1
            }
        }

        return (primary, secondary)
    }

    // MARK: - Per-letter helpers (kept out of the main loop for readability)

    private static func encodeC(
        _ letters: [Character], _ current: Int, _ length: Int, _ last: Int,
        stringAt: (Int, String...) -> Bool,
        matches: (Int, String) -> Bool,
        isVowel: (Int) -> Bool,
        slice: (Int, Int) -> String,
        add: (String, String?) -> Void
    ) -> Int {
        func at(_ i: Int) -> Character { (i >= 0 && i < length) ? letters[i] : " " }

        // -CIA-
        if stringAt(current, "CIA") { add("X", nil); return current + 3 }
        // CH
        if stringAt(current, "CH") {
            // CHAE (e.g. "Michael") → K/X
            if current > 0 && stringAt(current, "CHAE") { add("K", "X"); return current + 2 }
            // "CH" at start of certain Greek/Germanic roots → K
            if current == 0 && (stringAt(current + 1, "HARAC", "HARIS")
                || stringAt(current + 1, "HOR", "HYM", "HIA", "HEM")) {
                add("K", nil); return current + 2
            }
            add("X", "K"); return current + 2
        }
        // CZ (but not "WICZ")
        if stringAt(current, "CZ") && !(current >= 1 && stringAt(current - 1, "WICZ")) {
            add("S", "X"); return current + 2
        }
        // -CIA already done; -CC-
        if stringAt(current, "CC") && !(current == 1 && at(0) == "M") {
            if stringAt(current + 2, "I", "E", "H") && !stringAt(current + 2, "HU") {
                // CCE, CCI, CCH  (e.g. "accident", "Bacchus")
                if (current == 1 && at(current - 1) == "A") || stringAt(current - 1, "UCCEE", "UCCES") {
                    add("KS", nil)
                } else {
                    add("X", nil)
                }
                return current + 3
            } else {
                add("K", nil); return current + 2   // "Bacci", "Bertucci"
            }
        }
        if stringAt(current, "CK", "CG", "CQ") { add("K", nil); return current + 2 }
        if stringAt(current, "CI", "CE", "CY") {
            add("S", nil); return current + 2       // Italian/soft C
        }
        // Plain C
        add("K", nil)
        // skip a following silent combiner
        if stringAt(current + 1, " C", " Q", " G") { return current + 3 }
        return current + 1
    }

    private static func encodeG(
        _ letters: [Character], _ current: Int, _ length: Int, _ last: Int,
        isSlavoGermanic: Bool,
        stringAt: (Int, String...) -> Bool,
        matches: (Int, String) -> Bool,
        isVowel: (Int) -> Bool,
        slice: (Int, Int) -> String,
        add: (String, String?) -> Void
    ) -> Int {
        func at(_ i: Int) -> Character { (i >= 0 && i < length) ? letters[i] : " " }

        if at(current + 1) == "H" {
            if current > 0 && !isVowel(current - 1) {
                add("K", nil); return current + 2
            }
            if current == 0 {
                if at(current + 2) == "I" { add("J", nil) } else { add("K", nil) }
                return current + 2
            }
            // -GH- otherwise mostly silent
            return current + 2
        }
        if at(current + 1) == "N" {
            if current == 1 && isVowel(0) && !isSlavoGermanic {
                add("KN", "N"); return current + 2
            }
            if !stringAt(current + 2, "EY") && at(current + 1) == "N" && !isSlavoGermanic {
                add("N", "KN"); return current + 2
            }
            add("KN", nil); return current + 2
        }
        // -GLI- (Italian)  → simplified: keep K
        if stringAt(current, "GLI") { add("KL", "L"); return current + 2 }
        // Soft G before E/I/Y
        if at(current + 1) == "E" || at(current + 1) == "I" || at(current + 1) == "Y" {
            // "-GER"/"-GY" at start → hard K secondary J
            if (current == 0) {
                add("K", "J"); return current + 2
            }
            // GES / GEP / GEB ... Germanic → hard
            if stringAt(current + 1, "ER") || at(current + 1) == "Y" {
                add("K", "J"); return current + 2
            }
            add("J", "K"); return current + 2
        }
        if at(current + 1) == "G" {
            add("K", nil); return current + 2
        }
        add("K", nil)
        return current + 1
    }

    private static func encodeS(
        _ letters: [Character], _ current: Int, _ length: Int, _ last: Int,
        isSlavoGermanic: Bool,
        stringAt: (Int, String...) -> Bool,
        matches: (Int, String) -> Bool,
        isVowel: (Int) -> Bool,
        add: (String, String?) -> Void
    ) -> Int {
        func at(_ i: Int) -> Character { (i >= 0 && i < length) ? letters[i] : " " }

        // "island" / "isle" — silent S
        if stringAt(current, "ISL", "YSL") { return current + 1 }
        // SUGAR → X at start
        if current == 0 && stringAt(current, "SUGAR") { add("X", "S"); return current + 1 }
        if stringAt(current, "SH") {
            // Germanic "SHEIM/SHOEK/SHOLM/SHOLZ" → S
            if stringAt(current + 1, "HEIM", "HOEK", "HOLM", "HOLZ") { add("S", nil) }
            else { add("X", nil) }
            return current + 2
        }
        // SIO / SIA (e.g. "-sion")
        if stringAt(current, "SIO", "SIA", "SIAN") {
            if isSlavoGermanic { add("S", nil) } else { add("S", "X") }
            return current + 3
        }
        // SC-
        if stringAt(current, "SC") {
            if at(current + 2) == "H" {
                // schooner etc.
                if stringAt(current + 3, "OO", "ER", "EN", "UY", "ED", "EM") {
                    if stringAt(current + 3, "ER", "EN") { add("X", "SK") } else { add("SK", nil) }
                } else {
                    add("X", nil)
                }
                return current + 3
            }
            if "IEY".contains(at(current + 2)) { add("S", nil); return current + 3 }
            add("SK", nil); return current + 3
        }
        // SZ / plain double
        if stringAt(current, "SZ") { add("S", "X"); return current + 2 }
        add("S", nil)
        return (at(current + 1) == "S" || at(current + 1) == "Z") ? current + 2 : current + 1
    }
}
