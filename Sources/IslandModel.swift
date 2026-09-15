import AppKit
import Combine

// =====================================================================
// View model for the island. Main thread only.
//
// THE PUBLISHING RULE, which is the whole reason this file looks the way
// it does:
//
//   A @Published write invalidates EVERY SwiftUI view that observes this
//   object, whether or not that view reads the property that changed.
//   IslandView observes it, so one careless write per tick re-evaluates
//   the entire island — collapsed or not.
//
// Measured on this machine (probe_ui, 4 x 45 s, task_thread_times_info):
//   island + SwiftUI host, nothing publishing ......... 0.019% of a core
//   + 1 Hz @Published churn into a TRIVIAL view ....... 0.316%
//   + 1 Hz status item NSImage redraw ................. 0.389%
//   both .............................................. 0.412%
// against the full 441-pid process walk at 0.059%. Measuring the machine
// is nearly free; telling SwiftUI about it is what costs.
//
// So this model publishes three things and no others:
//
//   `strip`          what the COLLAPSED island draws. One enum. Changes
//                    when the kernel's pressure verdict changes, i.e.
//                    almost never. Written every tick, published only on
//                    a real change.
//   `memorySection`  what the OPEN panel draws — as the STRINGS the view
//                    puts on screen, not as raw bytes. Two ticks that
//                    render identically compare equal and publish
//                    nothing. NOT WRITTEN AT ALL while the panel is shut.
//   the rail         which sections are live, which one is selected, the
//                    footer line.
//
// The raw snapshot is kept in a plain stored property. Anything that
// wants it outside a view body can read it; nothing observes it.
// =====================================================================

enum IslandStatus: Int, Equatable {
    /// Pointer elsewhere. Bare strip, no panel in the view tree.
    case closed
    /// Pointer over the strip. It grows a couple of points; the dwell
    /// timer is running.
    case popping
    /// Panel is out, either by dwell or by an explicit click.
    case opened
}

/// What happened after the user clicked Quit on one specific row.
/// NOTHING here is ever entered automatically — every transition out of
/// `.idle` is a click the user made on that exact app.
enum QuitPhase: Equatable {
    case idle
    /// Graceful `terminate()` sent; waiting to see whether it took.
    case asked
    /// It did not take (unsaved changes, a modal sheet, a hung app).
    /// Only now is force quit offered, and only for this row.
    case needsForce
    case forced
    case gone
    case failed(String)
}

// MARK: - Published view state

/// Everything the COLLAPSED island draws. Deliberately tiny: this is the
/// only thing allowed to change while the panel is shut.
struct IslandStripState: Equatable {
    var pressure: MemoryPressureLevel?
}

/// One row of the Память section, already formatted.
///
/// The strings are what appears on screen, so two ticks that would draw
/// the same pixels compare equal — which is the point. `icon` is an
/// instance from `AppIconCache`, compared by identity: the same app
/// yields the same object, so it never falsifies the comparison.
struct AppRowState: Equatable, Identifiable {
    let pid: pid_t
    var id: pid_t { pid }
    let name: String
    let groupCount: Int
    let cpu: String
    let footprint: String
    let isApplication: Bool
    let icon: NSImage?

    static func == (a: AppRowState, b: AppRowState) -> Bool {
        a.pid == b.pid && a.name == b.name && a.groupCount == b.groupCount
            && a.cpu == b.cpu && a.footprint == b.footprint
            && a.isApplication == b.isApplication && a.icon === b.icon
    }
}

/// Everything the Память section draws, as drawn.
struct MemorySectionState: Equatable {
    var pressure: MemoryPressureLevel?
    /// 0...1, already quantised to one point of the 532 pt bar. nil is
    /// "not measurable" and draws an EMPTY track — never a zero fill.
    var barFraction: Double?
    var usedLine: String = "—"
    var swapLine: String = "—"
    var coverageLine: String = ""
    var rows: [AppRowState] = []
}

// MARK: -

final class IslandModel: ObservableObject {

    // ---- raw data: stored, NOT published ----

    /// Most recent snapshot. Read it from anywhere on main; observing it
    /// is what this file exists to prevent.
    private(set) var snapshot: MetricsSnapshot?

    // ---- interaction state ----
    @Published private(set) var status: IslandStatus = .closed
    /// Click-to-pin: the panel stays out until the user clicks again.
    @Published private(set) var isPinned = false
    @Published private(set) var quitPhases: [pid_t: QuitPhase] = [:]

    /// Set from the controller so the SwiftUI layer can draw the correct
    /// body width without knowing anything about NSScreen.
    @Published private(set) var notchSize = CGSize(width: 180, height: 32)
    @Published private(set) var hasPhysicalNotch = true

