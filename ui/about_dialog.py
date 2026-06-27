"""About + Changelog dialogs."""

from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import QThread, pyqtSignal
from PyQt6.QtWidgets import (
    QDialog,
    QLabel,
    QPushButton,
    QTabWidget,
    QTextBrowser,
    QVBoxLayout,
    QWidget,
)

from core.version import VERSION


def _resolve_changelog() -> Path:
    """Return the first CHANGELOG.md that exists.

    Dev layout:   `.../paragraphos/ui/about_dialog.py` → `../CHANGELOG.md`
    py2app .app:  CHANGELOG.md ships under `Contents/Resources/`, while
                  `about_dialog.py` lives at
                  `Contents/Resources/lib/python3.12/ui/about_dialog.py`
                  — so the dev-layout path misses it.
    """
    here = Path(__file__).resolve().parent  # .../ui/
    candidates = [
        here.parent / "CHANGELOG.md",  # dev: paragraphos/CHANGELOG.md
        here.parent.parent / "CHANGELOG.md",  # Resources/lib/python3.12 → Resources/lib
        here.parent.parent.parent / "CHANGELOG.md",  # .app/Contents/Resources
    ]
    for p in candidates:
        if p.exists():
            return p
    return candidates[0]  # first guess for error messages


CHANGELOG_PATH = _resolve_changelog()


# (name, version-rough, license-SPDX, project URL)
DEPENDENCIES = [
    ("Python", "3.12", "PSF-2.0", "https://python.org"),
    (
        "Qt / PyQt6",
        "6.6+",
        "GPL-3.0 / Commercial (Riverbank)",
        "https://www.riverbankcomputing.com/software/pyqt/",
    ),
    ("whisper.cpp", "HEAD", "MIT", "https://github.com/ggerganov/whisper.cpp"),
    ("OpenAI Whisper model (large-v3-turbo)", "2024", "MIT", "https://github.com/openai/whisper"),
    ("APScheduler", "3.10+", "MIT", "https://apscheduler.readthedocs.io/"),
    ("watchdog", "4.0+", "Apache-2.0", "https://github.com/gorakhargosh/watchdog"),
    ("feedparser", "6.0+", "BSD-2-Clause", "https://github.com/kurtmckee/feedparser"),
    ("httpx", "0.27+", "BSD-3-Clause", "https://www.python-httpx.org/"),
    ("pydantic", "2.6+", "MIT", "https://docs.pydantic.dev/"),
    ("beautifulsoup4", "4.12+", "MIT", "https://www.crummy.com/software/BeautifulSoup/"),
    ("lxml", "5.0+", "BSD-3-Clause", "https://lxml.de/"),
    ("PyYAML", "6.0+", "MIT", "https://pyyaml.org/"),
    ("ffmpeg", "6+", "LGPL-2.1 / GPL", "https://ffmpeg.org/"),
    ("Homebrew", "4+", "BSD-2-Clause", "https://brew.sh/"),
    ("defusedxml", "0.7+", "PSF-2.0", "https://github.com/tiran/defusedxml"),
    ("yt-dlp", "latest", "Unlicense (public domain)", "https://github.com/yt-dlp/yt-dlp"),
    # Optional extras — only needed for specific features.
    ("fpdf2 (optional — PDF export)", "2.7+", "LGPL-3.0", "https://github.com/py-pdf/fpdf2"),
    (
        "sherpa-onnx (optional — diarization)",
        "1.10+",
        "Apache-2.0",
        "https://github.com/k2-fsa/sherpa-onnx",
    ),
    (
        "mcp (optional — MCP server)",
        "1.0+",
        "MIT",
        "https://github.com/modelcontextprotocol/python-sdk",
    ),
]


