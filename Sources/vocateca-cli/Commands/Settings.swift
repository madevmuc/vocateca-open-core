import Foundation
import VocatecaCore
import Yams

// MARK: - settings / engine commands

/// Generic settings get/set/list plus engine get/set.
///
/// The settings surface is fully generic: it round-trips the ``Settings`` struct
/// through YAML (via ``SettingsStore``/Yams) so every one of the ~90 keys is
/// addressable by its snake_case name without hardcoding a per-field switch.
enum SettingsCommands {

    // MARK: - Load helpers

    /// Loads the current settings as a mutable YAML mapping keyed by snake_case
    /// key names. Uses `SettingsStore.yamlString` so the serialized shape (and
    /// therefore the valid key set) matches exactly what the app writes.
    private static func loadMapping() throws -> Yams.Node {
        let settings = try loadSettings()
        let yaml = try SettingsStore.yamlString(settings)
        guard let node = try Yams.compose(yaml: yaml), node.mapping != nil else {
            throw CLIError("could not parse settings YAML")
        }
        return node
    }

    /// Render a Yams node value to a plain Swift JSON value (for `--json`).
    private static func jsonValue(_ node: Yams.Node) -> Any {
        switch node {
        case .scalar(let s):
            // Try to preserve type: bool / int / double / string.
            let str = s.string
            if str == "true" { return true }
            if str == "false" { return false }
            if let i = Int(str) { return i }
            if let d = Double(str), str.contains(".") || str.contains("e") || str.contains("E") { return d }
            return str
        case .sequence(let seq):
            return seq.map { jsonValue($0) }
        case .mapping(let map):
            var out: [String: Any] = [:]
            for (k, v) in map { out[k.string ?? "\(k)"] = jsonValue(v) }
            return out
        case .alias:
            // YAML anchor reference — settings.yaml never emits these, but the
            // enum is non-exhaustive without it. Fall back to the string form.
            return node.string ?? ""
        }
    }

    /// A short type name for a node, for the `list` output.
    private static func typeName(_ node: Yams.Node) -> String {
        switch node {
        case .scalar(let s):
            let str = s.string
            if str == "true" || str == "false" { return "bool" }
            if Int(str) != nil { return "int" }
            if Double(str) != nil, str.contains(".") { return "double" }
            return "string"
        case .sequence: return "list"
        case .mapping:  return "map"
        case .alias:    return "alias"
        }
    }

    // MARK: - settings <subcommand>

    static func run(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let sub = args.subcommand else {
            throw CLIError("settings requires a subcommand: list | get <key> | set <key> <value>", exitCode: 2)
        }
        switch sub {
        case "list":  try list(asJSON: asJSON)
        case "get":   try get(args, asJSON: asJSON)
        case "set":   try set(args, asJSON: asJSON)
        default:
            throw CLIError("unknown settings subcommand '\(sub)'", exitCode: 2)
        }
    }

