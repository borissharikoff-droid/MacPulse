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
            "Освобождено на диске: \(formatMB(freedDiskBytes))"
        }
    }

    /// Runs entirely on a background queue, entirely offline, entirely
    /// unprivileged.
    static func cleanCachesAndLogs() -> Result {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches")
        let logsURL = home.appendingPathComponent("Library/Logs")

        let cachesBefore = directorySizeBytes(cachesURL)
        let logsBefore = directorySizeBytes(logsURL)
        let ramFreeBefore = MemorySampler.currentFreeBytes() ?? 0

        // Skip past any individual item that errors — some system
        // subfolders (CloudKit, Safari) refuse deletion even to their
        // owner, which is expected; keep going.
        deleteContents(of: cachesURL)
        deleteContents(of: logsURL)

        terminateHelpdIfRunning()

        let cachesAfter = directorySizeBytes(cachesURL)
        let logsAfter = directorySizeBytes(logsURL)
        let ramFreeAfter = MemorySampler.currentFreeBytes() ?? 0

        return Result(
            freedDiskBytes: max(0, (cachesBefore + logsBefore) - (cachesAfter + logsAfter)),
            ramFreeDeltaBytes: Int64(ramFreeAfter) - Int64(ramFreeBefore)
        )
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

    /// Deletes only the CONTENTS of `url`, never `url` itself.
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
        String(format: "%.0f МБ", Double(bytes) / 1_048_576.0)
    }
}
