import Foundation

// MARK: - Show+DisplayName

extension Show {

    /// The effective human-facing display name for this show.
    ///
    /// Precedence: ``customTitle`` (user override) → ``title`` (feed title) →
    /// ``displayHandle`` (derived @handle) → ``author`` → ``slug`` (last-ditch
    /// fallback — the slug must never win when any real name exists).
    ///
    /// `slug` itself is never touched by this computation — it stays the
    /// stable identity key for lookups/paths/keys everywhere else.
    public var displayName: String {
        if let custom = customTitle, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        if !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let handle = displayHandle, !handle.trimmingCharacters(in: .whitespaces).isEmpty {
            return handle
        }
        if let author, !author.trimmingCharacters(in: .whitespaces).isEmpty {
            return author
        }
        return slug
    }

    /// The effective author/publisher subline for this show.
    ///
    /// Precedence: ``creator`` (explicit creator assignment) → ``displayHandle``
    /// (derived @handle) → ``author``. Returns `nil` when none are available
    /// (never falls back to `slug` — this is a subline, not an identity).
    public var displayAuthor: String? {
        if let creator, !creator.trimmingCharacters(in: .whitespaces).isEmpty {
            return creator
        }
        if let handle = displayHandle, !handle.trimmingCharacters(in: .whitespaces).isEmpty {
            return handle
        }
        if let author, !author.trimmingCharacters(in: .whitespaces).isEmpty {
            return author
        }
        return nil
    }
}
