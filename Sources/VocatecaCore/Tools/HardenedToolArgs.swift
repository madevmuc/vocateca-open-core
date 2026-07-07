import Foundation

// MARK: - Hardened tool argument prefixes (L-3)
//
// Security hardening (2026-07-05): yt-dlp loads `~/.config/yt-dlp/config` (and
// per-user plugin directories) even when invoked as a standalone binary with
// an absolute path — that config file accepts ANY yt-dlp option, including
// `--exec "<shell command>"`. A same-user process that can write that file
// (a malicious npm postinstall script, a compromised dependency, etc.) turns
// Vocateca's routine, automated yt-dlp invocations into a code-exec
// trampoline. gallery-dl has an analogous `--ignore-config` flag.
//
// See docs/audits/audit-security-report-2026-07-05.md finding L-3.
//
// EVERY yt-dlp/gallery-dl `Process`/`Subprocess.run` call site must prepend
// these flags. Grep-verify: `rg 'ignore-config' swift/Sources` should have a
// hit for every yt-dlp/gallery-dl invocation.

/// Shared hardened argument prefix for all yt-dlp invocations.
public enum YtDlp {
    /// `--ignore-config` skips `~/.config/yt-dlp/config` (and the global/
    /// portable config locations) entirely; `--no-plugin-dirs` clears every
    /// plugin search directory so no auto-loaded plugin package from a
    /// user-writable directory can run. Both must be the FIRST arguments
    /// passed so no legitimate flag can be shadowed by something a hostile
    /// config might also set.
    ///
    /// NOTE: the flag is `--no-plugin-dirs`, NOT `--no-plugins` — the latter
    /// does not exist in the bundled yt-dlp (2026.06.09) and made every
    /// download exit 2 with "no such option: --no-plugins", silently breaking
    /// all YouTube / generic-URL fetches. `--no-plugin-dirs` is the supported
    /// equivalent (verify with `yt-dlp --help | grep plugin` if the bundled
    /// binary is ever bumped).
    public static let hardenedBaseArgs: [String] = ["--ignore-config", "--no-plugin-dirs"]
}

/// Shared hardened argument prefix for all gallery-dl invocations.
public enum GalleryDL {
    /// `--ignore-config` skips gallery-dl's own config file discovery
    /// (`~/.config/gallery-dl/config.json` and friends). gallery-dl has no
    /// separate plugin-loading flag to disable.
    public static let hardenedBaseArgs: [String] = ["--ignore-config"]
}
