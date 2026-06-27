# MCP server — design (roadmap 10.3)

- **Date:** 2026-06-27 · **Status:** BUILT (2026-06-27). Real stdio transport on
  top of the registry: `build_server` constructs an `mcp.server.Server` (optional
  `mcp` dep, lazy import → `McpUnavailable`) wiring `list_tools`/`call_tool`
  handlers; `serve_stdio` runs the asyncio loop; `cli.py mcp` is the entrypoint
  (clean error when `mcp` is absent). `list_tools` now emits a per-tool
  `inputSchema`. Tested without `mcp` installed (registry + unavailable path).
- **Shipped (original core):** `core/mcp_server.py` registry (`list_tools`) +
  dispatcher (`call_tool`) reusing the localhost JSON API router
  (`core.api_server.handle_request`).

## Why transport deferred

A real MCP server needs the `mcp` Python package and a stdio event loop. Rather
than add + validate that dependency overnight, the run ships the
transport-independent core so the LLM-operator surface is already defined and
tested; adding the transport is mechanical.

## Architecture

```
LLM client ⇄ (stdio MCP)  ⇄  core/mcp_server  ⇄  core/api_server.handle_request
                                                 ⇄  core/state, watchlist, …
```

Reusing `handle_request` means the MCP tools, the localhost HTTP API, and the
CLI all expose the **same** capabilities with one implementation.

## Tools (shipped registry)

`list_shows`, `queue_status`, `list_queue`, `pause_queue`, `resume_queue` —
each maps to an API method+path. Extending the set = one row in `_TOOLS`.

## Follow-up checklist

- [ ] Add `mcp` as an optional dependency.
- [ ] `core/mcp_server.serve_stdio(ctx)`: register `list_tools`/`call_tool` with
      the MCP server object; run the stdio loop.
- [ ] `cli.py mcp` entrypoint (stdio).
- [ ] Map richer tools (add show, requeue, set-setting) — they already exist in
      `cli.py`; expose via new `_TOOLS` rows + API routes.
- [ ] Auth/consent note: MCP runs locally on behalf of the user, same trust
      level as the CLI.
