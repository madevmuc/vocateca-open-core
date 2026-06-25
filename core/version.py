"""Single source of truth for Paragraphos's semantic version.

Every setup.py, About dialog, updater, DMG script, and CI workflow
reads from here (or is grep'd against this value by the test suite).
Bumping a release is a one-line change.
"""

VERSION = "1.5.0"
