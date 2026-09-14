import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    private var headerItem: NSMenuItem!
    private var optimizeItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    /// PHASE 1 NOTE: this is still the old menu-bar UI, rewired onto the new
    /// metrics engine. Sampling now happens on MetricsEngine's private serial
    /// queue and arrives here as immutable snapshots on the main thread — this
    /// class no longer owns any delta state and no longer samples on a Timer.
    /// The notch UI replaces everything below.
    private var metricsToken: MetricsObserverToken?
    private var isOptimizing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MacPulse only reads system counters and touches files under
        // ~/Library/Caches and ~/Library/Logs — it needs no TCC-gated
        // permission (no Accessibility, no Screen Recording), so unlike a
        // tool that has to briefly masquerade as a regular/activated app to
        // reliably file a permission request, it can just sit as a plain
        // accessory (menu-bar-only) app from the start.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        MetricsEngine.shared.start()
        metricsToken = MetricsEngine.shared.observe { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "⚡︎ --%  🧠--%"

        let menu = NSMenu()
        menu.delegate = self

        headerItem = NSMenuItem(title: "MacPulse", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        optimizeItem = NSMenuItem(title: "⚡️ Оптимизировать", action: #selector(optimizeTapped), keyEquivalent: "")
        optimizeItem.target = self
        menu.addItem(optimizeItem)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
    }

    /// Renders a snapshot into the status bar title and the dropdown header.
    /// Called on the main thread by MetricsEngine after every sample.
    private func render(_ snapshot: MetricsSnapshot) {
        let cpuBusy = snapshot.cpu?.overall.busy
        let ramUsed = snapshot.memory?.usedFraction

        statusItem.button?.title = String(
            format: "⚡︎%@  🧠%@",
            cpuBusy.map { String(format: "%3d%%", Int(($0 * 100).rounded())) } ?? " --%",
            ramUsed.map { String(format: "%3d%%", Int(($0 * 100).rounded())) } ?? " --%"
        )

        var lines: [String] = []
        if let cpu = snapshot.cpu {
            lines.append(String(format: "CPU: %.0f%%", cpu.overall.busy * 100))
        }
        if let memory = snapshot.memory {
            let gb = 1_073_741_824.0
            lines.append(String(format: "RAM: %.1f/%.1f GB",
                                Double(memory.usedBytes) / gb, Double(memory.totalBytes) / gb))
            lines.append(String(format: "Swap: %.1f/%.1f GB",
                                Double(memory.swapUsedBytes ?? 0) / gb,
                                Double(memory.swapTotalBytes ?? 0) / gb))
        }
        if let cpu = snapshot.cpu {
            lines.append(String(format: "Load: %.2f  %.2f  %.2f",
                                cpu.loadAverage1, cpu.loadAverage5, cpu.loadAverage15))
        }
        headerItem.title = lines.joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Ask for an out-of-band sample so the header is fresh the instant the
        // user looks at it; it arrives through the normal observer path.
        MetricsEngine.shared.refreshNow()
    }

    // MARK: - Optimize action

    @objc private func optimizeTapped() {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizeItem.isEnabled = false
        optimizeItem.title = "Оптимизирую…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = Self.performOptimize()
            DispatchQueue.main.async {
                guard let self else { return }
                self.optimizeItem.title = summary
                self.optimizeItem.isEnabled = true
                self.isOptimizing = false

                // Revert to the resting label after a few seconds, unless a
                // fresh run has already started and is showing its own
                // "Оптимизирую…" status by the time this fires.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, !self.isOptimizing else { return }
                    self.optimizeItem.title = "⚡️ Оптимизировать"
                }
            }
        }
    }

    /// The one-click cleanup. Runs entirely on a background queue, entirely
    /// offline, entirely without elevated privileges. It only ever touches
    /// ~/Library/Caches and ~/Library/Logs (contents, not the folders
    /// themselves), and only ever terminates the "helpd" helper process
    /// (macOS's Help Viewer helper — safe to kill, it relaunches on demand).
    ///
    /// Explicitly NOT done here, by design: no sudo, no `purge` (confirmed
    /// to fail without sudo on this machine), nothing outside those two
    /// folders, no killing of any other process, no network access anywhere.
    private static func performOptimize() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cachesURL = home.appendingPathComponent("Library/Caches")
        let logsURL = home.appendingPathComponent("Library/Logs")

        // 1. Snapshot before.
        let cachesBefore = directorySizeBytes(cachesURL)
        let logsBefore = directorySizeBytes(logsURL)
        let ramFreeBefore = (MemorySampler.currentFreeBytes() ?? 0)

        // 2 & 3. Delete contents (not the folders themselves); skip past
        // any individual item that errors (some system subfolders, e.g.
        // CloudKit/Safari caches, are protected and will refuse deletion
        // even for the owning user — that's expected, keep going).
        deleteContents(of: cachesURL)
        deleteContents(of: logsURL)

        // 4. helpd is always safe to terminate — it's a background helper
        // that relaunches on demand, never a user-facing app with unsaved
        // work. Nothing else is ever touched here.
        terminateHelpdIfRunning()

        // 5. Snapshot after and report the delta.
        let cachesAfter = directorySizeBytes(cachesURL)
        let logsAfter = directorySizeBytes(logsURL)
        let ramFreeAfter = (MemorySampler.currentFreeBytes() ?? 0)

        let freedBytes = max(0, (cachesBefore + logsBefore) - (cachesAfter + logsAfter))
        let ramDeltaBytes = Int64(ramFreeAfter) - Int64(ramFreeBefore)

        return "✓ Освобождено \(formatMB(freedBytes)), ОЗУ \(formatSignedMB(ramDeltaBytes))"
    }

    private static func directorySizeBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true } // keep walking past unreadable items
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes only the CONTENTS of `url`, never `url` itself. Any item that
    /// fails to delete (permission-protected system subfolders, files in
    /// use, etc.) is skipped rather than aborting the whole pass.
    private static func deleteContents(of url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
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
        guard check.terminationStatus == 0 else { return } // not running

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

    private static func formatSignedMB(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%@%.0f МБ", mb >= 0 ? "+" : "", mb)
    }

    // MARK: - Other menu actions

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        LaunchAtLogin.isEnabled = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
