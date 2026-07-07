import Foundation

// MARK: - MCPToolMapping
//
// Pure (no I/O) logic that maps the CLI's declarative `CLICommandCatalog` onto
// MCP (Model Context Protocol) `tools/list` entries, and maps a `tools/call`
// request back onto a CLI argv. Kept in `VocatecaCore` (not the `vocateca-cli`
// executable target) so it is unit-testable from `VocatecaCoreTests` — Swift
// test targets cannot `@testable import` an executable target.
//
// The actual process-spawning glue (subprocess invocation, stdout/stderr
// capture, JSON-RPC framing) lives in `vocateca-cli`'s `MCP/MCPServer.swift`
// and consumes this file's pure functions.
public enum MCPToolMapping {

    /// One derived MCP tool, paired with the `CLICommandDoc` it came from so
    /// `tools/call` can look up how to build argv for it.
    public struct Tool: Sendable {
        public let name: String
        public let doc: CLICommandDoc

        public init(name: String, doc: CLICommandDoc) {
            self.name = name
            self.doc = doc
        }

        /// The MCP `tools/list` entry for this tool: `{name, description, inputSchema}`.
        public var listEntry: [String: Any] {
            [
                "name": name,
                "description": MCPToolMapping.description(for: doc),
                "inputSchema": MCPToolMapping.inputSchema(for: doc),
            ]
        }
    }

    /// Builds the full tool list from the catalog, guaranteeing unique names.
    /// Order follows `CLICommandCatalog.all`.
    public static func tools(from catalog: [CLICommandDoc] = CLICommandCatalog.all) -> [Tool] {
        var used = Set<String>()
        var result: [Tool] = []
        result.reserveCapacity(catalog.count)
        for doc in catalog {
            let name = uniqueName(for: doc, avoiding: used)
            used.insert(name)
            result.append(Tool(name: name, doc: doc))
        }
        return result
    }

    /// Convenience: `name -> Tool` map for `tools/call` lookup.
    public static func toolsByName(from catalog: [CLICommandDoc] = CLICommandCatalog.all) -> [String: Tool] {
        var map: [String: Tool] = [:]
        for tool in tools(from: catalog) { map[tool.name] = tool }
        return map
    }

    // MARK: - Name derivation

    /// The literal command path: leading tokens of `doc.command` that are NOT
    /// a `<placeholder>`/`[optional]` and are NOT a `--flag` token, joined by
    /// `_`. E.g. `"sources add-podcast <feed-url>"` -> `"sources_add-podcast"`,
    /// `"status"` -> `"status"`, `"retry --all"` -> `"retry"`.
    public static func basePath(for doc: CLICommandDoc) -> [String] {
        var path: [String] = []
        for token in doc.command.split(separator: " ") {
            let t = String(token)
            if t.hasPrefix("<") || t.hasPrefix("[") || t.hasPrefix("--") {
                break
            }
            path.append(t)
        }
        return path
    }

    /// The base tool name (path joined by `_`), before uniqueness disambiguation.
    public static func baseName(for doc: CLICommandDoc) -> String {
        basePath(for: doc).joined(separator: "_")
    }

    /// Derives a unique tool name for `doc`, given the set of names already
    /// used by earlier catalog entries. The catalog has exactly one known
    /// collision (`retry <guid…>` / `retry --all`, both base-path `retry`) —
    /// documentation variants of the same top-level command. On collision we
    /// disambiguate deterministically using the first `--flag` token present
    /// in `doc.command` (e.g. `retry --all` -> `retry_all`); if no flag token
    /// is present, we fall back to a numeric suffix so uniqueness always holds.
    static func uniqueName(for doc: CLICommandDoc, avoiding used: Set<String>) -> String {
        let base = baseName(for: doc)
        guard used.contains(base) else { return base }

        if let flagToken = doc.command.split(separator: " ").first(where: { $0.hasPrefix("--") }) {
            let suffix = String(flagToken.dropFirst(2))
            let candidate = "\(base)_\(suffix)"
            if !used.contains(candidate) { return candidate }
        }

        var index = 2
        while used.contains("\(base)_\(index)") { index += 1 }
        return "\(base)_\(index)"
    }

    // MARK: - Description

    public static func description(for doc: CLICommandDoc) -> String {
        doc.mutating ? "\(doc.summary) (mutating)" : doc.summary
    }

    // MARK: - inputSchema

    /// JSON Schema `{type:"object", properties:{...}, required:[...]}` built
    /// from `doc.arguments`. Mutating commands additionally get a `dry_run`
    /// boolean property (never required) so a caller can preview without
    /// writing.
    public static func inputSchema(for doc: CLICommandDoc) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for arg in doc.arguments {
            properties[arg.name] = [
                "type": jsonSchemaType(for: arg.type),
                "description": arg.description,
            ]
            if arg.required {
                required.append(arg.name)
            }
        }

        if doc.mutating {
            properties["dry_run"] = [
                "type": "boolean",
                "description": "Preview without writing",
            ]
        }

        return [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
    }

    private static func jsonSchemaType(for type: CLIArgType) -> String {
        switch type {
        case .string:  return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        }
    }

    // MARK: - argv construction (tools/call)

    /// Builds the CLI argv (excluding the executable path itself) for invoking
    /// `doc` with the structured MCP `arguments` dict. Always appends
    /// `--json`; appends `--dry-run` when `doc.mutating` and
    /// `arguments["dry_run"] == true`.
    public static func argv(for doc: CLICommandDoc, arguments: [String: Any]) -> [String] {
        var argv = basePath(for: doc)

        for arg in doc.arguments {
            guard let raw = arguments[arg.name] else { continue }

            if !arg.isFlag {
                // Positional: append the stringified value.
                argv.append(stringify(raw))
                continue
            }

            if arg.type == .boolean {
                if boolValue(raw) == true {
                    argv.append("--\(arg.name)")
                }
            } else {
                argv.append("--\(arg.name)")
                argv.append(stringify(raw))
            }
        }

        argv.append("--json")

        if doc.mutating, boolValue(arguments["dry_run"]) == true {
            argv.append("--dry-run")
        }

        return argv
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" }
        return nil
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        return "\(value)"
    }
}
