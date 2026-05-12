"""Podcast discovery — iTunes Search API + HTML <link rel="alternate"> fallback."""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup

from core.http import get_client

ITUNES_SEARCH_URL = "https://itunes.apple.com/search"


@dataclass(frozen=True)
class PodcastMatch:
    title: str
    author: str
    feed_url: str
    artwork_url: Optional[str]
    itunes_collection_id: Optional[int]


def search_itunes(
    term: str, *, limit: int = 50, country: str = "de", timeout: float = 10.0
) -> List[PodcastMatch]:
    r = get_client().get(
        ITUNES_SEARCH_URL,
        params={"media": "podcast", "term": term, "limit": limit, "country": country},
        timeout=timeout,
    )
    r.raise_for_status()
    data = r.json()
    out: List[PodcastMatch] = []
    for item in data.get("results", []):
        feed = item.get("feedUrl")
        if not feed:
            continue
        out.append(
            PodcastMatch(
                title=item.get("collectionName", ""),
                author=item.get("artistName", ""),
                feed_url=feed,
                artwork_url=item.get("artworkUrl600") or item.get("artworkUrl100"),
                itunes_collection_id=item.get("collectionId"),
            )
        )
    return out


def _is_rss_content_type(ct: str) -> bool:
    ct = (ct or "").lower()
    return "xml" in ct or "rss" in ct


def find_rss_from_url(url: str, *, timeout: float = 10.0) -> Optional[str]:
    """Given a landing-page or direct-RSS URL, return the canonical RSS URL."""
    r = get_client().get(url, follow_redirects=True, timeout=timeout)
    r.raise_for_status()
    ct = r.headers.get("content-type", "")
    if _is_rss_content_type(ct):
        return str(r.url)
    soup = BeautifulSoup(r.text, "lxml")
    link = soup.find("link", rel="alternate", type=lambda t: t and "rss" in t.lower())
    if link and link.get("href"):
        base = httpx.URL(str(r.url))
        return str(base.join(link["href"]))
    return None


def resolve_input(user_input: str) -> str:
    """Top-level resolver for URL-style input → RSS URL."""
    parsed = urlparse(user_input)
    if parsed.scheme in ("http", "https"):
        feed = find_rss_from_url(user_input)
        if not feed:
            raise ValueError(f"no RSS feed found on {user_input}")
        return feed
    raise ValueError(f"not a URL: {user_input!r}")
