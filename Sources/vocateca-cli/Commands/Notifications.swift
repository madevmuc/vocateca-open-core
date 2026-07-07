import Foundation
import VocatecaCore

// MARK: - notifications <subcommand>

enum NotificationsCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let sub = args.subcommand else {
            throw CLIError("notifications requires a subcommand: list | read | delete", exitCode: 2)
        }
        let db: NotificationsDatabase
        do {
            db = try NotificationsDatabase(url: Paths.notificationsDatabaseURL)
        } catch {
            throw CLIError("could not open notifications database: \(error)")
        }
        switch sub {
        case "list":   try list(args, db: db, asJSON: asJSON)
        case "read":   try read(args, db: db, asJSON: asJSON)
        case "delete": try delete(args, db: db, asJSON: asJSON)
        default:
            throw CLIError("unknown notifications subcommand '\(sub)'", exitCode: 2)
        }
    }

    private static func list(_ args: ParsedArgs, db: NotificationsDatabase, asJSON: Bool) throws {
        var records = try db.fetchAll()
        if args.flags.contains("unread") {
            records = records.filter { $0.isUnread }
        }
        if let limit = Int(args.opts["limit"] ?? ""), limit > 0 {
            records = Array(records.prefix(limit))
        }
        if asJSON {
            let rows = records.map { r -> [String: Any] in
                [
                    "id": r.id,
                    "kind": r.kind,
                    "title": r.title,
                    "detail": r.detail,
                    "timestamp": r.timestamp,
                    "unread": r.isUnread,
                    "action_label": r.actionLabel as Any? ?? NSNull(),
                    "created_at": r.createdAt,
                    "episode_guid": r.episodeGuid as Any? ?? NSNull(),
                    "show_slug": r.showSlug as Any? ?? NSNull(),
                ]
            }
            print(jsonString(rows))
        } else {
            if records.isEmpty { print("(no notifications)"); return }
            for r in records {
                let mark = r.isUnread ? "●" : " "
                print("\(mark) [\(r.kind)] \(r.title)")
                if !r.detail.isEmpty { print("    \(r.detail)") }
                print("    id: \(r.id)  \(r.timestamp)")
            }
        }
    }

    private static func read(_ args: ParsedArgs, db: NotificationsDatabase, asJSON: Bool) throws {
        if args.flags.contains("all") {
            if args.isDryRun {
                emitSuccess(["action": "notifications-read", "scope": "all", "dry_run": true],
                            human: "would mark all notifications read (dry-run)", asJSON: asJSON)
                return
            }
            try db.markAllRead()
            Log.info("CLI: notifications read-all", component: "CLI", context: [("json", "\(asJSON)")])
            emitSuccess(["action": "notifications-read", "scope": "all"],
                        human: "marked all notifications read", asJSON: asJSON)
            return
        }
        guard let id = args.subPositional.first else {
            throw CLIError("notifications read requires an <id> or --all", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "notifications-read", "id": id, "dry_run": true],
                        human: "would mark '\(id)' read (dry-run)", asJSON: asJSON)
            return
        }
        try db.setRead(id: id, read: true)
        Log.info("CLI: notifications read", component: "CLI", context: [("id", id), ("json", "\(asJSON)")])
        emitSuccess(["action": "notifications-read", "id": id],
                    human: "marked '\(id)' read", asJSON: asJSON)
    }

    private static func delete(_ args: ParsedArgs, db: NotificationsDatabase, asJSON: Bool) throws {
        if args.flags.contains("all") {
            if args.isDryRun {
                emitSuccess(["action": "notifications-delete", "scope": "all", "dry_run": true],
                            human: "would delete all notifications (dry-run)", asJSON: asJSON)
                return
            }
            try db.deleteAll()
            Log.info("CLI: notifications delete-all", component: "CLI", context: [("json", "\(asJSON)")])
            emitSuccess(["action": "notifications-delete", "scope": "all"],
                        human: "deleted all notifications", asJSON: asJSON)
            return
        }
        guard let id = args.subPositional.first else {
            throw CLIError("notifications delete requires an <id> or --all", exitCode: 2)
        }
        if args.isDryRun {
            emitSuccess(["action": "notifications-delete", "id": id, "dry_run": true],
                        human: "would delete '\(id)' (dry-run)", asJSON: asJSON)
            return
        }
        try db.delete(id: id)
        Log.info("CLI: notifications delete", component: "CLI", context: [("id", id), ("json", "\(asJSON)")])
        emitSuccess(["action": "notifications-delete", "id": id],
                    human: "deleted '\(id)'", asJSON: asJSON)
    }
}
