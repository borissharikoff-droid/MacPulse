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

    /// What the status item currently DRAWS. A tick whose signature is
    /// unchanged does not rebuild the NSImage — see StatusItemIcon.
    private var drawnSignature: StatusItemIcon.Signature?
    /// Likewise for the tooltip string: assigning an identical string
    /// still makes AppKit rebuild the button's tracking rectangle.
    private var drawnToolTip: String?
    /// The menu's header is an NSAttributedString laid out from three
    /// formatted lines. Nobody can read it while the menu is shut, so it
    /// is only built while the menu is open — `menuWillOpen` already
    /// forces a fresh sample, so it is never stale when it matters.
    private var isMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MacPulse only reads system counters and touches files under
        // ~/Library/Caches and ~/Library/Logs — it needs no TCC-gated
        // permission (no Accessibility, no Screen Recording), so it can sit
        // as a plain accessory (menu-bar-only) app from the start. Mouse
        // event monitors, unlike keyboard ones, need no permission either.
        NSApp.setActivationPolicy(.accessory)

        // Inert unless --cost-log is on the command line. See IdleCost.swift.
        IdleCost.armIfRequested()

        setupStatusItem()

        // The island's trailing wing is bounded against MacPulse's OWN
        // menu bar item, so it can never grow under it. `window?.frame` on
        // our own status item window needs no permission whatsoever — no
        // Accessibility, no screen recording. Handed over as closures
        // rather than as the NSStatusItem so the controller cannot reach
        // anything else on it.
        island.statusItemMinX = { [weak self] in self?.statusItem.button?.window?.frame.minX }
        island.statusItemWindow = { [weak self] in self?.statusItem.button?.window }

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
        // The "frees disk, not memory" caveat lives in the tooltip below —
        // in the title it was the second-longest string in the menu.
        cleanupItem = NSMenuItem(title: "Очистить кэши и логи",
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
    ///
    /// THREE GATES, all of them measured. Redrawing the 18x15 meter every
    /// tick cost 0.389% of one core on its own (probe_ui), and the bars
    /// only have 13 distinct heights, so the overwhelming majority of
    /// those redraws produced the bitmap that was already on screen.
    private func renderStatusItem(_ snapshot: MetricsSnapshot) {
        let cpuBusy = snapshot.cpu?.overall.busy
        let ramUsed = snapshot.memory?.usedFraction
        let pressure = snapshot.memory?.pressureLevel

        let signature = StatusItemIcon.Signature(cpu: cpuBusy, ram: ramUsed, pressure: pressure)
        if signature != drawnSignature {
            drawnSignature = signature
            statusItem.button?.image = StatusItemIcon.image(cpu: cpuBusy, ram: ramUsed, pressure: pressure)
        }

        let tip = tooltip(snapshot)
        if tip != drawnToolTip {
            drawnToolTip = tip
            statusItem.button?.toolTip = tip
        }

        // Only while somebody can actually see it.
        if isMenuOpen {
            headerItem.attributedTitle = headerAttributed(snapshot)
        }
    }

    private func tooltip(_ s: MetricsSnapshot) -> String {
        let cpu = s.cpu?.overall.busy
        let ram = s.memory?.usedFraction
        return "MacPulse — CPU \(UIFmt.pct(cpu)) · память \(UIFmt.pct(ram)) · "
            + "давление: \(IslandPalette.label(for: s.memory?.pressureLevel))"
    }

    /// NSMenuItem.title collapses embedded newlines into ONE line, so the old
    /// multi-line string rendered as a single ~140-character run that set the
    /// menu's width. attributedTitle does lay out newlines, and also lets the
    /// header sit at 11pt instead of the 14pt menu font.
    ///
    /// Kept deliberately short: the island itself already shows pressure, the
    /// decompression trace and the top app, so this is a glance-sized echo,
    /// not a second dashboard.
    private func headerAttributed(_ s: MetricsSnapshot) -> NSAttributedString {
        var lines: [String] = []
        if let m = s.memory {
            lines.append("Давление: \(IslandPalette.label(for: m.pressureLevel))")
            lines.append("Распаковка \(UIFmt.mbps(m.rates?.decompressionBytesPerSec))"
                         + "   Своп \(UIFmt.bytes(m.swapUsedBytes))")
        }
        if let top = s.processes?.apps.first {
            lines.append("\(top.name) — \(UIFmt.bytes(top.footprintBytes))")
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: lines.isEmpty ? "MacPulse" : lines.joined(separator: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    // MARK: - NSMenuDelegate / validation

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // The header is not built while the menu is shut, so seed it from
        // the snapshot we already have before asking for a fresh one — the
        // fresh one arrives asynchronously and the menu is already on
        // screen by then.
        if let latest = MetricsEngine.shared.latest {
            headerItem.attributedTitle = headerAttributed(latest)
        }
        // Fresh numbers the instant the user looks; arrives via the normal
        // observer path.
        MetricsEngine.shared.refreshNow()
        islandItem.title = island.isVisible ? "Скрыть островок" : "Показать островок"
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
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
        let restingTitle = "Очистить кэши и логи"
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
