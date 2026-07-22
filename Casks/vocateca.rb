# DRAFT — not submitted anywhere yet.
#
# This is a working copy of the cask kept in this repo for local testing only.
# Its eventual home is the `Homebrew/homebrew-cask` tap
# (Casks/v/vocateca.rb there, per the two-letter directory convention).
# Opening that PR is a separate, USER-approved, outward-facing step — see
# docs/homebrew-cask.md for the bump process and the PR checklist.

cask "vocateca" do
  version "2.2.1"
  sha256 "0ac9d74ae90f06a973fe4646578bffc164dc9ec8b38552877f40bc23b8da1646"

  url "https://vocateca.com/releases/Vocateca-#{version}.dmg"
  name "Vocateca"
  desc "On-device podcast, YouTube, and Instagram transcription"
  homepage "https://vocateca.com/"

  livecheck do
    url "https://vocateca.com/appcast.xml"
    strategy :sparkle
  end

  depends_on macos: :sequoia

  app "Vocateca.app"

  # Paths mirror AppDataReset.wipeEverything() in the main app (state db,
  # settings/watchlist, media + trash trees under Application Support; the
  # log file under Caches). Note: `zap` cannot remove Keychain items —
  # wipeEverything() also clears three Keychain services
  # (com.vocateca.instagram / .integrations / .webhooks) that a Homebrew
  # uninstall has no mechanism to touch; those are only cleared by the
  # in-app "factory reset", not by `brew uninstall --zap`.
  zap trash: [
    "~/Library/Application Support/Vocateca",
    "~/Library/Caches/Vocateca",
    "~/Library/Preferences/com.vocateca.app.plist",
  ]
end
