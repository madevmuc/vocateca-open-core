// MARK: - ShowsGrouping

/// How the subscriptions list groups what the user is subscribed to.
///
/// A "person" is not a stored entity: there is no creators file and no creator
/// table. ``CreatorAggregator/aggregate(shows:recentItemsLimit:)`` derives one
/// at load time from `Show.creator` → `Show.author` → the normalised title, so
/// grouping by person is a *view* over the same subscriptions, not a different
/// set of them. That is why this is a mode and not a second screen.
///
/// UI-free on purpose (like ``StartupTabMigration``): the persistence key, the
/// default, and the fallback rule are decisions, so they live where they can be
/// tested without a UI test target. Only the labels belong to the view.
public enum ShowsGrouping: String, CaseIterable, Sendable {

    /// One row per subscription — the shape of what is actually stored.
    case byShow = "byShow"
    /// One row per aggregated person, detail column = their cross-source feed.
    case byPerson = "byPerson"

    /// Grouping for anyone who has never chosen: a show is the thing the user
    /// actually subscribed to, a person is inferred from it. Guessing at the
    /// inferred layer by default would show a first-run library through a lens
    /// the user never asked for — and one that a missing `author` field can
    /// silently degrade into "every show is its own person".
    public static let `default`: ShowsGrouping = .byShow

    /// `UserDefaults` key backing the remembered choice.
    ///
    /// Pinned by a test: changing the string doesn't fail to compile, it just
    /// silently drops every user's saved mode back to the default.
    public static let storageKey = "showsGrouping"

    /// Resolves a persisted raw value to a mode that exists.
    ///
    /// Anything unrecognised — absent, a value from a build that had another
    /// mode, a hand-edited defaults entry — lands on ``default`` rather than
    /// leaving the list with no grouping at all.
    public static func resolve(rawValue: String?) -> ShowsGrouping {
        guard let rawValue, let mode = ShowsGrouping(rawValue: rawValue) else {
            return `default`
        }
        return mode
    }
}
