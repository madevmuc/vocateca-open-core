import Foundation
import VocatecaCore

/// A minimal, hand-rolled MCP (Model Context Protocol) server exposed as
/// `vocateca-cli mcp`. Speaks newline-delimited JSON-RPC 2.0 over stdin/stdout
/// so an AI assistant can drive the app.
///
/// Protocol contract:
///   - One JSON object per line on stdin (read via `readLine`), one JSON
///     object per line on stdout (write + flush).
///   - **stdout is reserved for protocol messages only.** All logging and
///     diagnostics MUST go to stderr — a stray stdout write corrupts the
///     stream for the client.
///   - Requests carry an `id` and get a response; notifications have no `id`
///     and get no response.
///
/// Task 2 implements the read loop + the `initialize` handshake (plus the
/// trivial `notifications/initialized` / `ping` no-ops). Task 3 implements
/// `tools/list` (derived from `CLICommandCatalog` via `MCPToolMapping`) and
/// `tools/call` (dispatches to the CLI itself as a subprocess with `--json`).
struct MCPServer {

    /// The MCP protocol version this server speaks when the client doesn't
    /// specify one (or as a fallback echo target).
    private static let defaultProtocolVersion = "2024-11-05"

    /// `name -> Tool` map derived once from the catalog. Built lazily per
    /// server instance (the process is short-lived; no need to cache further).
    private let toolsByName: [String: MCPToolMapping.Tool] = MCPToolMapping.toolsByName()

    func run() {
        logDiagnostic("vocateca-cli mcp: server starting")

        while let line = readLine(strippingNewline: true) {
            // Ignore blank lines some clients send between messages.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            handleLine(trimmed)
        }

        logDiagnostic("vocateca-cli mcp: stdin closed, exiting")
    }

    // MARK: - Per-line handling

    private func handleLine(_ line: String) {
        guard let lineData = line.data(using: .utf8) else {
            writeResponse(errorResponse(id: .null, code: -32700, message: "Parse error: invalid UTF-8"))
            return
        }

        let parsedObject: Any
        do {
            parsedObject = try JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
        } catch {
            logDiagnostic("parse error: \(error)")
            writeResponse(errorResponse(id: .null, code: -32700, message: "Parse error: \(error.localizedDescription)"))
            return
        }

        guard let object = parsedObject as? [String: Any] else {
            writeResponse(errorResponse(id: .null, code: -32700, message: "Parse error: expected a JSON object"))
            return
        }

        let id = RPCID(anyValue: object["id"])
        let isNotification = (object["id"] == nil)
        guard let method = object["method"] as? String else {
            if !isNotification {
                writeResponse(errorResponse(id: id, code: -32600, message: "Invalid Request: missing method"))
            }
            return
        }
        let params = object["params"] as? [String: Any] ?? [:]

        let result = dispatch(method: method, params: params)

        // Notifications (no `id`) never get a response, even on error.
        guard !isNotification else { return }

        switch result {
        case .result(let value):
            writeResponse(["jsonrpc": "2.0", "id": id.jsonValue, "result": value])
        case .error(let code, let message):
            writeResponse(errorResponse(id: id, code: code, message: message))
        }
    }

    // MARK: - Method dispatch

    private enum DispatchResult {
        case result(Any)
        case error(code: Int, message: String)
    }

    private func dispatch(method: String, params: [String: Any]) -> DispatchResult {
        switch method {
        case "initialize":
            return handleInitialize(params: params)

        case "notifications/initialized":
            // No-op acknowledgement; caller already filters notifications
            // (no `id`) before responding, but guard here too for safety.
            return .result([:])

        case "ping":
            return .result([:])

        case "tools/list":
            return handleToolsList()

        case "tools/call":
            return handleToolsCall(params: params)

        default:
            return .error(code: -32601, message: "Method not found")
        }
    }

    private func handleInitialize(params: [String: Any]) -> DispatchResult {
        let protocolVersion = (params["protocolVersion"] as? String) ?? Self.defaultProtocolVersion
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [
                "tools": [:]
            ],
            "serverInfo": [
                "name": "vocateca",
                "version": Vocateca.version,
            ],
        ]
        return .result(result)
    }

    // MARK: - tools/list

    /// Derives the tool catalog from `CLICommandCatalog` (via `MCPToolMapping`)
    /// and returns `{tools: [...]}` — one entry per documented CLI command,
    /// ordered as in the catalog.
    private func handleToolsList() -> DispatchResult {
        let ordered = MCPToolMapping.tools()
        let entries = ordered.map { $0.listEntry }
        return .result(["tools": entries])
    }

    // MARK: - tools/call

    /// Dispatches `{name, arguments}` to the CLI itself, run as a subprocess
    /// with `--json` (and `--dry-run` when the tool is mutating and the caller
    /// passed `dry_run: true`). Never throws/crashes on a failing invocation —
    /// a non-zero exit is reported as `isError: true` with the captured output
    /// as the content text.
    private func handleToolsCall(params: [String: Any]) -> DispatchResult {
        guard let name = params["name"] as? String else {
            return .error(code: -32602, message: "Missing required param: name")
        }
        guard let tool = toolsByName[name] else {
            return .error(code: -32602, message: "Unknown tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        let argv = MCPToolMapping.argv(for: tool.doc, arguments: arguments)
        let invocation = runCLISubprocess(argv: argv)

        let text = invocation.stdout.isEmpty ? invocation.stderr : invocation.stdout
        let content: [[String: Any]] = [
            ["type": "text", "text": text],
        ]
        return .result([
            "content": content,
            "isError": invocation.exitCode != 0,
        ])
    }

    /// Runs the SAME `vocateca-cli` binary as a subprocess with `argv`,
    /// capturing stdout and stderr separately. Resolves `CommandLine.arguments[0]`
    /// to an absolute path first (SwiftPM/Xcode can invoke us with a relative
    /// path, and `Process.executableURL` needs an absolute one).
    private func runCLISubprocess(argv: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let selfPath = resolvedSelfExecutablePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfPath)
        process.arguments = argv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ("", "failed to launch subprocess: \(error)", 1)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        return (stdout, stderr, process.terminationStatus)
    }

    /// Resolves `CommandLine.arguments[0]` to an absolute path. If it is
    /// already absolute, returns it as-is; otherwise resolves it against the
    /// current working directory via `realpath`, falling back to
    /// `FileManager.currentDirectoryPath` joining if `realpath` fails.
    private func resolvedSelfExecutablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") {
            return raw
        }
        if let resolved = realpath(raw, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(raw)
    }

    // MARK: - JSON-RPC id handling

    /// JSON-RPC ids may be a string, a number, or null — this wraps whichever
    /// came in so we can echo it back verbatim.
    private struct RPCID {
        let jsonValue: Any

        init(anyValue: Any?) {
            self.jsonValue = anyValue ?? NSNull()
        }

        static var null: RPCID { RPCID(anyValue: nil) }
    }

    private func errorResponse(id: RPCID, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    // MARK: - I/O

    /// Writes a single-line JSON object to stdout and flushes it immediately.
    /// This is the ONLY place this file should touch stdout.
    private func writeResponse(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let jsonLine = String(data: data, encoding: .utf8) else {
            logDiagnostic("failed to encode response: \(object)")
            return
        }
        print(jsonLine)
        fflush(stdout)
    }

    /// All logging/diagnostics go to stderr — stdout is reserved for protocol
    /// messages only.
    private func logDiagnostic(_ message: String) {
        fputs("[vocateca-cli mcp] \(message)\n", stderr)
    }
}
