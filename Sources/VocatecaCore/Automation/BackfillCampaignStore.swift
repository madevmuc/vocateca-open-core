import Foundation

/// Reads/writes/deletes the per-show `BackfillCampaign` blob in StateStore meta.
/// Mirrors `AutomationStatusReporter`.
public struct BackfillCampaignStore: Sendable {
    private let store: StateStore
    public init(store: StateStore) { self.store = store }

    public func read(slug: String) throws -> BackfillCampaign? {
        guard let json = try store.metaValue(BackfillCampaign.metaKey(slug: slug)),
              !json.isEmpty else { return nil }
        return BackfillCampaign.decode(json)
    }
    public func write(slug: String, _ campaign: BackfillCampaign) throws {
        guard let json = campaign.encoded() else { return }
        try store.setMeta(key: BackfillCampaign.metaKey(slug: slug), value: json)
        Log.debug("Backfill campaign written", component: "Backfill",
                  context: [("slug", slug), ("done", "\(campaign.done)"), ("total", "\(campaign.total)")])
    }
    public func delete(slug: String) throws {
        // Use the meta-delete if StateStore has one; otherwise blank the key
        // (read() treats empty as absent).
        try store.setMeta(key: BackfillCampaign.metaKey(slug: slug), value: "")
    }
}
