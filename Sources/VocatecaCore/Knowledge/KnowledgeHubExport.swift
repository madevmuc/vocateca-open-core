import Foundation

// MARK: - KnowledgeHub

/// Resolves the extra "export" destination roots a transcript should be mirrored
/// to, on top of the primary library (`outputRoot`). Pure + testable — the actual
/// file copy lives in ``MarkdownLibraryWriter``.
///
/// Wires `Settings.exportRoot` (a general export destination) and the combined
/// **Knowledge-Hub** feature (`obsidianVaultPath` + `obsidianVaultName` +
/// `knowledgeHubRoot`) — Obsidian *is* the knowledge hub.
public enum KnowledgeHub {

    /// The configured export roots (parent dirs of the per-show subfolder). Empty
    /// when nothing is configured. Tilde-expanded and de-duplicated, order
    /// preserved (exportRoot, then Obsidian vault, then knowledge-hub root).
    public static func exportRoots(
        exportRoot: String,
        obsidianVaultPath: String,
        obsidianVaultName: String,
        knowledgeHubRoot: String
    ) -> [URL] {
        var roots: [String] = []

        func addExpanded(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            roots.append((t as NSString).expandingTildeInPath)
        }

        addExpanded(exportRoot)

        // Obsidian vault: base path plus an optional vault-name subfolder.
        let vaultBase = obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vaultBase.isEmpty {
            let base = (vaultBase as NSString).expandingTildeInPath
            let name = obsidianVaultName.trimmingCharacters(in: .whitespacesAndNewlines)
            roots.append(name.isEmpty ? base : (base as NSString).appendingPathComponent(name))
        }

        addExpanded(knowledgeHubRoot)

        // De-dupe, preserve order.
        var seen = Set<String>()
        return roots.compactMap { path in
            seen.insert(path).inserted ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }
}
