import Foundation

// MARK: - DiskWarning

/// Pure escalation logic for the app-wide low-disk warning. Wires
/// `Settings.diskWarnHudGb` / `diskWarnModalGb`; the thresholds themselves are
/// kept in a sane order by ``DiskThresholds``.
///
/// Deliberately independent of `Settings.diskGuardEnabled`: that switch decides
/// whether the QUEUE pauses, whereas a nearly-full disk is the Mac's problem and
/// worth saying out loud either way.
public enum DiskWarning {

    /// How loudly the app should warn, given current free space.
    public enum Level: String, Sendable, Equatable, CaseIterable {
        /// Enough space — say nothing.
        case none
        /// A floating bar. Blocks nothing.
        case hud
        /// A modal dialog. The disk is nearly gone.
        case modal
    }

    /// GB→bytes on the decimal (1e9) convention, matching ``DiskGuard`` and what
    /// Finder shows the user.
    public static func bytes(forGb gb: Int) -> Int64 { Int64(gb) * 1_000_000_000 }

    /// The level to show for `freeBytes`. `modalGb` is tested first, so an
    /// out-of-order pair can never hide the louder warning.
    public static func level(freeBytes: Int64, hudGb: Int, modalGb: Int) -> Level {
        if modalGb > 0, freeBytes < bytes(forGb: modalGb) { return .modal }
        if hudGb > 0, freeBytes < bytes(forGb: hudGb) { return .hud }
        return .none
    }

    /// How many bytes must be freed to get back above `targetGb` and silence the
    /// warning. `0` once the target is already met.
    public static func bytesShort(freeBytes: Int64, targetGb: Int) -> Int64 {
        max(0, bytes(forGb: targetGb) - freeBytes)
    }

    /// Whether cleaning up everything Vocateca owns would actually clear the
    /// warning. THIS is the question the dialog must answer before it offers a
    /// cleanup button: an offer that leaves the user still stuck is worse than no
    /// offer, because it costs them their media and solves nothing.
    public static func isEnough(reclaimableBytes: Int64, freeBytes: Int64, targetGb: Int) -> Bool {
        let short = bytesShort(freeBytes: freeBytes, targetGb: targetGb)
        guard short > 0 else { return true }
        return reclaimableBytes >= short
    }
}

// MARK: - ReclaimEstimate

/// What Vocateca can free by cleaning up after itself, split by source so the UI
/// can name what it is about to delete.
///
/// The transcription model is NOT part of this and never will be — deleting it
/// leaves the app unable to do the one thing it exists for, and it would come
/// straight back down the wire on the next run.
public struct ReclaimEstimate: Sendable, Equatable {
    /// Bytes held by media files whose episode is already transcribed.
    public var mediaBytes: Int64 = 0
    /// How many such media files there are.
    public var mediaCount: Int = 0
    /// Bytes parked in Vocateca's internal „Recently deleted" trash.
    public var trashBytes: Int64 = 0
    /// How many trashed items those bytes belong to.
    public var trashCount: Int = 0

    public var totalBytes: Int64 { mediaBytes + trashBytes }
    public var isEmpty: Bool { totalBytes <= 0 }

    public init(mediaBytes: Int64 = 0, mediaCount: Int = 0, trashBytes: Int64 = 0, trashCount: Int = 0) {
        self.mediaBytes = mediaBytes
        self.mediaCount = mediaCount
        self.trashBytes = trashBytes
        self.trashCount = trashCount
    }
}

// MARK: - StorageReclaimer

/// Measures — and on request performs — the cleanup Vocateca can do for itself
/// when the disk runs low: media it has finished with, plus its internal trash.
///
/// Reuses the existing retention machinery (`StateStore.mp3RetentionCandidates`
/// asked the "delete as soon as transcribed" question, `TrashStore`) rather than
/// re-deriving what is deletable, so this can never disagree with what the
/// maintenance pass would do on its own.
///
/// „Finished with" stands in for „played": Vocateca has no player and no
/// play/listen state, so the only honest signal that a media file has served its
/// purpose is that its transcript exists (`status == done`). This deliberately
/// ignores per-show retention overrides and the global retention preference —
/// the user is asking for space back NOW, which outranks a policy about when to
/// reclaim it automatically.
public struct StorageReclaimer {

    private let store: StateStore
    private let fileManager: FileManager
    private let trashDirOverride: URL?

    public init(store: StateStore, fileManager: FileManager = .default, trashDirOverride: URL? = nil) {
        self.store = store
        self.fileManager = fileManager
        self.trashDirOverride = trashDirOverride
    }

    private var trashDir: URL {
        trashDirOverride ?? Paths.userDataDir().appendingPathComponent("trash", isDirectory: true)
    }

    private func trashStore() -> TrashStore {
        TrashStore(store: store, trashDir: trashDir, fileManager: fileManager)
    }

    /// Media files for episodes that are already transcribed, with their sizes.
    /// Rows whose file has vanished are skipped, so the estimate only ever counts
    /// bytes that really exist.
    private func transcribedMedia(nowISO: String) -> [(guid: String, path: String, size: Int64)] {
        let candidates = (try? store.mp3RetentionCandidates(
            overrideBySlug: [:], globalDays: 0, globalDeleteAfterTranscribe: true, nowISO: nowISO)) ?? []
        return candidates.compactMap { cand in
            let path = cand.mp3Path
            guard !path.isEmpty,
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64
            else { return nil }
            return (cand.guid, path, size)
        }
    }

    /// What a cleanup would free, without deleting anything.
    public func estimate(nowISO: String = Event.nowISO()) -> ReclaimEstimate {
        var result = ReclaimEstimate()

        for media in transcribedMedia(nowISO: nowISO) {
            result.mediaBytes += media.size
            result.mediaCount += 1
        }

        let items = (try? trashStore().items()) ?? []
        result.trashCount = items.count
        result.trashBytes = directoryBytes(trashDir)

        return result
    }

    /// Performs the cleanup and reports what was actually freed. Best-effort: a
    /// single unreadable file never aborts the pass, so the returned figures can
    /// come in under ``estimate()``.
    @discardableResult
    public func reclaim(nowISO: String = Event.nowISO()) -> ReclaimEstimate {
        var freed = ReclaimEstimate()

        for media in transcribedMedia(nowISO: nowISO) {
            guard (try? fileManager.removeItem(atPath: media.path)) != nil else { continue }
            try? store.clearMp3Path(guid: media.guid)
            freed.mediaBytes += media.size
            freed.mediaCount += 1
        }

        let trash = trashStore()
        let items = (try? trash.items()) ?? []
        let trashBytesBefore = directoryBytes(trashDir)
        for item in items {
            guard (try? trash.deleteNow(id: item.id)) != nil else { continue }
            freed.trashCount += 1
        }
        freed.trashBytes = max(0, trashBytesBefore - directoryBytes(trashDir))

        Log.info("StorageReclaim: cleanup done", component: "Maintenance",
                 context: [("mediaCount", "\(freed.mediaCount)"),
                           ("mediaBytes", "\(freed.mediaBytes)"),
                           ("trashCount", "\(freed.trashCount)"),
                           ("trashBytes", "\(freed.trashBytes)")])
        return freed
    }

    /// Total bytes of every regular file under `url`. `0` when the directory is
    /// absent or unreadable — an unmeasurable trash is reported as freeing
    /// nothing rather than as a guess.
    private func directoryBytes(_ url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            guard let vals = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true, let size = vals.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
