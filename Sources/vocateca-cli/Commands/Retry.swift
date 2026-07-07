import Foundation
import VocatecaCore

// MARK: - retry <guids> | retry --all [--show S]

enum RetryCommand {

    static func run(_ args: ParsedArgs, asJSON: Bool) throws {
        let all = args.flags.contains("all")
        let showFilter = args.opts["show"]

        // Resolve the guids to retry.
        var guids: [String]
        if all {
            guard let reader = try StateReader.openProductionForReading() else {
                throw CLIError("state.sqlite not found")
            }
            guids = try reader.fetchFailed(showSlug: showFilter, limit: 0).map { $0.guid }
        } else {
            guids = args.positional
            guard !guids.isEmpty else {
                throw CLIError("retry requires <guid…> or --all", exitCode: 2)
            }
        }

        if guids.isEmpty {
            emitSuccess(["action": "retry", "count": 0, "guids": [] as [String]],
                        human: "no failed episodes to retry", asJSON: asJSON)
            return
        }

        if args.isDryRun {
            emitSuccess(["action": "retry", "count": guids.count, "guids": guids,
                         "all": all, "dry_run": true],
                        human: "would retry \(guids.count) episode(s) (dry-run)", asJSON: asJSON)
            return
        }

        let store = try openWritableStore()
        for guid in guids {
            try store.enqueueFront(guid: guid)
        }

        Log.info("CLI: retry", component: "CLI",
                 context: [("count", "\(guids.count)"), ("all", "\(all)"), ("json", "\(asJSON)")])

        emitSuccess(["action": "retry", "count": guids.count, "guids": guids, "all": all],
                    human: "re-enqueued \(guids.count) episode(s) at the front of the queue", asJSON: asJSON)
    }
}
