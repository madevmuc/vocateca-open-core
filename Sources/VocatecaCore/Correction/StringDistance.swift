import Foundation

/// String-similarity primitives for the transcript corrector.
public enum StringDistance {

    /// Levenshtein edit distance between `a` and `b`, bounded by `max`.
    ///
    /// The comparison is case-insensitive and diacritic-insensitive (so
    /// `Fertina` ~ `firtina`). Uses the two-row dynamic-programming variant
    /// with an **early exit**: as soon as every cell in a row exceeds `max`,
    /// no completion can come in at or under budget, so the function stops and
    /// returns the sentinel `max + 1` (meaning "further than `max` edits").
    /// A length gap greater than `max` short-circuits immediately.
    ///
    /// - Returns: the exact distance when it is `<= max`, otherwise `max + 1`.
    public static func levenshtein(_ a: String, _ b: String, max: Int) -> Int {
        // Normalise for a fair phonetic-neighbour comparison.
        func norm(_ s: String) -> [Character] {
            Array(s.folding(options: .diacriticInsensitive, locale: .current).lowercased())
        }
        let s = norm(a)
        let t = norm(b)
        let m = s.count
        let n = t.count

        if max < 0 { return (m == n && s == t) ? 0 : 0 }
        if m == 0 { return n <= max ? n : max + 1 }
        if n == 0 { return m <= max ? m : max + 1 }
        // A length difference alone already exceeds the budget.
        if abs(m - n) > max { return max + 1 }

        let over = max + 1
        var previous = Array(0...n)          // row 0: 0,1,2,…,n
        var current = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            current[0] = i
            var rowMin = i
            let sc = s[i - 1]
            for j in 1...n {
                let cost = (sc == t[j - 1]) ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + cost
                let best = Swift.min(deletion, Swift.min(insertion, substitution))
                current[j] = best
                if best < rowMin { rowMin = best }
            }
            // Early exit: no cell in this row is within budget.
            if rowMin > max { return over }
            swap(&previous, &current)
        }

        let dist = previous[n]
        return dist <= max ? dist : over
    }
}