    private static func list(asJSON: Bool) throws {
        let node = try loadMapping()
        guard let mapping = node.mapping else { throw CLIError("settings not a mapping") }
        // Deterministic key order.
        let keys = mapping.keys.compactMap { $0.string }.sorted()
        if asJSON {
            var rows: [[String: Any]] = []
            for key in keys {
                guard let v = mapping[Yams.Node(key)] else { continue }
                rows.append(["key": key, "value": jsonValue(v), "type": typeName(v)])
            }
            print(jsonString(rows))
        } else {
            for key in keys {
                guard let v = mapping[Yams.Node(key)] else { continue }
                let val = (try? Yams.serialize(node: v).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                let k = key.padding(toLength: 38, withPad: " ", startingAt: 0)
                let t = typeName(v).padding(toLength: 7, withPad: " ", startingAt: 0)
                print("\(k) \(t) \(val)")
            }
        }
    }

    private static func get(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let key = args.subPositional.first else {
            throw CLIError("settings get requires a <key>", exitCode: 2)
        }
        let node = try loadMapping()
        guard let mapping = node.mapping, let v = mapping[Yams.Node(key)] else {
            throw CLIError("unknown settings key '\(key)'", exitCode: 2)
        }
        if asJSON {
            print(jsonString(["key": key, "value": jsonValue(v), "type": typeName(v)]))
        } else {
            let val = (try? Yams.serialize(node: v).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            print(val)
        }
    }

    private static func set(_ args: ParsedArgs, asJSON: Bool) throws {
        let sp = args.subPositional
        guard sp.count >= 2 else {
            throw CLIError("settings set requires <key> <value>", exitCode: 2)
        }
        let key = sp[0]
        // The value may itself contain spaces; join the remaining positionals.
        let rawValue = sp.dropFirst().joined(separator: " ")

        var node = try loadMapping()
        guard var mapping = node.mapping, mapping[Yams.Node(key)] != nil else {
            throw CLIError("unknown settings key '\(key)'", exitCode: 2)
        }

        // Parse the value as a YAML scalar so `true`/`42`/`auto`/`1.5` get the
        // right node type. Falls back to a plain string when compose fails.
        let parsedNode: Yams.Node
        if let composed = try? Yams.compose(yaml: rawValue), composed.mapping == nil {
            parsedNode = composed
        } else {
            parsedNode = Yams.Node(rawValue)
        }

        let oldNode = mapping[Yams.Node(key)]!
        let oldVal = (try? Yams.serialize(node: oldNode).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let newVal = (try? Yams.serialize(node: parsedNode).trimmingCharacters(in: .whitespacesAndNewlines)) ?? rawValue

        if args.isDryRun {
            emitSuccess(
                ["action": "settings-set", "key": key, "old": oldVal, "new": newVal, "dry_run": true],
                human: "would set \(key): \(oldVal) -> \(newVal) (dry-run)",
                asJSON: asJSON)
            return
        }

        // Apply, re-serialize, validate by decoding, then persist.
        mapping[Yams.Node(key)] = parsedNode
        node.mapping = mapping
        let updatedYAML = try Yams.serialize(node: node)
        let decoded: Settings
        do {
            decoded = try SettingsStore.decode(from: updatedYAML)
        } catch {
            throw CLIError("invalid value for '\(key)': \(error)", exitCode: 2)
        }
        try SettingsStore.save(decoded, to: Paths.settingsURL)

        Log.info("CLI: settings set", component: "CLI",
                 context: [("key", key), ("old", oldVal), ("new", newVal), ("json", "\(asJSON)")])

        emitSuccess(
            ["action": "settings-set", "key": key, "old": oldVal, "new": newVal],
            human: "set \(key): \(oldVal) -> \(newVal)",
            asJSON: asJSON)
    }
}

// MARK: - engine get / set

enum EngineCommands {

    static func run(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let sub = args.subcommand else {
            throw CLIError("engine requires a subcommand: get | set <auto|whisper|qwen>", exitCode: 2)
        }
        switch sub {
        case "get": try get(asJSON: asJSON)
        case "set": try set(args, asJSON: asJSON)
        default:
            throw CLIError("unknown engine subcommand '\(sub)'", exitCode: 2)
        }
    }

    private static func get(asJSON: Bool) throws {
        let settings = try loadSettings()
        let pref = TranscriptionEngine(rawValue: settings.transcriptionEngine) ?? .auto
        let resolved = EngineSelector.resolveLive(preference: pref)
        if asJSON {
            print(jsonString([
                "ok": true,
                "preference": pref.rawValue,
                "resolves_to": resolved.rawValue,
            ]))
        } else {
            print("preference: \(pref.rawValue)")
            print("resolves to: \(resolved.rawValue) (on this Mac)")
        }
    }

    private static func set(_ args: ParsedArgs, asJSON: Bool) throws {
        guard let value = args.subPositional.first else {
            throw CLIError("engine set requires <auto|whisper|qwen>", exitCode: 2)
        }
        guard let pref = TranscriptionEngine(rawValue: value) else {
            throw CLIError("invalid engine '\(value)' (expected auto|whisper|qwen)", exitCode: 2)
        }
        let resolved = EngineSelector.resolveLive(preference: pref)

        if args.isDryRun {
            emitSuccess(
                ["action": "engine-set", "preference": pref.rawValue,
                 "resolves_to": resolved.rawValue, "dry_run": true],
                human: "would set engine to \(pref.rawValue) (resolves to \(resolved.rawValue)) (dry-run)",
                asJSON: asJSON)
            return
        }

        var settings = try loadSettings()
        settings.transcriptionEngine = pref.rawValue
        try SettingsStore.save(settings, to: Paths.settingsURL)

        Log.info("CLI: engine set", component: "CLI",
                 context: [("preference", pref.rawValue), ("resolvesTo", resolved.rawValue), ("json", "\(asJSON)")])

        emitSuccess(
            ["action": "engine-set", "preference": pref.rawValue, "resolves_to": resolved.rawValue],
            human: "engine set to \(pref.rawValue) (resolves to \(resolved.rawValue))",
            asJSON: asJSON)
    }
}