def _about_tab(parent: QWidget) -> QWidget:
    w = QWidget(parent)
    v = QVBoxLayout(w)

    def _p(text: str) -> None:
        # Word-wrap every paragraph: a non-wrapping QLabel reports its full
        # one-line text width as its minimum, which propagates up through the
        # stacked widget and forces the whole main window wider than the screen.
        lbl = QLabel(text)
        lbl.setWordWrap(True)
        v.addWidget(lbl)

    _p("<h2>Paragraphos</h2>")
    _p(
        "Local podcast, YouTube &amp; audio-file → whisper.cpp transcription "
        f"pipeline.<br>Version {VERSION} · Apple Silicon only"
    )
    _p(
        "<br>The name <b>Paragraphos</b> refers to the ancient Greek "
        "punctuation mark that signalled a change of speaker in a text — "
        "the job Paragraphos does for every episode it transcribes."
    )
    _p(
        "<br><b>Technology</b>: Python 3.12, PyQt6, whisper.cpp "
        "(large-v3-turbo), APScheduler, watchdog, feedparser, "
        "yt-dlp (YouTube ingestion), and optional sherpa-onnx (speaker "
        "diarization)."
    )
    _p(
        "<br><b>Capabilities</b>: parallel transcription, per-episode "
        "language detection + low-confidence marking, speaker labels, "
        "re-upload de-duplication, processing windows + battery-aware "
        "pausing, and full headless automation — an expanded CLI, a "
        "localhost JSON API, and an MCP server for LLM agents."
    )
    _p(
        "<br><b>Spotlight</b>: macOS automatically indexes the "
        "<code>.md</code> transcripts in your output folder. "
        "Search them system-wide with ⌘Space."
    )
    _p(
        "<br><b>Privacy</b>: everything runs locally. No cloud APIs "
        "for transcription. No telemetry."
    )
    v.addStretch()
    return w


def _licenses_tab(parent: QWidget) -> QWidget:
    w = QWidget(parent)
    v = QVBoxLayout(w)
    _intro = QLabel(
        "Paragraphos stands on the shoulders of open-source projects. "
        "The full list of bundled + runtime dependencies and their licenses:"
    )
    _intro.setWordWrap(True)
    v.addWidget(_intro)

    html = "<table cellpadding='6' cellspacing='0' style='border-collapse:collapse;'>"
    html += (
        "<tr style='background:palette(alternate-base);'>"
        "<th align='left'>Component</th>"
        "<th align='left'>Version</th>"
        "<th align='left'>License</th>"
        "<th align='left'>Project</th></tr>"
    )
    for name, ver, lic, url in DEPENDENCIES:
        html += (
            "<tr>"
            f"<td><b>{name}</b></td>"
            f"<td>{ver}</td>"
            f"<td>{lic}</td>"
            f"<td><a href='{url}'>{url.replace('https://', '').rstrip('/')}</a></td>"
            "</tr>"
        )
    html += "</table>"

    html += (
        "<br><br>"
        "<b>About the licenses</b><br>"
        "MIT, BSD, Apache-2.0, and PSF are permissive — they allow "
        "free use, modification, and redistribution subject to "
        "attribution and preservation of the license notice. "
        "GPL / LGPL (PyQt6 under GPL-3.0, parts of ffmpeg under "
        "LGPL-2.1/GPL) require that modifications to those components "
        "themselves be released under the same license; dynamic "
        "linking from Paragraphos is covered. Paragraphos itself is "
        "a personal project and is not redistributed to third parties."
        "<br><br>"
        "<b>Whisper model weights</b> (OpenAI, released under MIT) "
        "are downloaded separately from the Hugging Face mirror at "
        "<a href='https://huggingface.co/ggerganov/whisper.cpp'>"
        "huggingface.co/ggerganov/whisper.cpp</a>."
        "<br><br>"
        "<b>Podcast audio</b> remains the property of its original "
        "authors. Transcripts are derived works for personal "
        "research / archiving use. Check the license of each podcast "
        "before redistribution."
    )

    browser = QTextBrowser()
    browser.setOpenExternalLinks(True)
    browser.setHtml(html)
    v.addWidget(browser)
    return w


