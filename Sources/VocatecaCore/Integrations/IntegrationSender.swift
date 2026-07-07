import Foundation

// MARK: - NotionTokenProviding

/// Abstraction over "read the stored Notion token" so `IntegrationSender` is
/// testable without the Keychain. `IntegrationSecrets` (Task 1) conforms to
/// this; tests inject a `StubSecrets`.
public protocol NotionTokenProviding: Sendable {
    func notionToken() throws -> String?
}

extension IntegrationSecrets: NotionTokenProviding {}

// MARK: - IntegrationTarget

public enum IntegrationTarget: String, Sendable {
    case notion
}

// MARK: - DeliveryOutcome

public struct DeliveryOutcome: Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

// MARK: - IntegrationSender

/// Pushes an episode's transcript to an external integration (currently only
/// Notion) and records a delivery marker for idempotency + status tracking.
///
/// Pure Core — no UI. Never crashes: every failure path (missing token,
/// missing episode, missing/unreadable transcript, HTTP error) is caught and
/// turned into a failed `DeliveryOutcome` plus an `"error"` delivery marker.
public struct IntegrationSender: Sendable {

    private static let component = "integrations"

    private let notionFactory: @Sendable (String) -> NotionPageCreating

    /// - Parameter notionFactory: Builds a `NotionPageCreating` client from a
    ///   bearer token. Defaults to the real `NotionClient`; tests inject a
    ///   fake so no live network is ever touched.
    public init(notionFactory: @escaping @Sendable (String) -> NotionPageCreating = { NotionClient(token: $0) }) {
        self.notionFactory = notionFactory
    }

    public func send(
        episodeGuid: String,
        to target: IntegrationTarget,
        store: StateStore,
        secrets: NotionTokenProviding,
        settings: Settings
    ) async -> DeliveryOutcome {
        Log.info("Integration push starting", component: Self.component,
                  context: [("guid", episodeGuid), ("target", target.rawValue)])

        // Idempotency: a prior successful delivery for this (integration, guid)
        // means we must not re-post and create a duplicate page. A DB error here
        // (e.g. the `integration_deliveries` table missing on a pre-v4 DB) MUST be
        // logged, not swallowed — a silent failure disables dedupe and produces
        // duplicate Notion pages. On error we log and proceed as "no prior
        // delivery" (the createPage below is the safe default if unsure).
        do {
            if let last = try store.lastDelivery(integration: target.rawValue, episodeGuid: episodeGuid),
               last.status == "ok" {
                Log.info("Integration push skipped — already delivered", component: Self.component,
                          context: [("guid", episodeGuid), ("target", target.rawValue),
                                    ("externalRef", last.externalRef ?? "")])
                return DeliveryOutcome(ok: true, message: "Already delivered (skipped)")
            }
        } catch {
            Log.error("Integration: delivery bookkeeping failed (dedupe check) — proceeding",
                      component: Self.component,
                      context: [("guid", episodeGuid), ("target", target.rawValue), ("error", "\(error)")])
        }

        do {
            // Load episode.
            guard let episode = try store.episode(guid: episodeGuid) else {
                throw IntegrationSendError.episodeNotFound
            }

            // Load transcript text from disk.
            guard let transcriptPath = episode.transcriptPath, !transcriptPath.isEmpty else {
                throw IntegrationSendError.noTranscript
            }
            let transcriptURL = URL(fileURLWithPath: transcriptPath)
            let transcript: String
            do {
                transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
            } catch {
                throw IntegrationSendError.transcriptUnreadable("\(error)")
            }

            // Token + database id.
            guard let token = try secrets.notionToken(), !token.isEmpty else {
                throw IntegrationSendError.missingToken
            }
            guard !settings.notionDatabaseId.isEmpty else {
                throw IntegrationSendError.missingDatabaseId
            }

            // Metadata blocks (source, show, pub date, engine/model, language)
            // + the transcript itself — all in the page BODY, never as DB
            // properties (see NotionClient's "Name"-only doc comment).
            var blocks: [String] = []
            blocks.append("Source: \(episode.mp3Url)")
            blocks.append("Show: \(episode.showSlug)")
            blocks.append("Published: \(episode.pubDate)")
            if let origin = episode.transcriptOrigin, !origin.isEmpty {
                blocks.append("Engine: \(origin)")
            }
            if let lang = episode.detectedLanguage, !lang.isEmpty {
                blocks.append("Language: \(lang)")
            }
            blocks.append(transcript)

            if NotionClient.makeChildren(from: blocks).count >= NotionClient.maxChildrenPerRequest {
                Log.warn("Transcript truncated to fit Notion's per-request block limit",
                          component: Self.component,
                          context: [("guid", episodeGuid), ("limit", "\(NotionClient.maxChildrenPerRequest)")])
            }

            let client = notionFactory(token)
            let pageId = try await client.createPage(
                databaseId: settings.notionDatabaseId,
                title: episode.title,
                properties: [:],
                blocks: blocks
            )

            do {
                try store.recordDelivery(
                    integration: target.rawValue,
                    episodeGuid: episodeGuid,
                    target: settings.notionDatabaseId,
                    status: "ok",
                    externalRef: pageId,
                    errorText: nil
                )
            } catch {
                // The page WAS created; only the success marker failed to persist.
                // Log loudly — a lost "ok" marker means the next run re-posts and
                // creates a duplicate page (the exact dedupe failure this brief fixes).
                Log.error("Integration: delivery bookkeeping failed (recording success) — duplicate risk on next run",
                          component: Self.component,
                          context: [("guid", episodeGuid), ("target", target.rawValue),
                                    ("pageId", pageId), ("error", "\(error)")])
            }
            Log.info("Integration push succeeded", component: Self.component,
                      context: [("guid", episodeGuid), ("target", target.rawValue), ("pageId", pageId)])
            return DeliveryOutcome(ok: true, message: "Created Notion page \(pageId)")

        } catch {
            let errorText = "\(error)"
            do {
                try store.recordDelivery(
                    integration: target.rawValue,
                    episodeGuid: episodeGuid,
                    target: settings.notionDatabaseId.isEmpty ? nil : settings.notionDatabaseId,
                    status: "error",
                    externalRef: nil,
                    errorText: errorText
                )
            } catch {
                Log.error("Integration: delivery bookkeeping failed (recording error marker)",
                          component: Self.component,
                          context: [("guid", episodeGuid), ("target", target.rawValue),
                                    ("bookkeepingError", "\(error)")])
            }
            Log.error("Integration push failed", component: Self.component,
                       context: [("guid", episodeGuid), ("target", target.rawValue), ("error", errorText)])
            return DeliveryOutcome(ok: false, message: errorText)
        }
    }
}

// MARK: - IntegrationSendError

enum IntegrationSendError: Error, CustomStringConvertible {
    case episodeNotFound
    case noTranscript
    case transcriptUnreadable(String)
    case missingToken
    case missingDatabaseId

    var description: String {
        switch self {
        case .episodeNotFound: return "Episode not found"
        case .noTranscript: return "Episode has no transcript"
        case .transcriptUnreadable(let detail): return "Transcript could not be read: \(detail)"
        case .missingToken: return "No Notion token configured"
        case .missingDatabaseId: return "No Notion database id configured"
        }
    }
}
