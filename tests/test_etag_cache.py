"""use_etag_cache wiring (8.5): conditional headers gated by the setting."""

from __future__ import annotations

from pathlib import Path

import httpx
import respx

from core.rss import build_manifest_with_url, conditional_validators

FIX = Path(__file__).parent / "fixtures" / "sample_feed.xml"


def test_conditional_validators_gate():
    # When caching is on, stored validators pass through; off → both None.
    assert conditional_validators("etag-1", "mod-1", use_cache=True) == ("etag-1", "mod-1")
    assert conditional_validators("etag-1", "mod-1", use_cache=False) == (None, None)


@respx.mock
def test_headers_sent_when_etag_supplied():
    captured = {}

    def _responder(request):
        captured["inm"] = request.headers.get("If-None-Match")
        return httpx.Response(200, text=FIX.read_text())

    respx.get("https://a.test/rss").mock(side_effect=_responder)
    build_manifest_with_url("https://a.test/rss", etag="etag-1")
    assert captured["inm"] == "etag-1"


@respx.mock
def test_headers_absent_when_no_etag():
    captured = {}

    def _responder(request):
        captured["inm"] = request.headers.get("If-None-Match")
        return httpx.Response(200, text=FIX.read_text())

    respx.get("https://a.test/rss").mock(side_effect=_responder)
    build_manifest_with_url("https://a.test/rss", etag=None)
    assert captured["inm"] is None
