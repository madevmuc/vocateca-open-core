"""MCP server (roadmap 10.3).

A Model Context Protocol wrapper that lets an LLM client drive Paragraphos over
**stdio**. The transport-independent core is a tool registry + ``call_tool``
dispatcher that reuses the localhost API router
(``core.api_server.handle_request``); :func:`serve_stdio` wires the real MCP
stdio transport on top of it.

The ``mcp`` package is an optional dependency, lazy-imported: building the server
without it raises :class:`McpUnavailable` with an actionable message. The
registry + dispatch are importable and unit-tested without ``mcp`` installed.
"""

from __future__ import annotations

import json

from core.api_server import handle_request

# Tool name → (description, method, path). Mirrors the JSON API surface. All
# current tools are argument-less, so they share the empty-object input schema.
_TOOLS = {
    "list_shows": ("List all shows in the watchlist.", "GET", "/shows"),
    "queue_status": ("Queue depth + by-status counts.", "GET", "/status"),
    "list_queue": ("List pending episodes in the queue.", "GET", "/queue"),
    "pause_queue": ("Pause the processing queue.", "POST", "/queue/pause"),
    "resume_queue": ("Resume the processing queue.", "POST", "/queue/resume"),
}

_EMPTY_SCHEMA = {"type": "object", "properties": {}, "additionalProperties": False}

# An internal token: dispatch goes straight through the router in-process, so we
# pass a fixed token as both expected + provided (no network, no real auth here).
_LOCAL_TOKEN = "mcp-local"


class McpUnavailable(RuntimeError):
    """The MCP stdio transport was requested but the ``mcp`` package is absent."""


def list_tools() -> list[dict]:
    """Return MCP-style tool descriptors (name, description, inputSchema)."""
    return [
        {"name": name, "description": desc, "inputSchema": _EMPTY_SCHEMA}
        for name, (desc, _m, _p) in _TOOLS.items()
    ]


def call_tool(name: str, arguments: dict, ctx) -> dict:
    """Dispatch a tool call to the API router. Raises KeyError for unknown tools."""
    if name not in _TOOLS:
        raise KeyError(f"unknown tool: {name!r}")
    _desc, method, path = _TOOLS[name]
    _status, body = handle_request(method, path, _LOCAL_TOKEN, _LOCAL_TOKEN, ctx)
    return body


def call_tool_text(name: str, arguments: dict, ctx) -> str:
    """Dispatch + JSON-encode — the text payload an MCP TextContent carries."""
    return json.dumps(call_tool(name, arguments or {}, ctx), ensure_ascii=False)


def build_server(ctx):
    """Construct a configured ``mcp.server.Server`` bound to this registry.

    Lazy-imports ``mcp``; raises :class:`McpUnavailable` if it isn't installed.
    Registers ``list_tools`` / ``call_tool`` handlers that delegate to the
    in-process registry above."""
    try:
        import mcp.types as types
        from mcp.server import Server
    except ImportError as e:  # pragma: no cover - exercised only without mcp
        raise McpUnavailable(
            "the MCP stdio server needs the optional 'mcp' package "
            "(pip install mcp) — see docs/plans/mcp-server-design.md"
        ) from e

    server = Server("paragraphos")

    @server.list_tools()
    async def _list():  # pragma: no cover - needs mcp runtime
        return [
            types.Tool(name=t["name"], description=t["description"], inputSchema=t["inputSchema"])
            for t in list_tools()
        ]

    @server.call_tool()
    async def _call(name, arguments):  # pragma: no cover - needs mcp runtime
        return [types.TextContent(type="text", text=call_tool_text(name, arguments, ctx))]

    return server


def serve_stdio(ctx) -> None:
    """Run the MCP server over stdio until the client disconnects.

    Blocking; raises :class:`McpUnavailable` if ``mcp`` is not installed."""
    import asyncio

    # build_server raises McpUnavailable cleanly if 'mcp' is absent — do it
    # BEFORE importing the stdio transport so a missing package never surfaces
    # as a raw ImportError to the CLI.
    server = build_server(ctx)

    from mcp.server.stdio import stdio_server  # pragma: no cover - needs mcp

    async def _main():  # pragma: no cover - needs mcp runtime
        async with stdio_server() as (read, write):
            await server.run(read, write, server.create_initialization_options())

    asyncio.run(_main())  # pragma: no cover - needs mcp runtime