def _security_tab(parent: QWidget) -> QWidget:
    w = QWidget(parent)
    v = QVBoxLayout(w)
    html = (
        "<h3>Threat model</h3>"
        "Paragraphos ingests <b>fully untrusted data</b>: RSS feed XML, "
        "episode landing-page HTML, MP3 URLs, and OPML subscription lists. "
        "A compromised feed or a MITM between you and a podcast host "
        "should not be able to read your local files, reach your private "
        "network, or execute code on your Mac."
        ""
        "<h3>Mitigations in place</h3>"
        "<ul>"
        "<li><b>URL allowlist</b> — only <code>http://</code> and "
        "<code>https://</code> are followed. <code>file://</code>, "
        "<code>data:</code>, <code>javascript:</code> are rejected.</li>"
        "<li><b>SSRF guard</b> — URLs resolving to loopback, link-local, "
        "private (RFC1918), multicast, or reserved IP ranges are refused, "
        "so a malicious feed can't probe your LAN or read "
        "<code>http://localhost/admin</code>.</li>"
        "<li><b>Download caps</b> — MP3 ≤ 2 GB, RSS feed ≤ 50 MB, "
        "HTML ≤ 10 MB. Streams exceeding the cap are aborted and the "
        "<code>.part</code> file deleted.</li>"
        "<li><b>Content-Type sniffing</b> — MP3 downloads must advertise "
        "<code>audio/*</code> or <code>application/octet-stream</code>. "
        "A feed can't sneak a <code>text/html</code> payload into your "
        "transcripts folder.</li>"
        "<li><b>XML hardening</b> — OPML parsing uses "
        "<code>defusedxml</code> (blocks XXE, billion-laughs, external "
        "entity expansion). feedparser and lxml are called without "
        "feature flags that enable entity resolution.</li>"
        "<li><b>Path-traversal defence</b> — the filename sanitizer "
        'strips <code>/ \\ : * ? " &lt; &gt; |</code> and neutralises '
        "<code>..</code>. A second check (<code>safe_path_within</code>) "
        "verifies each write stays inside <code>output_root</code>.</li>"
        "<li><b>Model integrity</b> — whisper-cpp GGML models are "
        "verified against a pinned SHA-256 after download; a mismatched "
        "file is deleted before being moved into place.</li>"
        "<li><b>No shell execution</b> — all subprocess invocations use "
        "<code>subprocess.run([...])</code> with list-form arguments. "
        "Episode titles, whisper prompts, and feed URLs never touch a "
        "shell. No <code>shell=True</code> anywhere.</li>"
        "<li><b>SQL injection impossible</b> — every state query uses "
        "parameterised <code>?</code> placeholders.</li>"
        "<li><b>YAML is <code>safe_load</code> only</b> — frontmatter "
        "parsing can't instantiate arbitrary Python classes.</li>"
        "<li><b>Local automation surface is contained</b> — the optional "
        "JSON API (<code>serve</code>) binds to <code>127.0.0.1</code> only "
        "and requires a generated bearer token; the MCP server "
        "(<code>mcp</code>) speaks over stdio with no network listener. "
        "Both are off unless you start them.</li>"
        "<li><b>Webhook POST targets are SSRF-guarded</b> and command "
        "webhooks are split with <code>shlex</code> + run as list-form argv "
        "(no shell).</li>"
        "</ul>"
        ""
        "<h3>Residual risks</h3>"
        "<ul>"
        "<li><b>whisper.cpp itself</b> is a C++ binary; a crafted MP3 "
        "could in theory exploit a parser bug. macOS sandbox / signed "
        "Homebrew releases mitigate this. Keep <code>brew upgrade "
        "whisper-cpp</code> current.</li>"
        "<li><b>HTTP-only feeds</b> (no TLS) are still followed — their "
        "contents can be tampered with on the wire. A future release "
        "could flag these in the feed-health check.</li>"
        "<li><b>No code signing / notarization</b> — the .app is locally "
        "ad-hoc signed, so macOS Gatekeeper warns on first launch. Only "
        "install Paragraphos from a source you trust.</li>"
        "<li><b>yt-dlp binary auto-update</b> — the yt-dlp helper is fetched "
        "over HTTPS from GitHub and self-updates without a pinned hash "
        "(unlike the whisper models). A compromised GitHub release would "
        "run as your user; the HTTPS fetch is the only guard.</li>"
        "</ul>"
        ""
        "<h3>Reporting a vulnerability</h3>"
        "Paragraphos is a personal project. If you find a security issue, "
        "open a private issue in the repository or mail the maintainer "
        "directly before disclosing publicly."
    )
    browser = QTextBrowser()
    browser.setOpenExternalLinks(True)
    browser.setHtml(html)
    v.addWidget(browser)
    return w


class AboutDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("About Paragraphos")
        self.resize(720, 560)
        v = QVBoxLayout(self)
        tabs = QTabWidget()
        tabs.addTab(_about_tab(self), "About")
        tabs.addTab(_licenses_tab(self), "Credits & Licenses")
        tabs.addTab(_security_tab(self), "Security")
        v.addWidget(tabs)
        close = QPushButton("Close")
        close.clicked.connect(self.accept)
        v.addWidget(close)


class ChangelogDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Paragraphos Changelog")
        self.resize(640, 520)
        v = QVBoxLayout(self)
        browser = QTextBrowser()
        browser.setOpenExternalLinks(True)
        text = (
            CHANGELOG_PATH.read_text(encoding="utf-8")
            if CHANGELOG_PATH.exists()
            else "_No CHANGELOG.md found yet._"
        )
        browser.setMarkdown(text)
        v.addWidget(browser)
        close = QPushButton("Close")
        close.clicked.connect(self.accept)
        v.addWidget(close)


class _ChangelogTab(QWidget):
    """Tab showing a changelog. Prefers GitHub releases API (live, covers
    every tagged release) and falls back to the bundled CHANGELOG.md if
    the network call fails. Fetch happens off-thread."""

    def __init__(self, parent=None):
        super().__init__(parent)

        v = QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        self._browser = QTextBrowser()
        self._browser.setOpenExternalLinks(True)
        # Render bundled CHANGELOG.md immediately so the tab is never blank
        # while the GitHub fetch is in flight.
        if CHANGELOG_PATH.exists():
            self._browser.setMarkdown(CHANGELOG_PATH.read_text(encoding="utf-8"))
        else:
            self._browser.setPlainText("Loading releases…")
        v.addWidget(self._browser)

        # Kick off the GitHub fetch.
        self._ChangelogThread = _GitHubChangelogThread  # alias for readability
        self._thread = _GitHubChangelogThread(self)
        self._thread.loaded.connect(self._on_loaded)
        self._thread.failed.connect(self._on_failed)  # silent fallback
        self._thread.start()

    def _on_loaded(self, markdown: str) -> None:
        if markdown.strip():
            self._browser.setMarkdown(markdown)

    def _on_failed(self, msg: str) -> None:
        # Don't strand the user on "Loading releases…" if the GitHub
        # fetch fails AND the bundled CHANGELOG.md is missing.
        if not CHANGELOG_PATH.exists():
            self._browser.setPlainText(
                "Couldn't reach GitHub for release notes.\n\n"
                "Visit https://github.com/madevmuc/paragraphos/releases\n"
                f"(error: {msg})"
            )


class _GitHubChangelogThread(QThread):
    """Fetch every release from GitHub + stitch into a single markdown
    document. Runs off the UI thread."""

    loaded = pyqtSignal(str)
    failed = pyqtSignal(str)

    def run(self) -> None:
        try:
            from core.http import get_client
            from core.updater import DEFAULT_GITHUB_REPO

            url = f"https://api.github.com/repos/{DEFAULT_GITHUB_REPO}/releases"
            r = get_client().get(url, timeout=10, headers={"Accept": "application/vnd.github+json"})
            r.raise_for_status()
            releases = r.json()
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(str(exc))
            return

        if not releases:
            self.failed.emit("no releases")
            return

        parts = ["# Paragraphos Changelog", ""]
        for rel in releases:
            tag = rel.get("tag_name") or rel.get("name") or "?"
            date = (rel.get("published_at") or "")[:10]
            body = (rel.get("body") or "").strip()
            parts.append(f"## {tag} — {date}")
            parts.append("")
            parts.append(body or "_(no notes)_")
            parts.append("")
        self.loaded.emit("\n".join(parts))


class AboutPane(QWidget):
    """In-window About content — same tabs as AboutDialog, shown as a page
    in the main-window sidebar stack instead of a popup."""

    def __init__(self, parent=None):
        super().__init__(parent)
        v = QVBoxLayout(self)
        v.setContentsMargins(14, 14, 14, 14)
        tabs = QTabWidget()
        tabs.addTab(_about_tab(self), "About")
        tabs.addTab(_ChangelogTab(self), "Changelog")
        tabs.addTab(_licenses_tab(self), "Credits & Licenses")
        tabs.addTab(_security_tab(self), "Security")
        v.addWidget(tabs)
