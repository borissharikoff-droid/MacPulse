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
    // the right wing is the only expandable surface the collapsed island
    // has. How far it may expand is bounded by our own status item and by
    // the leftmost position that item has held — never by a measurement of
    // somebody else's menu bar extra. See IslandMetrics for why.

    /// Frozen. Not a var by accident — see IslandMetrics.leadingWingWidth.
    @Published private(set) var leadingWingWidth: CGFloat = IslandMetrics.leadingWingWidth
    /// 26 at rest, up to `trailingWingLimit` when something occupies it.
    @Published private(set) var trailingWingWidth: CGFloat = IslandMetrics.restingWingWidth
    /// Runtime ceiling, from MacPulse's own status item position. Not
    /// published: a change to it only ever moves `trailingWingWidth`, and
    /// that IS published.
    ///
    /// STARTS AT THE RESTING WIDTH, i.e. "no growth until somebody has
    /// measured where our own icon is". The controller supplies the real
    /// bound one main-queue turn after launch. Starting at the ceiling
    /// instead would mean the island could draw its widest plate during
    /// exactly the window in which nothing had checked whether there was
    /// room for it.
    private(set) var trailingWingLimit: CGFloat = IslandMetrics.restingWingWidth

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
    // Both of these are EVENT-DRIVEN or slow-polled and publish only when
    // their own displayed value changes, which is the hard rule from the
    // measurements at the top of this file. The printer moves at most
    // once every 8 s while a print is live and not at all otherwise; the
    // privacy rail moves only when a sensor actually starts or stops.

    /// The current print, or nil for "there is no print worth a pixel".
    /// nil is the normal state — the printer is powered off most of the
    /// time — and it means no chip, no ring, no footer clause.
    @Published private(set) var printer: PrinterReading?
    /// Who is holding the microphone, and whether a camera is on.
    @Published private(set) var privacy = PrivacyState()

    // ---- the five sections added in the second wave ----
    //
    // SAME RULE AS ABOVE, and it is the only rule that matters here. Each
    // of these is written by its own event source — a watcher, a poller,
    // an engine observer — and every setter below compares before it
    // assigns, so a sample that would draw the same pixels publishes
    // nothing. NONE of them is written on the metrics tick, with one
    // documented exception: `calendarStrip`, which is a function of the
    // CLOCK and therefore cannot be event-driven. Its cost is one
    // Optional read; see `refreshCalendarStrip()`.

    /// Who is carrying this machine's traffic, from routing-table
    /// evidence. nil until the first sample lands (12 s after launch), and
    /// nil is "could not measure", never "no tunnel". Republished only
    /// when something the section can draw actually changed — see
    /// `TunnelMetrics.==`, which deliberately ignores the sample cost.
    @Published private(set) var tunnel: TunnelMetrics?

    /// The next meeting, or the engine's measured "there is none".
    /// `hasState` is `next != nil`, so on a machine whose only calendar
    /// events are all-day holidays this stays quiet for ever.
    @Published private(set) var calendar = CalendarSnapshot(status: .off)

    /// The COLLAPSED strip's countdown, already formatted ("12′"), or nil
    /// for "no meeting has earned the slot". Non-nil for exactly the 15
    /// minutes before a meeting starts. A STRING, re-derived on the tick,
    /// because the collapsed island publishes almost nothing and a
    /// countdown formatted inside the strip's view body would be drawn
    /// once and then freeze at that minute.
    @Published private(set) var calendarStrip: String?

    /// Which apps have an audio OUTPUT STREAM open. Empty is the normal
    /// state and means no chip, no strip icon, no footer clause; nil means
    /// the audio server could not be asked, which is not the same thing.
    /// "Open stream" is NOT "playing" — see FeatureSound.swift.
    @Published private(set) var sound = SoundState()

    /// The memory-pressure notifier's user-visible state: what it told the
    /// user, whether the user actually saw it, and whether they switched
    /// it off. NOT a per-tick value — `PressureAlertBridge` publishes it
    /// only when a notification is posted, when the OS's permission answer
    /// changes, when the switch is flipped, or (for the one live line)
    /// while the panel is open. See FeaturePressureAlert.swift.
    @Published private(set) var pressureAlert = PressureAlertState()

    /// Clipboard history, already formatted. Written ONLY when the
    /// clipboard actually moves — never on a tick. See
    /// IslandSectionClipboard.swift.
    @Published private(set) var clipboard = ClipboardSectionState()

    private let iconCache = AppIconCache()
    private var token: MetricsObserverToken?
    /// Not a `MetricsObserverToken`: the calendar engine has its own
    /// observer list because it publishes on its own schedule and not on
    /// the metrics tick. Same contract — dropping the token does not
    /// unsubscribe, `remove` does.
    private var calendarToken: CalendarObserverToken?
    private lazy var printerPoller = PrinterPoller(model: self)
    private lazy var privacyWatcher = PrivacyWatcher(model: self)
    private lazy var soundWatcher = SoundWatcher(model: self)
    private lazy var tunnelWatcher = TunnelWatcher(model: self)

    // MARK: - Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        IslandFeatures.registerAll()
        MetricsEngine.shared.start()
        token = MetricsEngine.shared.observe { [weak self] snap in
            self?.ingest(snap)
        }
        privacyWatcher.start()
        printerPoller.start()
        soundWatcher.start()
        tunnelWatcher.start()

        // The memory-pressure notifier. It subscribes to MetricsEngine
        // itself, because unlike every other feature here it has to keep
        // watching while the panel is shut. It prompts for nothing at
        // launch — see FeaturePressureAlert.swift.
        PressureAlertBridge.shared.start(model: self)

        // Event-driven, not tick-driven: the engine publishes only on a
        // real `changeCount` transition, so on an idle machine this never
        // calls back at all. See IslandSectionClipboard.swift.
        ClipboardFeature.shared.start(model: self)

        // NEVER PROMPTS. Starts only if the user turned the feature on in
        // the status-item menu AND macOS has already granted access. On a
        // fresh machine this is one `UserDefaults.bool` and a return.
        CalendarEngine.shared.startIfEnabled()
        calendarToken = CalendarEngine.shared.observe { [weak self] snap in
            self?.setCalendar(snap)
        }
    }

    func stop() {
        if let token { MetricsEngine.shared.remove(token) }
        token = nil
        // Balanced with setStatus(.opened): a panel that is torn down while
        // open must not leave the engine sampling at full rate for a view
        // that no longer exists.
        MetricsEngine.shared.setDetail(.islandPanel, needed: false)
        privacyWatcher.stop()
        printerPoller.stop()
        soundWatcher.stop()
        tunnelWatcher.stop()
        PressureAlertBridge.shared.stop()
        ClipboardFeature.shared.stop()
        // Dropping the token does NOT unsubscribe — same contract as
        // MetricsObserverToken.
        if let calendarToken { CalendarEngine.shared.remove(calendarToken) }
        calendarToken = nil
        CalendarEngine.shared.stop()
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

        // The meeting countdown, which the engine deliberately does not
        // publish: it is derived from the CLOCK. One Optional read per
        // tick when there is no meeting, which is the normal state.
        refreshCalendarStrip()

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
        // The printer poller speeds up while somebody can see the answer
        // and pulls a fresh reading the moment the panel opens.
        printerPoller.setPanelOpen(new == .opened)
        // Same reason, cheaper subject: a ~2 ms HAL sweep so the Звук tab
        // is not showing a stale answer at the moment it opens.
        soundWatcher.setPanelOpen(new == .opened)
        // So does the tunnel watcher: 10 s shut, 4 s open. Routes change
        // when a tunnel comes up or goes down and at no other time, so the
        // shut cadence is a staleness bound, not a sampling rate.
        tunnelWatcher.setPanelOpen(new == .opened)
        // So does the metrics engine. The panel is the only thing in the app
        // that draws the per-app table, and nothing anywhere draws watts,
        // temperatures, disk capacity or battery — so while it is shut the
        // engine samples those on a long cadence. Same 1 Hz base tick either
        // way; see MetricsEngine.Cadence. `.popping` does not count: the
        // panel is not in the view tree until `.opened`.
        MetricsEngine.shared.setDetail(.islandPanel, needed: new == .opened)
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
    /// MetricsEngine — the printer, say — can come alive between two
    /// metric ticks, and the rail would otherwise be up to a full tick out
    /// of date at exactly the moment the user is looking at it.
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

    /// Called by `PrinterPoller` on the main thread after every poll.
    func setPrinter(_ reading: PrinterReading?) {
        precondition(Thread.isMainThread)
        guard printer != reading else { return }
        printer = reading
        updateTrailingSlot()
        if status == .opened { refreshRouter() }
    }

    /// Called by `TunnelWatcher` on the main thread after every sample.
    func setTunnel(_ metrics: TunnelMetrics?) {
        precondition(Thread.isMainThread)
        guard tunnel != metrics else { return }
        tunnel = metrics
        updateTrailingSlot()
        if status == .opened { refreshRouter() }
    }

    /// Called by `SoundWatcher` on the main thread after every sweep.
    func setSound(_ state: SoundState) {
        precondition(Thread.isMainThread)
        guard sound != state else { return }
        sound = state
        updateTrailingSlot()
        if status == .opened { refreshRouter() }
    }

    /// Called by `PressureAlertBridge` on the main thread. Same contract
    /// as `setPrinter`: it compares first, so a tick that would draw the
    /// same pixels publishes nothing.
    ///
    /// No `updateTrailingSlot()`. The notifier's whole point is that it
    /// speaks through Notification Centre; having also taken the one
    /// ambient slot in the menu bar would be saying the same thing twice.
    func setPressureAlert(_ state: PressureAlertState) {
        precondition(Thread.isMainThread)
        guard pressureAlert != state else { return }
        pressureAlert = state
        if status == .opened { refreshRouter() }
    }

    /// Called by `ClipboardFeature` on the main thread after every
    /// clipboard change. Event-driven, not tick-driven: `ClipboardEngine`
    /// publishes only on a real `changeCount` transition, so on an idle
    /// machine this is never called at all.
    ///
    /// Deliberately does NOT touch the wings. Clipboard history never
    /// earns a collapsed-strip slot — it has no state worth a pixel in a
    /// 77 pt wing — so there is no `requestTrailingWing` here and
    /// `stripSlotSection` is never `.clipboard`.
    func setClipboard(_ state: ClipboardSectionState) {
        precondition(Thread.isMainThread)
        guard clipboard != state else { return }
        clipboard = state
        // The rail gains its chip with a copy and loses it again when the
        // copy goes stale — see `ClipboardSectionState.isLive`.
        if status == .opened { refreshRouter() }
    }

    /// Called by `CalendarEngine`'s observer on the main thread. The
    /// engine only publishes when the MEANING changed — a different
    /// meeting, a different candidate count, a status change.
    func setCalendar(_ snapshot: CalendarSnapshot) {
        precondition(Thread.isMainThread)
        guard calendar != snapshot else { return }
        calendar = snapshot
        // At once, not on the next tick: a meeting that arrives already
        // inside its window must take the strip slot now.
        refreshCalendarStrip()
        if status == .opened { refreshRouter() }
    }

    /// THE WHOLE COST OF THE CALENDAR FEATURE AT IDLE: one Optional read
    /// and a compare against nil (measured 66.5 ns). It has to live on the
    /// tick rather than in the engine because `isImminent` is a function
    /// of the clock, and the engine's `isMeaningfullyEqual` dedup compares
    /// the MEETING — when a meeting crosses into its window the engine
    /// re-queries and then publishes nothing, because the same meeting is
    /// still the next meeting.
    private func refreshCalendarStrip() {
        let text = calendar.isImminent ? CalendarFmt.strip(calendar.next) : nil
        guard calendarStrip != text else { return }
        let hadSlot = calendarStrip != nil
        calendarStrip = text
        // Only the APPEARANCE or DISAPPEARANCE of the countdown is a
        // question for the arbiter; a minute ticking over is not.
        if hadSlot != (text != nil) { updateTrailingSlot() }
    }

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

    /// THE COLLAPSED STRIP'S SLOT ARBITER.
    ///
    /// The trailing wing shows exactly ONE thing, and which one is a
    /// cross-feature question, so it cannot live inside any single
    /// feature's file — priority is only meaningful relative to everything
    /// else competing for the same 79.5 pt.
    ///
    /// Priority, by cost-of-missing-it (from the architecture spike, then
    /// settled between four features that all wanted the same 77 pt):
    ///   1. transient toast          — not built yet
    ///   2. print progress           — the only feature with an
    ///                                 UNRECOVERABLE deadline: hours of
    ///                                 machine time and a spool of filament
    ///   3. the next meeting         — a RECOVERABLE deadline, but a real
    ///                                 one, and it expires by itself: the
    ///                                 countdown is non-nil for exactly the
    ///                                 15 minutes before a start
    ///   4. audio output open        — no deadline, but transient: it is
    ///                                 gone when the sound stops, so it
    ///                                 cannot squat
    ///   5. a tunnel off the default route — no deadline AND no end. It is
    ///                                 last precisely because it is the
    ///                                 longest-lived of the four: a VPN
    ///                                 that has been up since breakfast
    ///                                 must not starve a meeting that
    ///                                 starts in nine minutes
    ///   0. nothing                  — the wing goes back to 26 pt
    ///
    /// NOT IN THIS LIST, on purpose: the pressure notifier (it speaks
    /// through Notification Centre, and saying the same thing twice is
    /// worse than saying it once) and the clipboard (a history has no
    /// instant worth an ambient pixel).
    ///
    /// The privacy rail is NOT in this list either. It is pinned at the far
    /// right of the wing and is drawn beside whatever wins here, never
    /// instead of it.
    ///
    /// IF YOU REORDER THESE BRANCHES, REORDER `IslandTrailingWing` TO
    /// MATCH. This method picks which tab the click navigates to; the wing
    /// picks what is drawn. Drawing one and navigating to the other is the
    /// bug that ordering comment exists to prevent.
    private func updateTrailingSlot() {
        if printer != nil {
            // Ask for the ceiling and LAY OUT to what comes back. The
            // ceiling is 77 pt — exactly what the widest row can use — and
            // the runtime bound can only cut it further (this machine's own
            // status item at x=952 leaves 79.5 pt, so 77 is what binds
            // here). Designing the slot for the requested width instead of
            // the granted one is the bug this comment exists to prevent.
            requestTrailingWing(IslandMetrics.maxTrailingWingWidth)
            setStripSlotSection(.printer)
        } else if calendarStrip != nil {
            // The ceiling as well: MeetingStripSlot borrows the print
            // slot's exact geometry (14 pt ring + 4 pt gap + 25 pt text),
            // so `trailingLayout` and `maxTrailingWingWidth` still bound
            // ONE worst case rather than two.
            requestTrailingWing(IslandMetrics.maxTrailingWingWidth)
            setStripSlotSection(.calendar)
        // SOUND AND TUNNEL ARE DELIBERATELY NOT HERE, and both used to be.
        // Measured on this machine, which is what changed my mind:
        //
        //   sound  — Zen holds an output stream open CONTINUOUSLY. Three
        //            probes two minutes apart, always "audio open: Zen".
        //            `hasOutput` is honestly documented as "somebody has a
        //            stream open", NOT "something is playing" — the play
        //            state is not knowable at all — so this lit the wing
        //            around the clock while saying nothing.
        //   tunnel — FlClashX is up permanently and is never the default
        //            route, so `deservesStripSlot` was permanently true.
        //            That gate was written to prevent a permanently-lit VPN
        //            badge and on this machine it produced exactly one.
        //
        // Applying this list's own rule — cost of missing it — settles it:
        // missing a print costs filament and hours, missing a meeting costs
        // the meeting, and missing "a browser has an audio stream open"
        // costs nothing. A wing that is always lit is a wing you stop
        // reading, which would cost the two above their only channel.
        //
        // Both KEEP their rail chips. The panel is where you go to look;
        // the wing is for what you must not miss without looking.
        } else {
            requestTrailingWing(IslandMetrics.restingWingWidth)
            setStripSlotSection(.memory)
        }
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
