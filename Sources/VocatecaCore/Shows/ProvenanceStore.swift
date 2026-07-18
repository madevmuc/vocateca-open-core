import Foundation

/// Durable per-slug provenance persistence over the DB `meta` table. This is
/// the orphaning-proof home for a show's origin (`watchlist.yaml` is the file
/// whose loss defines "orphaned", so provenance cannot live there).
public struct ProvenanceStore: Sendable {
    private let store: StateStore
    public init(store: StateStore) { self.store = store }

    /// Idempotent upsert keyed by slug. Guards against blanking a good
    /// `sourceURL` with an empty one; `capturedAt` still advances.
    public func write(slug: String, provenance: ShowProvenance) throws {
        var next = provenance
        if let existing = try read(slug: slug) {
            // Never blank a good sourceURL with an empty one (a refresh that
            // failed to resolve the address must not erase what we had).
            if next.sourceURL.trimmingCharacters(in: .whitespaces).isEmpty,
               !existing.sourceURL.isEmpty {
                next.sourceURL = existing.sourceURL
            }
            // Preserve an active deferral: `write`/`capture` build a fresh record
            // without `deferredUntil`, but only `clearDefer` (which bypasses
            // `write`) should clear a "retry tomorrow" snooze. An expired stamp is
            // harmless — `isDeferred` compares against `now`.
            if next.deferredUntil == nil {
                next.deferredUntil = existing.deferredUntil
            }
        }
        try store.setMeta(key: ShowProvenance.metaKey(slug: slug),
                          value: next.jsonString())
    }

    /// Convenience: capture provenance for a show at subscribe/refresh time.
    public func capture(slug: String, platform: SourcePlatform, sourceURL: String) throws {
        try write(slug: slug, provenance: ShowProvenance(
            platform: platform, sourceURL: sourceURL,
            capturedAt: ISO8601DateFormatter().string(from: Date())))
    }

    public func read(slug: String) throws -> ShowProvenance? {
        guard let raw = try store.metaValue(ShowProvenance.metaKey(slug: slug)),
              !raw.isEmpty else { return nil }
        return try? ShowProvenance(jsonString: raw)
    }

    /// Returns the stored provenance, or reconstructs it from episode rows and
    /// caches the result.
    public func resolve(slug: String) throws -> ShowProvenance {
        if let stored = try read(slug: slug) { return stored }
        // `StateReader(dbQueue:)` is an internal (module-visible) initializer —
        // ProvenanceStore lives in the same VocatecaCore module, so it can
        // reuse the store's own queue instead of re-opening the DB file via
        // the public `StateReader(databaseURL:)` initializer.
        let reader = StateReader(dbQueue: store.dbQueue)
        let episodes = (try? reader.fetchEpisodesBySlug(
            showSlug: slug, statusFilter: nil, limit: 200)) ?? []
        let signals = episodes.map {
            ProvenanceRecovery.EpisodeSignal(
                guid: $0.guid, mp3Url: $0.mp3Url, igProfile: $0.igProfile)
        }
        var recovered = ProvenanceRecovery.recover(slug: slug, signals: signals)
        recovered.capturedAt = ISO8601DateFormatter().string(from: Date())
        Log.info("Reconstructed provenance from episode rows",
                 component: "Provenance",
                 context: [("slug", slug), ("platform", recovered.platform.rawValue)])
        try? write(slug: slug, provenance: recovered)
        return recovered
    }

    /// Soft-defer this show's reconnect until `date` (e.g. Instagram "retry
    /// tomorrow"). Read-modify-write of the record's `deferredUntil`. If no record
    /// exists yet, creates a minimal one so the deferral persists.
    public func deferUntil(slug: String, until date: Date) throws {
        var rec = (try? read(slug: slug)) ?? ShowProvenance(
            platform: .instagram, sourceURL: "",
            capturedAt: ISO8601DateFormatter().string(from: Date()))
        rec.deferredUntil = ISO8601DateFormatter().string(from: date)
        try store.setMeta(key: ShowProvenance.metaKey(slug: slug), value: rec.jsonString())
    }

    public func clearDefer(slug: String) throws {
        guard var rec = try read(slug: slug) else { return }
        rec.deferredUntil = nil
        try store.setMeta(key: ShowProvenance.metaKey(slug: slug), value: rec.jsonString())
    }

    /// True when a reconnect is deferred and the deferral has not yet expired.
    public func isDeferred(slug: String, now: Date = Date()) throws -> Bool {
        guard let rec = try read(slug: slug),
              let iso = rec.deferredUntil,
              let until = ISO8601DateFormatter().date(from: iso) else { return false }
        return until > now
    }
}
