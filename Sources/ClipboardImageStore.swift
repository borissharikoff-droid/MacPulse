import Foundation

// =====================================================================
// Where a copied IMAGE's original bytes live.
//
// WHY THEY LIVE ANYWHERE AT ALL. The shelf has to hand a real file to
// whatever the user drops a chip on — Telegram, Finder, Figma. A drag
// that carries pixels-in-memory is a paste, not a file, and a 1-5 MB
// screenshot cannot sit in the history's 2 MiB RAM budget anyway. So the
// original goes to disk, the entry keeps the path, and a few-KB thumbnail
// is the only part that stays resident. That split is the whole design:
// RAM cost stays flat no matter how large the image.
//
// WHY NOT ~/Library/Caches. Because MacPulse itself ships an action that
// deletes the CONTENTS of that directory. Spooling there would mean the
// app eating its own clipboard the moment the user pressed its own
// "очистить кэши" button — a bug that would look like data loss and be
// nearly impossible to attribute. NSTemporaryDirectory() is per-app
// (/var/folders/...), OS-managed, and untouched by that action.
//
// WHAT IS DELETED, AND ONLY WHAT. Every unlink in this file is re-checked
// against the store's own directory first, the same way Maintenance.swift
// re-verifies its two roots before deleting inside them. This type never
// removes a path it was handed; it removes paths it wrote, inside a
// directory it created.
// =====================================================================

final class ClipboardImageStore {

    /// The live clipboard's spool. One fixed name, so a crashed process's
    /// leftovers are found and wiped by the next launch instead of
    /// accumulating under a fresh random name forever.
    static let defaultDirectoryName = "MacPulse-clipboard-images"

    /// A harness driving a PRIVATE pasteboard gets its own subdirectory,
    /// so a test can wipe freely without touching the running app's
    /// spool. The same reasoning as the pasteboard parameter itself.
    static func harnessDirectoryName(for pasteboardName: String) -> String {
        let safe = pasteboardName.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return defaultDirectoryName + "-harness-" + String(safe).prefix(40)
    }

    /// Absolute path of the directory this store owns. Readable so
    /// `--clipboard-probe` can count what is really on disk rather than
    /// trusting the engine's own bookkeeping.
    let directory: URL

    /// Serialises every filesystem operation. The engine polls from its
    /// sampling queue and the shelf drags from the main thread, so these
    /// calls genuinely do arrive from more than one place.
    private let lock = NSLock()

    /// Paths this store wrote, oldest first. The eviction order, and also
    /// the answer to "may I delete this" — a path that is not in here is
    /// not ours.
    private var spooled: [(path: String, bytes: Int)] = []

    init(name: String) {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Remove everything, including leftovers from a previous process.
    ///
    /// Called ONCE per launch, and only for the real clipboard — never on
    /// a second `start()`, which would wipe the running app's own images
    /// out from under the shelf.
    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        spooled.removeAll()
        // Remove the directory wholesale rather than walking it: it is
        // ours by construction and recreated on the next spool.
        try? FileManager.default.removeItem(at: directory)
    }

    /// Total bytes currently on disk.
    var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return spooled.reduce(0) { $0 + $1.bytes }
    }

    /// How many files are spooled right now.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return spooled.count
    }

    // MARK: - Spooling

    /// Write one image's original bytes and return its path, or nil if it
    /// could not be stored. `nil` is a normal outcome — the caller keeps
    /// the entry, minus the drag.
    ///
    /// `pathExtension` comes from the pasteboard type so the dropped file
    /// arrives as a real .png / .jpg rather than an extensionless blob
    /// that Finder shows as "document" and Telegram sends as a file of
    /// unknown kind.
    func spool(_ data: Data, pathExtension: String, perEntryCap: Int, totalCap: Int) -> String? {
        guard !data.isEmpty, data.count <= perEntryCap else { return nil }

        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let ext = pathExtension.isEmpty ? "png" : pathExtension
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            // `.atomic` so a reader can never see half a file, and
            // `.completeFileProtection` is deliberately NOT used: these
            // live in a per-app temp directory and the drag has to be
            // readable by the app the user drops onto.
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }

        spooled.append((path: url.path, bytes: data.count))
        evictLocked(totalCap: totalCap)
        // The write above may itself have been evicted if it alone
        // exceeds the total cap; say so rather than handing back a path
        // to a file that is already gone.
        return spooled.contains { $0.path == url.path } ? url.path : nil
    }

    /// Drop one spooled file. Silently does nothing for a path this store
    /// did not write — that check is the point, not politeness.
    func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = spooled.firstIndex(where: { $0.path == path }) else { return }
        spooled.remove(at: idx)
        unlinkVerified(path)
    }

    /// True when the file is still there AND still ours. The shelf asks
    /// this before offering a drag: the OS clears /var/folders on its own
    /// schedule, so a path that existed when the chip was drawn can be
    /// gone by the time it is dragged.
    func isAvailable(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard spooled.contains(where: { $0.path == path }) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Eviction

    /// Oldest file out until the total fits. The ENTRY survives — it keeps
    /// its thumbnail and its metadata and simply stops being draggable,
    /// which is a better outcome than making history vanish because a
    /// disk budget moved.
    private func evictLocked(totalCap: Int) {
        var total = spooled.reduce(0) { $0 + $1.bytes }
        while total > totalCap, !spooled.isEmpty {
            let victim = spooled.removeFirst()
            total -= victim.bytes
            unlinkVerified(victim.path)
        }
    }

    /// The only place this type deletes anything.
    ///
    /// Re-verifies containment immediately before the unlink rather than
    /// trusting that the path came from `spooled`: same discipline as
    /// Maintenance.verifiedRoot, one level down. Symlinks are resolved on
    /// BOTH sides before comparing, so a link planted inside the spool
    /// cannot redirect the delete outside it.
    private func unlinkVerified(_ path: String) {
        let resolvedDir = directory.resolvingSymlinksInPath().path
        let resolvedFile = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let prefix = resolvedDir.hasSuffix("/") ? resolvedDir : resolvedDir + "/"
        guard resolvedFile.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
