import AppKit

// =====================================================================
// Cache and log cleanup. DEMOTED, deliberately.
//
// This used to be the app's headline "⚡️ Оптимизировать" action. It is
// now a secondary menu item with an honest label, because the measured
// verdict is unambiguous: deleting disk caches has ZERO effect on memory
// pressure, and on a machine already paging in at ~27 MB/s it is mildly
// counterproductive short-term (everything it deletes gets rebuilt).
// It frees DISK, and that is all it is allowed to claim.
//
// The one action that actually moves memory pressure is quitting a
// memory-hog app, and that lives in IslandModel, one explicit click per
// app.
//
// SAFETY CONSTRAINTS, unchanged from the original implementation and
// deliberately preserved:
//   * no sudo, ever;
//   * no network access, ever, anywhere in this app;
//   * no deletion outside ~/Library/Caches and ~/Library/Logs, and only
//     of their CONTENTS, never the folders themselves;
//   * the only process this file may terminate is `helpd` — the Help
//     Viewer helper, which relaunches on demand and never holds user
//     work. Nothing else. Apps are terminated only where the user
//     clicked an individual Quit button.
//   * no `purge` (needs root, and per the research it is actively
//     harmful on a memory-constrained Mac anyway).
// =====================================================================

enum Maintenance {
    struct Result {
        let freedDiskBytes: Int64
        /// Deliberately reported separately and described as noise, not as
        /// an achievement. Free RAM moving is not evidence this helped.
        let ramFreeDeltaBytes: Int64

        var summary: String {
            tr("Освобождено на диске: \(formatMB(freedDiskBytes))",
               "Freed on disk: \(formatMB(freedDiskBytes))")
        }
    }

    /// Runs entirely on a background queue, entirely offline, entirely
    /// unprivileged.
    /// The ONLY two directories this file may ever delete inside, relative to
    /// the user's home. Nothing here takes a path from anywhere else.
    private static let deletionRoots = ["Library/Caches", "Library/Logs"]

    static func cleanCachesAndLogs() -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // A root that does not survive verification is skipped entirely —
        // never deleted inside, never even measured.
        let roots = deletionRoots.compactMap { verifiedRoot($0, under: home) }

        let before = roots.reduce(Int64(0)) { $0 + directorySizeBytes($1) }
        let ramFreeBefore = MemorySampler.currentFreeBytes() ?? 0

        // Skip past any individual item that errors — some system
        // subfolders (CloudKit, Safari) refuse deletion even to their
        // owner, which is expected; keep going.
        for root in roots { deleteContents(of: root) }

        terminateHelpdIfRunning()

        let after = roots.reduce(Int64(0)) { $0 + directorySizeBytes($1) }
        let ramFreeAfter = MemorySampler.currentFreeBytes() ?? 0

        return Result(
            freedDiskBytes: max(0, before - after),
            ramFreeDeltaBytes: Int64(ramFreeAfter) - Int64(ramFreeBefore)
        )
    }

    /// Turns "Library/Caches" into a URL that is SAFE to recursively delete
    /// inside, or nil.
    ///
    /// The deletion roots used to be built by string-appending onto
    /// `homeDirectoryForCurrentUser` and handed straight to
    /// `contentsOfDirectory(at:)` + `removeItem`. Nothing checked what was
    /// actually at the end of that path. If `~/Library/Caches` were a symlink
    /// — planted, or left behind by someone relocating their cache onto
    /// another volume — the recursive delete would walk through it and empty
    /// whatever it pointed at.
    ///
    /// Three conditions, all required:
    ///   1. the item exists and is a directory;
    ///   2. the item itself is not a symbolic link (checked WITHOUT following
    ///      it, via .isSymbolicLinkKey on the unresolved URL);
    ///   3. resolving every symlink in the path leaves it at exactly the
    ///      expected location under the (also fully resolved) home directory —
    ///      which catches a symlink anywhere in the chain, e.g. ~/Library
    ///      itself, not just the last component.
    private static func verifiedRoot(_ relativePath: String, under home: URL) -> URL? {
        let fm = FileManager.default
        let url = home.appendingPathComponent(relativePath)

        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true,
              values.isDirectory == true else { return nil }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let expected = home.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(relativePath).standardizedFileURL
        guard resolved.path == expected.path else { return nil }

        // Belt and braces: the resolved path must still BE a directory.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        return resolved
    }

    private static func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }   // keep walking past unreadable items
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            else { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes only the CONTENTS of `url`, never `url` itself. `url` must have
    /// come from `verifiedRoot`.
    ///
    /// Items inside may themselves be symlinks; `removeItem` unlinks the link
    /// and never follows it, so a symlink in a cache folder costs its target
    /// nothing.
    private static func deleteContents(of url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    private static func terminateHelpdIfRunning() {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-x", "helpd"]
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        do {
            try check.run()
            check.waitUntilExit()
        } catch {
            return
        }
        guard check.terminationStatus == 0 else { return }   // not running

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["helpd"]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: tr("%.0f МБ", "%.0f MB"), Double(bytes) / 1_048_576.0)
    }
}