    // ---- wings ----
    //
    // ASYMMETRIC ON PURPOSE. The left wing has 0.5 pt of measured
    // clearance against the frontmost app's menus and is frozen forever;
    // the right wing has 172.5 pt and is the only expandable surface the
    // collapsed island has. See IslandMetrics for the measurements.

    /// Frozen. Not a var by accident — see IslandMetrics.leadingWingWidth.
    @Published private(set) var leadingWingWidth: CGFloat = IslandMetrics.leadingWingWidth
    /// 26 at rest, up to `trailingWingLimit` when something occupies it.
    @Published private(set) var trailingWingWidth: CGFloat = IslandMetrics.restingWingWidth
    /// Runtime ceiling, from MacPulse's own status item position. Not
    /// published: a change to it only ever moves `trailingWingWidth`, and
    /// that IS published.
    private(set) var trailingWingLimit: CGFloat = IslandMetrics.maxTrailingWingWidth

    /// Fires AFTER a wing width has actually changed.
    ///
    /// THE TRAP THIS CLOSES: the controller hit-tests a rect it derives
    /// from these widths, and arms the panel from mouse-MOVED events. A
    /// wing that grows while the pointer sits still would leave the panel
    /// disarmed over its own newly drawn pixels until the user happened to
    /// move the mouse. The controller re-derives and re-arms from here.
    var wingWidthsDidChange: (() -> Void)?

    // ---- collapsed strip ----
    @Published private(set) var strip = IslandStripState()

    // ---- the router ----

    /// Sections that have state RIGHT NOW, in rail order. One chip on a
    /// quiet machine.
    @Published private(set) var visibleSections: [IslandSectionID] = [.memory]
    /// The section in the body. Always one of `visibleSections`.
    @Published private(set) var selectedSection: IslandSectionID = .memory
    /// One line summarising the live sections that are NOT selected.
    @Published private(set) var footerLine: String = ""
    /// What the collapsed trailing slot is currently showing, and
    /// therefore which tab the panel opens on. The strip is the table of
    /// contents and the click is the navigation; with a bare dot that
    /// means Память. Not published — it is only read at open time.
    private(set) var stripSlotSection: IslandSectionID = .memory

    // ---- the Память section ----
    @Published private(set) var memorySection = MemorySectionState()

    // ---- features that are not driven by MetricsEngine ----
    //
    // This one is EVENT-DRIVEN and publishes only when its own displayed
    // value changes, which is the hard rule from the measurements at the
    // top of this file: it moves when a sensor actually starts or stops,
    // and on a normal day that is never.

    /// Who is holding the microphone, and whether a camera is on.
    @Published private(set) var privacy = PrivacyState()

    private let iconCache = AppIconCache()
    private var token: MetricsObserverToken?
    private lazy var privacyWatcher = PrivacyWatcher(model: self)

