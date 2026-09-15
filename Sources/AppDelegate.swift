import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let island = IslandController()

    private var headerItem: NSMenuItem!
    private var islandItem: NSMenuItem!
    private var cleanupItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var calendarItem: NSMenuItem!
    private var updateItem: NSMenuItem!

    private var metricsToken: MetricsObserverToken?
    private var isCleaning = false

    /// The self-updater's ENTIRE user interface is this one menu item's
    /// title. There is no window, no sheet, no alert and no notification
    /// anywhere in the update path — see `checkForUpdates(silent:)` for
    /// why a failed check must be invisible.
    private var updateTimer: Timer?
    private var updateResetWork: DispatchWorkItem?
    private var isUpdating = false
    private static let restingUpdateTitle = "Проверить обновления…"

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

        scheduleUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let metricsToken { MetricsEngine.shared.remove(metricsToken) }
        updateTimer?.invalidate()
        updateResetWork?.cancel()
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

        // THE ONLY THING IN MACPULSE THAT CAN SHOW A PERMISSION DIALOG,
        // and it only can because the user clicked this line.
        calendarItem = NSMenuItem(title: "Показывать следующую встречу",
                                  action: #selector(toggleCalendar), keyEquivalent: "")
        calendarItem.target = self
        calendarItem.state = CalendarEngine.shared.isEnabledByUser ? .on : .off
        calendarItem.toolTip = "Читает только время начала ближайшей встречи. "
                             + "Названия встреч никуда не записываются и не отправляются."
        menu.addItem(calendarItem)

        menu.addItem(.separator())

        // The self-updater's whole interface. Its TITLE is the state
        // display — "Проверяю…", "Скачиваю v1.0.1… 42%", "Обновлений нет
        // (v1.0.0)" — because a menu item the user has just clicked is
        // the one place a status line costs nothing and interrupts
        // nobody. Same shape the sibling project uses.
        updateItem = NSMenuItem(title: Self.restingUpdateTitle,
                                action: #selector(checkForUpdatesManually), keyEquivalent: "")
        updateItem.target = self
        updateItem.toolTip = "Загружает новую версию с GitHub и перезапускает приложение. "
                           + "Это единственное сетевое соединение MacPulse наружу."
        menu.addItem(updateItem)

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
        // The header names the top app by footprint, which is the only
        // thing in this process that reads the per-app table while the
        // island's panel is shut. Say so, so the engine samples the
        // expensive metrics at full rate for as long as the menu is up and
        // not one tick longer. See MetricsEngine.Cadence.
        MetricsEngine.shared.setDetail(.statusMenu, needed: true)
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

        // FREE RECOVERY, AND THE ONLY ONE THERE IS. EventKit posts nothing
        // when the user flips the switch in System Settings, and the engine
        // stops sampling once it is in a dead end. One authorizationStatus
        // call, measured 232 us, and only while the menu is coming down.
        CalendarEngine.shared.revalidate()
        CalendarEngine.shared.refreshNow()
        calendarItem.state = CalendarEngine.shared.isEnabledByUser ? .on : .off
        if let hint = CalendarFmt.unavailableHint(CalendarEngine.shared.snapshot.status) {
            calendarItem.toolTip = hint
        }

        islandItem.title = island.isVisible ? "Скрыть островок" : "Показать островок"
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        MetricsEngine.shared.setDetail(.statusMenu, needed: false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === headerItem { return false }
        if menuItem === cleanupItem { return !isCleaning }
        if menuItem === updateItem { return !isUpdating }
        return true
    }

    // MARK: - Self-update
    //
    // See Sources/Updater.swift for the contract this operates under —
    // one file, HTTPS, three GitHub hosts, nothing else.

    /// One check shortly after launch, then one every six hours.
    ///
    /// COST. MacPulse idles at 0.27% of one core and this must not appear
    /// in that number at all, so:
    ///
    ///   * Six hours, not six minutes. One round trip per 21 600 seconds.
    ///     A full check measured end to end is a few tens of milliseconds
    ///     of CPU, i.e. around 0.0002% of a core amortised — three orders
    ///     of magnitude under the idle budget. `--cost-log` is what
    ///     proves that rather than this comment.
    ///   * A 30-minute `tolerance`, so the timer never forces a wake of
    ///     its own — the kernel coalesces it into a wake that was going
    ///     to happen anyway. A timer without tolerance is a timer that
    ///     costs power even when its handler is free.
    ///   * Between checks the updater owns no thread and no connection:
    ///     the URLSession is ephemeral, created per request and
    ///     invalidated in its own completion handler.
    ///
    /// The launch check waits 45 s deliberately: long enough that it is
    /// not competing with the island's first layout, and late enough
    /// that `--cost-log`'s default 10 s settle window does NOT exclude
    /// it. The measurement should contain the check, not dodge it.
    private func scheduleUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(silent: true)
        }
        timer.tolerance = 30 * 60
        updateTimer = timer
    }

    /// `silent` means: a failure is invisible.
    ///
    /// This is the rule the whole update path is built around. A user who
    /// did not ask to check for updates must never see that a check
    /// failed — no dialog at launch, no badge, not even a changed menu
    /// title. Offline is the normal state of a laptop, not an error, and
    /// an updater that reports it is an updater the user learns to
    /// resent. Failures go to NSLog and nowhere else.
    ///
    /// A MANUAL check is the opposite: the user asked, so they get an
    /// answer either way, in the item's title.
    private func checkForUpdates(silent: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        updateResetWork?.cancel()

        Updater.checkForUpdate { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .unreachable(let why):
                    NSLog("MacPulse: update check failed: \(why)")
                    self.isUpdating = false
                    if !silent {
                        self.updateItem.title = "Не удалось проверить обновления"
                        self.resetUpdateItemLater()
                    } else {
                        self.updateItem.title = Self.restingUpdateTitle
                    }

                case .upToDate(let version):
                    NSLog("MacPulse: up to date (v\(version))")
                    self.isUpdating = false
                    if !silent {
                        self.updateItem.title = "Обновлений нет (v\(version))"
                        self.resetUpdateItemLater()
                    } else {
                        self.updateItem.title = Self.restingUpdateTitle
                    }

                case .available(let release):
                    NSLog("MacPulse: v\(release.version) available, downloading")
                    self.updateItem.title = "Скачиваю v\(release.version)… 0%"
                    self.install(release)
                }
            }
        }
    }

    private func install(_ release: Updater.ReleaseInfo) {
        Updater.downloadAndInstall(release) { [weak self] fraction in
            // Already on the main thread — Updater dispatches it there.
            guard let self else { return }
            if fraction >= 1 {
                self.updateItem.title = "Проверяю и устанавливаю v\(release.version)…"
            } else {
                self.updateItem.title = "Скачиваю v\(release.version)… \(Int(fraction * 100))%"
            }
        } completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let version):
                    // The swap script relaunches us a second from now, so
                    // this title is mostly there for the instant before
                    // the app goes away.
                    NSLog("MacPulse: installed v\(version), relaunching")
                    self.updateItem.title = "Установлено v\(version) — перезапуск…"
                case .failure(let why):
                    // EVERY one of these leaves the installed app exactly
                    // as it was. Nothing is swapped in that did not pass
                    // all six checks in Updater.validate.
                    NSLog("MacPulse: update refused — \(why)")
                    self.isUpdating = false
                    self.updateItem.title = "Обновление не установлено"
                    self.resetUpdateItemLater()
                }
            }
        }
    }

    /// Without this, a finished check leaves the item permanently
    /// captioned with a stale result and the user has no way to ask
    /// again. Cancellable, so a second click does not get stomped by the
    /// first click's pending reset.
    private func resetUpdateItemLater() {
        updateResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isUpdating else { return }
            self.updateItem.title = Self.restingUpdateTitle
        }
        updateResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
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

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        // `.denied` is the one state where the checkmark cannot mean what
        // it says: macOS will not re-prompt. Open the pane where the
        // refusal can be undone instead.
        //
        // DELIBERATELY NOT a greyed-out item in validateMenuItem: that
        // leaves a denied user with no way back at all.
        if case .unavailable(.denied) = CalendarEngine.shared.snapshot.status {
            _ = CalendarEngine.openPrivacySettings()
            return
        }
        let enabled = !CalendarEngine.shared.isEnabledByUser
        CalendarEngine.shared.setEnabled(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func checkForUpdatesManually() {
        guard !isUpdating else { return }
        updateItem.title = "Проверяю…"
        checkForUpdates(silent: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
