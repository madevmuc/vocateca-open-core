import Foundation
import GRDB

/// A single delivery attempt of an episode's transcript to an external
/// integration (e.g. Notion, a generic webhook).
///
/// Rows in `integration_deliveries` are append-only markers used for two
/// purposes:
///   - **Idempotency**: check `lastDelivery(integration:episodeGuid:)` before
///     re-pushing the same transcript.
///   - **Status tracking**: surface delivery history/errors in the UI.
///
/// Additive table (see `Schema.v4_integration_deliveries`) — unknown to the
/// v1 Python app, same pattern as `watchlist_hits`.
public struct IntegrationDelivery: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {

    public static let databaseTableName = "integration_deliveries"

    /// Stable unique id for this delivery attempt (UUID string).
    public var id: String
    /// Which integration this delivery targeted, e.g. `"notion"`, `"webhook"`.
    public var integration: String
    /// The episode this delivery relates to. `nil` for non-episode deliveries.
    public var episodeGuid: String?
    /// Integration-specific destination (e.g. a Notion database id, a webhook URL).
    public var target: String?
    /// Delivery outcome, e.g. `"ok"`, `"error"`.
    public var status: String
    /// Integration-specific reference to the created/updated remote object
    /// (e.g. a Notion page id).
    public var externalRef: String?
    /// ISO-8601 timestamp of the delivery attempt.
    public var deliveredAt: String
    /// Error detail when `status != "ok"`.
    public var errorText: String?

    enum CodingKeys: String, CodingKey {
        case id, integration
        case episodeGuid  = "episode_guid"
        case target, status
        case externalRef  = "external_ref"
        case deliveredAt  = "delivered_at"
        case errorText    = "error_text"
    }

    public init(
        id: String,
        integration: String,
        episodeGuid: String?,
        target: String?,
        status: String,
        externalRef: String?,
        deliveredAt: String,
        errorText: String?
    ) {
        self.id = id
        self.integration = integration
        self.episodeGuid = episodeGuid
        self.target = target
        self.status = status
        self.externalRef = externalRef
        self.deliveredAt = deliveredAt
        self.errorText = errorText
    }
}