    // MARK: - Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        IslandFeatures.registerAll()
        MetricsEngine.shared.start()
        token = MetricsEngine.shared.observe { [weak self] snap in
            self?.ingest(snap)
        }
        privacyWatcher.start()
    }

    func stop() {
        if let token { MetricsEngine.shared.remove(token) }
        token = nil
        privacyWatcher.stop()
    }

    func setGeometry(notchSize: CGSize, hasPhysicalNotch: Bool) {
        if self.notchSize != notchSize { self.notchSize = notchSize }
        if self.hasPhysicalNotch != hasPhysicalNotch { self.hasPhysicalNotch = hasPhysicalNotch }
    }

    private func ingest(_ snap: MetricsSnapshot) {
        snapshot = snap

        // Always: the one value the collapsed island draws.
        let nextStrip = IslandStripState(pressure: snap.memory?.pressureLevel)
        if strip != nextStrip { strip = nextStrip }

        // Only while the panel is actually on screen. Closed, the expanded
        // hierarchy is not in the view tree, so building its state would be
        // work whose only effect is to invalidate views that cannot be seen.
        if status == .opened {
            refreshPanel(snap)
        }

        // Retire finished quit rows once the app is really gone.
        pruneQuitPhases()
    }

    // MARK: - Wings

    /// Ask for a trailing wing width. Clamped to the resting width and to
    /// whatever room the status item leaves; callers do not need to know
    /// either bound. Pass `IslandMetrics.restingWingWidth` to give it back.
    func requestTrailingWing(_ width: CGFloat) {
        precondition(Thread.isMainThread)
        let clamped = min(max(width, IslandMetrics.restingWingWidth), trailingWingLimit)
        guard abs(trailingWingWidth - clamped) > 0.01 else { return }
        trailingWingWidth = clamped
        wingWidthsDidChange?()
    }

    /// The runtime ceiling, recomputed by the controller whenever the
    /// screen configuration or the status item's position changes. If the
    /// wing is currently wider than the new ceiling it is pulled in at
    /// once — a wing drawn under a menu bar extra is the failure this
    /// bound exists to prevent, and waiting for the next feature tick to
    /// fix it is not good enough.
    func setTrailingWingLimit(_ limit: CGFloat) {
        precondition(Thread.isMainThread)
        let clamped = min(max(limit, IslandMetrics.restingWingWidth),
                          IslandMetrics.maxTrailingWingWidth)
        guard abs(trailingWingLimit - clamped) > 0.01 else { return }
        trailingWingLimit = clamped
        if trailingWingWidth > clamped {
            trailingWingWidth = clamped
            wingWidthsDidChange?()
        }
    }

    /// Which section the collapsed trailing slot is showing. Sets the
    /// panel's default tab. Feature code calls this alongside
    /// `requestTrailingWing`.
    func setStripSlotSection(_ id: IslandSectionID) {
        precondition(Thread.isMainThread)
        stripSlotSection = id
    }

    // MARK: - Interaction state

    func setStatus(_ new: IslandStatus) {
        guard status != new else { return }
        let wasOpen = status == .opened
        status = new
        if new == .opened && !wasOpen {
            // Refresh BEFORE selecting. `visibleSections` is whatever it
            // was when the panel last closed, and the strip slot's section
            // is precisely the one most likely to have come alive since —
            // selecting against the stale list would bounce the user to
            // Память on the one open where they least want it.
            if let snapshot { refreshPanel(snapshot) }
            // Opening navigates to whatever the strip slot was showing.
            selectIfLive(stripSlotSection)
        }
    }

    func setPinned(_ new: Bool) {
        guard isPinned != new else { return }
        isPinned = new
    }

    // MARK: - The router

    func select(_ id: IslandSectionID) {
        precondition(Thread.isMainThread)
        guard visibleSections.contains(id), selectedSection != id else { return }
        selectedSection = id
        // Only the footer depends on which tab is selected; the section
        // states do not, so a tab click does not rebuild them.
        refreshFooter()
    }

    private func selectIfLive(_ id: IslandSectionID) {
        let target = visibleSections.contains(id) ? id : .memory
        guard selectedSection != target else { return }
        selectedSection = target
        // The footer lists the live sections that are NOT selected, so it
        // has to follow every selection change or it shows the tab the
        // user is already looking at.
        refreshFooter()
    }

    /// Rebuild everything the OPEN panel draws. Never called while shut.
    private func refreshPanel(_ snap: MetricsSnapshot) {
        rebuildMemorySection(snap)
        refreshRouter()
    }

    /// Which chips the rail shows, and which one is selected.
    ///
    /// Split out of `refreshPanel` because a feature that is NOT driven by
    /// MetricsEngine can come alive between two metric ticks, and the rail
    /// would otherwise be up to a full tick out of date at exactly the
    /// moment the user is looking at it.
    private func refreshRouter() {
        // The rail lists only what is live. Memory always is, which is why
        // it is the fallback below and why the rail is never empty.
        let ids = IslandSectionRegistry.sections.filter { $0.hasState(self) }.map(\.id)
        if visibleSections != ids { visibleSections = ids }

        // The selected tab can go quiet under the user (a print finishes
        // while they are looking at it). Fall back rather than show a body
        // for a section with nothing in it.
        if !ids.contains(selectedSection) { selectedSection = .memory }

        refreshFooter()
    }

    // MARK: - Feature state

    /// Called by `PrivacyWatcher` on the main thread when a sensor starts
    /// or stops.
    ///
    /// Deliberately does NOT touch the wings. The privacy rail is sized to
    /// fit inside the RESTING 26 pt wing precisely so that the one signal
    /// nothing may preempt can never be starved by a width negotiation it
    /// might lose. See IslandMetrics.privacyRailWidth.
    func setPrivacy(_ state: PrivacyState) {
        precondition(Thread.isMainThread)
        guard privacy != state else { return }
        privacy = state
        // The footer names the app in words. It is not a section, so
        // nothing else would refresh it.
        if status == .opened { refreshFooter() }
    }

    private func refreshFooter() {
        var clauses: [String] = []
        // FIRST, ALWAYS. The privacy rail has no tab of its own — a safety
        // signal you have to navigate to is not one — so the footer is
        // where "which app is holding the microphone" gets said in words
        // rather than as a 6 pt dot. It leads the line because nothing
        // else on it could matter more.
        if let privacyClause = PrivacyFooter.line(privacy) { clauses.append(privacyClause) }
        clauses += IslandSectionRegistry.sections
            .filter { $0.id != selectedSection && visibleSections.contains($0.id) }
            .compactMap { $0.footerSummary(self) }
            .filter { !$0.isEmpty }
        let line = clauses.joined(separator: " · ")
        if footerLine != line { footerLine = line }
    }

    private func rebuildMemorySection(_ snap: MetricsSnapshot) {
        let m = snap.memory

        // Quantised to ONE POINT of the 532 pt bar. Below that the fill is
        // pixel-identical, so republishing would re-lay-out the panel to
        // draw exactly what is already on it.
        let bar = m?.pressureHeuristic.map { h -> Double in
            let clamped = min(max(h, 0), 1)
            return (clamped * 532).rounded() / 532
        }

        let apps = Array((snap.processes?.apps ?? []).prefix(5))
        let pids = Set(apps.map(\.pid))
        iconCache.retainOnly(pids)

        let rows = apps.map { app in
            AppRowState(
                pid: app.pid,
                name: app.name,
                groupCount: app.memberPIDs.count,
                cpu: UIFmt.pct(app.cpuPercent.map { $0 / 100 }),
                footprint: UIFmt.bytes(app.footprintBytes),
                isApplication: app.isApplication,
                icon: iconCache.icon(pid: app.pid,
                                     bundleIdentifier: app.bundleIdentifier,
                                     isApplication: app.isApplication)
            )
        }

        // Honest coverage note: unprivileged we can only introspect our OWN
        // uid, so this is never "all processes". top sees everything only
        // because it is setuid root.
        let coverage = snap.processes.map {
            "видно \($0.introspectedCount) из \($0.pidCount) процессов (только ваш пользователь)"
        } ?? ""

        let next = MemorySectionState(
            pressure: m?.pressureLevel,
            barFraction: bar,
            usedLine: "\(UIFmt.bytes(m?.usedBytes)) из \(UIFmt.bytes(m?.totalBytes)) занято",
            swapLine: "Своп \(UIFmt.bytes(m?.swapUsedBytes)) из \(UIFmt.bytes(m?.swapTotalBytes))",
            coverageLine: coverage,
            rows: rows
        )
        if memorySection != next { memorySection = next }
    }

    // MARK: - Derived readouts

    var pressureLevel: MemoryPressureLevel? { strip.pressure }

    // MARK: - The one action with a real effect
    //
    // The research verdict is blunt: quitting a memory-hog app is the only
    // optimization with a measurable effect on memory pressure (Telegram
    // alone was 1.78 GB here = 22% of this machine's RAM). Cache clearing
    // does nothing for memory and a "free RAM" button is actively harmful.
    //
    // SAFETY RULES, enforced structurally and not just by convention:
    //   * only ever the single app whose button was clicked;
    //   * graceful terminate() first, always;
    //   * forceTerminate() only as an explicit SECOND click, only after the
    //     graceful attempt has demonstrably failed, and never on a timer;
    //   * nothing that is not a real NSRunningApplication is ever touched.
    // There is deliberately no "quit everything" button and no heuristic
    // auto-killing anywhere in this file. Unsaved work is at stake.

    func quitPhase(for pid: pid_t) -> QuitPhase { quitPhases[pid] ?? .idle }

    func requestQuit(pid: pid_t) {
        precondition(Thread.isMainThread)
        guard quitPhase(for: pid) == .idle else { return }
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            quitPhases[pid] = .failed("не приложение")
            return
        }
        quitPhases[pid] = .asked
        let ok = running.terminate()          // graceful: sends the Quit Apple event
        if !ok {
            quitPhases[pid] = .needsForce
            return
        }
        // Give it time to put up a save dialog and for the user to answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.quitPhase(for: pid) == .asked else { return }
            if NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true {
                self.quitPhases[pid] = .gone
            } else {
                self.quitPhases[pid] = .needsForce
            }
        }
    }

    func forceQuit(pid: pid_t) {
        precondition(Thread.isMainThread)
        guard quitPhase(for: pid) == .needsForce else { return }
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            quitPhases[pid] = .gone
            return
        }
        quitPhases[pid] = .forced
        _ = running.forceTerminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true {
                self.quitPhases[pid] = .gone
            } else {
                self.quitPhases[pid] = .failed("не отвечает")
            }
        }
    }

    func cancelQuit(_ pid: pid_t) {
        quitPhases[pid] = nil
    }

    private func pruneQuitPhases() {
        guard !quitPhases.isEmpty else { return }
        var next = quitPhases
        for (pid, phase) in quitPhases {
            let alive = !(NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true)
            switch phase {
            case .gone where !alive:
                next[pid] = nil                     // row is gone; forget it
            case .needsForce where !alive:
                next[pid] = nil                     // user quit it by hand meanwhile
            default:
                break
            }
        }
        if next != quitPhases { quitPhases = next }
    }
}
