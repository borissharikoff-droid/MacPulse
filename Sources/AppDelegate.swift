import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let island = IslandController()

    private var headerItem: NSMenuItem!
    private var islandItem: NSMenuItem!
    private var cleanupItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var metricsToken: MetricsObserverToken?
    private var isCleaning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MacPulse only reads system counters and touches files under
        // ~/Library/Caches and ~/Library/Logs — it needs no TCC-gated
        // permission (no Accessibility, no Screen Recording), so it can sit
        // as a plain accessory (menu-bar-only) app from the start. Mouse
        // event monitors, unlike keyboard ones, need no permission either.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        // The island starts the metrics engine and subscribes itself.
        island.start()

        metricsToken = MetricsEngine.shared.observe { [weak self] snapshot in
            self?.renderStatusItem(snapshot)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let metricsToken { MetricsEngine.shared.remove(metricsToken) }
        island.stop()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        // A compact fixed width instead of variableLength: the item is a
        // drawn 18pt meter now, not a string, and it should not breathe.
        statusItem = NSStatusBar.system.statusItem(withLength: 24)
        statusItem.button?.image = StatusItemIcon.image(cpu: nil, ram: nil, pressure: nil)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "MacPulse"

        let menu = NSMenu()
        menu.delegate = self
        // AppKit's default is TRUE, which silently re-enables anything we
        // disable (the "Очищаю…" state used to flicker back to enabled for
        // exactly this reason). We drive isEnabled ourselves; the
        // NSMenuItemValidation conformance below is a belt-and-braces
        // second line of defence.
        menu.autoenablesItems = false

        headerItem = NSMenuItem(title: "MacPulse", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        islandItem = NSMenuItem(title: "Скрыть островок",
                                action: #selector(toggleIsland), keyEquivalent: "")
        islandItem.target = self
        menu.addItem(islandItem)

        menu.addItem(.separator())

        // Demoted from the old headline "⚡️ Оптимизировать". The label now
        // says what it does and does not oversell it: this frees disk, not
        // memory. The action that frees memory is a per-app Quit button in
        // the island panel.
        cleanupItem = NSMenuItem(title: "Очистить кеши и логи (освобождает диск, не память)",
                                 action: #selector(cleanupTapped), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.toolTip = """
        Удаляет содержимое ~/Library/Caches и ~/Library/Logs.
        На давление памяти это не влияет — чтобы его снизить, \
        закройте приложение с большим footprint в панели островка.
        """
        menu.addItem(cleanupItem)

        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Запускать при входе",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Called on the main thread by MetricsEngine after every sample.
    private func renderStatusItem(_ snapshot: MetricsSnapshot) {
        let cpuBusy = snapshot.cpu?.overall.busy
        let ramUsed = snapshot.memory?.usedFraction
        let pressure = snapshot.memory?.pressureLevel

        statusItem.button?.image = StatusItemIcon.image(cpu: cpuBusy, ram: ramUsed, pressure: pressure)
        statusItem.button?.toolTip = tooltip(snapshot)
        headerItem.title = headerText(snapshot)
    }

    private func tooltip(_ s: MetricsSnapshot) -> String {
        let cpu = s.cpu?.overall.busy
        let ram = s.memory?.usedFraction
        return "MacPulse — CPU \(UIFmt.pct(cpu)) · память \(UIFmt.pct(ram)) · "
            + "давление: \(IslandPalette.label(for: s.memory?.pressureLevel))"
    }

    private func headerText(_ s: MetricsSnapshot) -> String {
        var lines: [String] = []
        if let m = s.memory {
            lines.append("Давление памяти: \(IslandPalette.label(for: m.pressureLevel))")
            lines.append("Распаковка: \(UIFmt.mbps(m.rates?.decompressionBytesPerSec))"
                         + "   Сжатие: \(UIFmt.mbps(m.rates?.compressionBytesPerSec))")
            lines.append("Память: \(UIFmt.bytes(m.usedBytes)) из \(UIFmt.bytes(m.totalBytes))"
                         + "   Своп: \(UIFmt.bytes(m.swapUsedBytes))")
        }
        if let top = s.processes?.apps.first {
            lines.append("Самое крупное: \(top.name) — \(UIFmt.bytes(top.footprintBytes))")
        }
        return lines.isEmpty ? "MacPulse" : lines.joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate / validation

    func menuWillOpen(_ menu: NSMenu) {
        // Fresh numbers the instant the user looks; arrives via the normal
        // observer path.
        MetricsEngine.shared.refreshNow()
        islandItem.title = island.isVisible ? "Скрыть островок" : "Показать островок"
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === headerItem { return false }
        if menuItem === cleanupItem { return !isCleaning }
        return true
    }

    // MARK: - Actions

    @objc private func toggleIsland() {
        island.setVisible(!island.isVisible)
        islandItem.title = island.isVisible ? "Скрыть островок" : "Показать островок"
    }

    @objc private func cleanupTapped() {
        guard !isCleaning else { return }
        isCleaning = true
        cleanupItem.isEnabled = false
        let restingTitle = "Очистить кеши и логи (освобождает диск, не память)"
        cleanupItem.title = "Очищаю…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Maintenance.cleanCachesAndLogs()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupItem.title = "✓ " + result.summary
                self.cleanupItem.isEnabled = true
                self.isCleaning = false

                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, !self.isCleaning else { return }
                    self.cleanupItem.title = restingTitle
                }
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = sender.state != .on
        LaunchAtLogin.isEnabled = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
