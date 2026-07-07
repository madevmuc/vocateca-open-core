import Foundation
import VocatecaCore

// MARK: - integrations <subcommand>

enum IntegrationsCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let sub = args.subcommand else {
            throw CLIError("integrations requires a subcommand: list | test", exitCode: 2)
        }
        switch sub {
        case "list": try list(args, asJSON: asJSON)
        case "test": try test(args, asJSON: asJSON)
        default:
            throw CLIError("unknown integrations subcommand '\(sub)'", exitCode: 2)
        }
    }

    // MARK: - list

    private static func list(_ args: ParsedArgs, asJSON: Bool) throws {
        let settings = try loadSettings()
        let tokenPresent = ((try? IntegrationSecrets().notionToken()) ?? nil) != nil

        if asJSON {
            print(jsonString([
                "notion": [
                    "enabled": settings.notionEnabled,
                    "auto_push": settings.notionAutoPush,
                    "database_id": settings.notionDatabaseId,
                    "token_present": tokenPresent,
                ],
            ]))
        } else {
            print("notion:")
            print("  enabled:       \(settings.notionEnabled)")
            print("  auto_push:     \(settings.notionAutoPush)")
            print("  database_id:   \(settings.notionDatabaseId.isEmpty ? "(none)" : settings.notionDatabaseId)")
            print("  token_present: \(tokenPresent)")
        }
    }

    // MARK: - test

    private static func test(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let to = args.opts["to"], !to.isEmpty else {
            throw CLIError("integrations test requires --to <target> (supported: notion)", exitCode: 2)
        }
        guard to == "notion" else {
            throw CLIError("unsupported --to target '\(to)' (supported: notion)", exitCode: 2)
        }

        let settings = try loadSettings()
        let tokenPresent = ((try? IntegrationSecrets().notionToken()) ?? nil) != nil
        let databaseIdPresent = !settings.notionDatabaseId.isEmpty

        // v1: config validation only — no live Notion API call is made here, so
        // this never hangs on network I/O. A real API ping (e.g. querying the
        // database) is a future enhancement, not built in this pass.
        var missing: [String] = []
        if !tokenPresent { missing.append("notion_token (Keychain)") }
        if !databaseIdPresent { missing.append("notion_database_id (Settings)") }
        let ready = missing.isEmpty

        Log.info("CLI: integrations test", component: "CLI",
                 context: [("target", "notion"), ("ready", "\(ready)"), ("json", "\(asJSON)")])

        if asJSON {
            print(jsonString([
                "ok": true,
                "target": "notion",
                "status": ready ? "ready" : "needs_attention",
                "missing": missing,
                "note": "config validation only — no live Notion API call is made",
            ]))
        } else {
            if ready {
                print("notion: ready (token + database_id configured; config check only, no live API call made)")
            } else {
                print("notion: needs_attention — missing: \(missing.joined(separator: ", ")) (config check only, no live API call made)")
            }
        }
        if !ready {
            exit(2)
        }
    }
}
