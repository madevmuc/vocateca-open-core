import Foundation

// MARK: - AddClipboardPrefill

/// The pure "should we prefill the Add router's fast-path field from the
/// clipboard" decision — extracted so it is unit-testable WITHOUT `NSPasteboard`
/// or a UI harness.
///
/// The router reads `NSPasteboard.general` exactly once, on sheet appear
/// (see `AddRouterSheet`), never on a timer/focus-poll. This type answers two
/// separate questions the view then acts on:
///  1. Does the clipboard string look like something the Add flow understands
///     at all (`AddSourceClassifier.classify` != `.none`)?
///  2. Would prefilling it just re-nag the user with a value they already
///     acted on this session (the "repeat suppression" rule)?
public enum AddClipboardPrefill {

    /// Whether `clipboard` should prefill the fast-path field, given the most
    /// recent value the user already added successfully this session
    /// (`lastAdded`, `nil` if nothing has been added yet).
    ///
    /// Rules (first match wins):
    /// 1. Empty/whitespace-only clipboard → never prefill.
    /// 2. A clipboard string the classifier can't recognise (`.none`) → never
    ///    prefill (nothing useful to seed the field with).
    /// 3. A clipboard string equal to `lastAdded` (exact match after trimming
    ///    whitespace on both sides) → never prefill — avoids re-suggesting a
    ///    value the user just subscribed/imported in this very session.
    /// 4. Otherwise → prefill.
    public static func shouldPrefill(clipboard: String?, lastAdded: String?) -> Bool {
        guard let raw = clipboard else { return false }
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        guard AddSourceClassifier.classify(candidate) != .none else { return false }
        if let lastAdded {
            let normalizedLast = lastAdded.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedLast == candidate { return false }
        }
        return true
    }
}
