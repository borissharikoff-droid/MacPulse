import AppKit
import Darwin
import UserNotifications

// =====================================================================
// «Давление» — tell the user memory is going bad BEFORE the machine
// starts doing something about it, and give them the one button that
// actually helps.
//
// No SwiftUI in this file. It owns the policy, the notification and the
// published view state; `IslandSectionPressure.swift` draws it.
//
// THIS IS A NOTIFIER, NOT A SAMPLER. It reads NOTHING per tick. It
// consumes the `MemoryPressureLevel` MemorySampler already put in the
// snapshot and the `AppUsage` rows ProcessSampler already computed —
// adding a second reader of `kern.memorystatus_vm_pressure_level` would
// be two sources of truth for one number. The three
// `kill_on_sustained_pressure_*` sysctls it DOES read (~1.4 us each,
// measured) are read at launch, on the panel's open edge, and while
// composing an alert. Never on a tick.
//
// WHY IT POLLS AT ALL, since Apple ships a memory-pressure event source:
// MEASURED on this machine (M2, macOS 26.6.2),
// `DispatchSource.makeMemoryPressureSource` fired ZERO times across five
// induced-pressure runs, including 63 s of sustained kernel warning level
// and two level-4 excursions — in a plain CLI, inside the allocating
// process, and inside a signed LSUIElement .app with the source on the
// main queue. Raw kqueue EVFILT_MEMORYSTATUS never fired either, and
// Apple's own `memory_pressure -l warn` just polls. Nothing in the
// alerting path may depend on that source.
//
// THE PROBLEM THE WHOLE POLICY EXISTS TO SOLVE. This 8 GB machine sits at
// kernel pressure level 2 for long stretches of ordinary work. A naive
// `level >= 2` alert fires more or less permanently, the user mutes
// MacPulse inside a day, and the one time it matters they never see it.
// MEASURED against the detector below: level pinned at 2 for six hours of
// 1 Hz samples produces exactly ONE alert where the naive rule would have
// produced 21 600. That is the feature. Do not "simplify" the dwell, the
// falling-edge debounce or the rearm — each of them is load-bearing and
// each has its measurement in the doc comment.
//
// THE COPY DOES NOT THREATEN. `kern.memorystatus.kill_on_sustained_pressure_count`
// reads 0 here and stayed 0 through 63 s of sustained warning pressure,
// two critical excursions and ~3.8 GB of incompressible allocation: the
// OS kill feature is DORMANT on this machine. So nothing below says macOS
// is about to kill anything unless that counter says it already has. See
// `PressureAlertCopy.killerClause`.
//
// IT NEVER TERMINATES ANYTHING. The alert's button hands a re-validated
// pid to `IslandModel.requestQuit` — graceful `terminate()`, the same
// guarded path the island's own rows use — and stops. There is no force
// path here at all; if the graceful quit does not take, IslandModel moves
// the row to `.needsForce` and the user presses force in the panel,
// looking at the app.
// =====================================================================


// =====================================================================
// MARK: - 1. The macOS 26 sustained-pressure killer
// =====================================================================

/// What `kern.memorystatus.kill_on_sustained_pressure_*` says right now.
///
/// THE TRAP THESE THREE OIDs SET, and the reason this is a type rather
/// than three loose numbers: `..._count` reads 0 here and it is tempting
/// to read that as "the threshold is zero, so the system will kill on the
/// next event". It is the opposite. `sysctl -w` on it answers `oid ... is
/// read only` — it is a KILL COUNTER, not a knob, and it read 0 before
/// and after every induced-pressure run, with no jetsam anywhere in
/// `log show` for those windows.
///
/// So the only honest sentence this data supports is "N processes have
/// been killed by the sustained-pressure killer in the last
/// `windowSeconds`", and here N is 0.
///
/// WIDTH NOTE, measured: all three oids are 8 bytes, unlike
/// `kern.memorystatus_vm_pressure_level` which is 4. Reading them through
/// `Sysctl.int32` happens to work on a little-endian machine and is
/// exactly the bug SamplingSupport warns about, so they go through
/// `Sysctl.uint64`.
struct SustainedPressureKiller: Equatable {

    /// Processes the sustained-pressure killer has killed inside the
    /// window. nil means the oid is absent (older macOS, or Apple removed
    /// it) — which is NOT the same as zero kills.
    let killCount: UInt64?
    /// `..._window_s`. 600 on this machine.
    let windowSeconds: UInt64?

    /// What we are entitled to SAY, as opposed to what we read.
    enum Verdict: Equatable {
        /// The oids are not on this system. Say nothing about jetsam.
        case unknown
        /// The oids exist and report zero kills in the window. The killer
        /// is dormant. Do not write "macOS is about to kill your apps".
        case dormant(windowSeconds: UInt64?)
        /// The killer has actually fired. Only now may the copy say so.
        case hasKilled(count: UInt64, windowSeconds: UInt64?)
    }

    var verdict: Verdict {
        guard let killCount else { return .unknown }
        return killCount == 0 ? .dormant(windowSeconds: windowSeconds)
                              : .hasKilled(count: killCount, windowSeconds: windowSeconds)
    }

    static func read() -> SustainedPressureKiller {
        SustainedPressureKiller(
            killCount: Sysctl.uint64("kern.memorystatus.kill_on_sustained_pressure_count"),
            windowSeconds: Sysctl.uint64("kern.memorystatus.kill_on_sustained_pressure_window_s")
        )
    }
}


// =====================================================================
// MARK: - 2. The edge detector
// =====================================================================

enum PressureAlertSeverity: Int, Equatable {
    case warning = 2
    case critical = 4
}

/// Why a tick did NOT produce an alert. Every branch that declines to
/// fire names itself, so the panel can tell the user why they are not
/// being bothered instead of showing nothing.
enum PressureAlertSuppression: Equatable {
    /// `pressureLevel` was nil. NOT "normal" — we could not measure.
    case unmeasured
    /// The sample stream had a hole (sleep, a stalled tick, the feature
    /// was muted and unmuted). A dwell cannot be claimed across a hole,
    /// so the episode clock restarted.
    case measurementGap
    /// Level 1, armed, nothing brewing.
    case normal
    /// Level 1, but we fired recently and are still serving the rearm dwell.
    case rearming(remaining: TimeInterval)
    /// Level dropped to 1 but the drop debounce has not elapsed, so the
    /// episode is still considered open. This is the falling-edge
    /// hysteresis; it stops a one-second dip from restarting a 45 s clock.
    case episodeSettling(normalFor: TimeInterval)
    /// Elevated, but the feature has not been running long enough. Login
    /// and app launch are memory-churny and the user did not ask about it.
    case startupGrace(remaining: TimeInterval)
    /// Elevated, but not for long enough yet. This is the sustained-dwell
    /// requirement and it is what stops "level == 2" from being an alert.
    case dwellTooShort(elapsed: TimeInterval, needed: TimeInterval)
    /// Already alerted about THIS episode. The next alert needs the level
    /// to come back down first.
    case alreadyAlertedThisEpisode
    /// Fired recently and the level never returned to normal for long
    /// enough to rearm.
    case notRearmed
    case cooldown(remaining: TimeInterval)
    case snoozed(remaining: TimeInterval)
    /// Rolling-window cap. A user who is alerted more than this in a day
    /// turns the feature off, and then it protects nobody.
    case dailyCapReached(cap: Int)
}

/// The detector said "now".
struct PressureAlertTrigger: Equatable {
    let severity: PressureAlertSeverity
    /// Level at the instant of the decision.
    let level: MemoryPressureLevel
    /// Highest level seen since this episode started.
    let peakLevel: MemoryPressureLevel
    /// How long the level has been >= warning, continuously (modulo the
    /// drop debounce), when the decision was made.
    let elevatedFor: TimeInterval
    /// How long the level has been == critical, continuously. nil unless
    /// currently critical.
    let criticalFor: TimeInterval?
    /// True when we had already alerted at `.warning` for this episode and
    /// this is the one permitted upgrade to `.critical`.
    let isEscalation: Bool
}

enum PressureEdgeOutcome: Equatable {
    case quiet(PressureAlertSuppression)
    case fire(PressureAlertTrigger)
}

/// Every number the alert policy turns on, in one place, with the reason
/// it has the value it has. ANDed, never ORed.
struct PressureEdgeThresholds: Equatable {

    /// Continuous seconds at level >= 2 before a warning alert.
    ///
    /// 45 s. Measured: a natural ramp took ~10 s to go from 60 % free to
    /// level 2, and level 2 bounced back to 1 within seconds several
    /// times. 45 s is comfortably longer than every transient bounce
    /// observed and still leaves lead time — the machine held level 2 for
    /// 63 s under a hog without anything being killed, so 45 s sits inside
    /// the "things are bad but nothing has happened yet" band, which is
    /// exactly where a warning belongs.
    var warningDwell: TimeInterval = 45

    /// Continuous seconds at level == 4 before a critical alert. Measured
    /// as its own clock, NOT derived from the episode age, so a single
    /// level-4 blip inside a long level-2 episode cannot short-circuit the
    /// dwell.
    ///
    /// 5 s. Measured: the level bounced 2 -> 4 -> 2 inside one second, so
    /// zero is wrong; an aggressive allocator also went 1 -> 4 in 1.2 s,
    /// so a 1 Hz poller has no hope of catching THAT one early and a long
    /// dwell buys nothing. 5 samples reject the bounce and still arrive as
    /// a warning rather than an obituary.
    var criticalDwell: TimeInterval = 5

    /// Continuous seconds at level 1 before the episode is considered
    /// over. FALLING-EDGE HYSTERESIS: without it, one level-1 sample in
    /// the middle of a bad stretch resets the 45 s clock, and on a flappy
    /// machine the alert then never fires at all.
    var dropDebounce: TimeInterval = 10

    /// Continuous seconds at level 1 required after an alert before the
    /// detector will consider firing again. Coming back to normal for two
    /// full minutes is the evidence that the previous episode really ended.
    var rearmNormalDwell: TimeInterval = 120

    /// Minimum seconds between two alerts, whatever the level does.
    var cooldown: TimeInterval = 1800

    /// No alerts in the first minute. Login, app launch and Spotlight
    /// indexing all spike memory and the user did not do anything to
    /// cause it.
    var startupGrace: TimeInterval = 60

    /// Hard ceiling on alerts in a rolling `dailyWindow`. With `cooldown`
    /// at 30 min the theoretical maximum is 48/day; this is the backstop
    /// that makes that impossible. Three is the point at which a
    /// notification stops being information and starts being noise — the
    /// one threshold here that is a judgement rather than a measurement.
    var dailyCap: Int = 3
    var dailyWindow: TimeInterval = 86_400

    /// Allow exactly ONE upgrade from a warning alert to a critical alert
    /// inside the same episode, bypassing the cooldown. Warning ->
    /// critical is a genuinely new fact and the user's decision changes.
    /// Permitted once per episode, and it never downgrades.
    var allowCriticalEscalation = true
}

/// Pure. No sysctl, no clock of its own, no notifications, no I/O at all:
/// levels and monotonic timestamps in, decisions out. That is what makes
/// the policy testable against a six-hour synthetic sequence in
/// microseconds instead of against a real machine over six hours.
///
/// THREADING: not thread safe and does not need to be — owned by
/// `PressureAlertEngine`, touched only on the main thread.
final class PressureEdgeDetector {

    var thresholds = PressureEdgeThresholds()

    // ---- episode tracking ----
    /// Monotonic seconds at which the current elevated (level >= 2)
    /// episode began. nil when no episode is open.
    private var elevatedSince: TimeInterval?
    /// Monotonic seconds at which the current continuous level-4 run
    /// began. Reset the instant the level is not 4.
    private var criticalSince: TimeInterval?
    /// Monotonic seconds at which the current continuous level-1 run began.
    private var normalSince: TimeInterval?
    /// Highest level seen in the open episode.
    private var peakLevel: MemoryPressureLevel?
    /// Severity we have already alerted at for the open episode.
    private var alertedSeverityThisEpisode: PressureAlertSeverity?

    // ---- fire bookkeeping ----
    private var firstStepAt: TimeInterval?
    private var lastFireAt: TimeInterval?
    private var snoozedUntil: TimeInterval?
    private var armed = true
    private var fireTimestamps: [TimeInterval] = []

    /// Consecutive unmeasured (`nil` level) samples are tolerated for this
    /// long before the episode clock is thrown away. A dwell that spans a
    /// hole in the data is not a measured dwell.
    private var unmeasuredSince: TimeInterval?

    // MARK: Two-phase API
    //
    // `evaluate` decides and advances the EPISODE clocks, but deliberately
    // does NOT record that an alert happened. The caller calls
    // `confirmFired` only once the notification has actually been handed
    // to the system. THE REASON: an alert that could not be delivered —
    // notifications not yet permitted, or no quittable app to name — must
    // not burn the 30-minute cooldown, or a user who grants permission at
    // 10:00 silently gets nothing until 10:30. If the caller never
    // confirms, `evaluate` keeps returning `.fire`, which is correct: it
    // keeps trying to tell the user until it can.

    /// Advance the detector by one sample. `level` is
    /// `MemoryMetrics.pressureLevel` straight out of the snapshot; nil
    /// means the sysctl failed and is never treated as normal. `now` is
    /// monotonic seconds, never wall clock.
    @discardableResult
    func evaluate(level: MemoryPressureLevel?, now: TimeInterval) -> PressureEdgeOutcome {
        if firstStepAt == nil { firstStepAt = now }

        // ---- unmeasured ----
        guard let level else {
            if unmeasuredSince == nil { unmeasuredSince = now }
            if now - (unmeasuredSince ?? now) >= thresholds.dropDebounce * 3 {
                resetEpisode()
                return .quiet(.measurementGap)
            }
            return .quiet(.unmeasured)
        }
        unmeasuredSince = nil

        // ---- normal ----
        if level == .normal {
            if normalSince == nil { normalSince = now }
            let normalFor = now - (normalSince ?? now)
            criticalSince = nil

            if elevatedSince != nil {
                // Falling-edge hysteresis: the episode is only over once
                // the level has held at 1 for `dropDebounce`.
                if normalFor >= thresholds.dropDebounce {
                    resetEpisode()
                } else {
                    return .quiet(.episodeSettling(normalFor: normalFor))
                }
            }

            if !armed {
                if normalFor >= thresholds.rearmNormalDwell {
                    armed = true
                } else {
                    return .quiet(.rearming(remaining: thresholds.rearmNormalDwell - normalFor))
                }
            }
            return .quiet(.normal)
        }

        // ---- elevated (level 2 or 4) ----
        normalSince = nil
        if elevatedSince == nil {
            elevatedSince = now
            peakLevel = level
            alertedSeverityThisEpisode = nil
        }
        if let p = peakLevel, level.rawValue > p.rawValue { peakLevel = level }
        if peakLevel == nil { peakLevel = level }

        if level == .critical {
            if criticalSince == nil { criticalSince = now }
        } else {
            criticalSince = nil
        }

        let elevatedFor = now - (elevatedSince ?? now)
        let criticalFor = criticalSince.map { now - $0 }

        // Which severity, if any, has met its dwell?
        let criticalReady = (criticalFor ?? -1) >= thresholds.criticalDwell
        let warningReady = elevatedFor >= thresholds.warningDwell
        guard criticalReady || warningReady else {
            // Report the dwell the caller is actually waiting on.
            if level == .critical, let c = criticalFor, !warningReady {
                return .quiet(.dwellTooShort(elapsed: c, needed: thresholds.criticalDwell))
            }
            return .quiet(.dwellTooShort(elapsed: elevatedFor, needed: thresholds.warningDwell))
        }
        let severity: PressureAlertSeverity = criticalReady ? .critical : .warning

        // ---- gates ----
        if let first = firstStepAt, now - first < thresholds.startupGrace {
            return .quiet(.startupGrace(remaining: thresholds.startupGrace - (now - first)))
        }

        var isEscalation = false
        if let already = alertedSeverityThisEpisode {
            let upgrading = thresholds.allowCriticalEscalation
                && severity == .critical && already == .warning
            guard upgrading else { return .quiet(.alreadyAlertedThisEpisode) }
            // An escalation deliberately ignores `armed` and `cooldown`:
            // the level got worse inside an episode the user already knows
            // about, and that is new information. It still respects the
            // snooze (the user said not now) and the daily cap.
            isEscalation = true
        } else {
            guard armed else { return .quiet(.notRearmed) }
            if let last = lastFireAt, now - last < thresholds.cooldown {
                return .quiet(.cooldown(remaining: thresholds.cooldown - (now - last)))
            }
        }

        if let until = snoozedUntil, now < until {
            return .quiet(.snoozed(remaining: until - now))
        }

        fireTimestamps.removeAll { now - $0 >= thresholds.dailyWindow }
        if fireTimestamps.count >= thresholds.dailyCap {
            return .quiet(.dailyCapReached(cap: thresholds.dailyCap))
        }

        return .fire(PressureAlertTrigger(
            severity: severity,
            level: level,
            peakLevel: peakLevel ?? level,
            elevatedFor: elevatedFor,
            criticalFor: criticalFor,
            isEscalation: isEscalation
        ))
    }

    /// Record that the alert `evaluate` asked for was actually delivered.
    /// THIS is what starts the cooldown and disarms the detector.
    func confirmFired(_ trigger: PressureAlertTrigger, at now: TimeInterval) {
        lastFireAt = now
        fireTimestamps.append(now)
        armed = false
        alertedSeverityThisEpisode = trigger.severity
    }

    /// The user pressed «Не сейчас». Suppresses alerts without touching
    /// the episode clocks.
    func snooze(for seconds: TimeInterval, at now: TimeInterval) {
        snoozedUntil = max(snoozedUntil ?? now, now + seconds)
    }

    /// Tell the detector the sample stream had a hole — the feature was
    /// muted and unmuted, the machine slept, a tick was missed. The open
    /// episode's dwell is no longer a measured dwell, so it is discarded.
    /// Deliberately does NOT clear the cooldown or the daily cap: those
    /// are about how often the USER is interrupted, and a gap in our
    /// sampling is not a reason to interrupt them again.
    func noteMeasurementGap() {
        resetEpisode()
        unmeasuredSince = nil
        // Re-serve the startup grace: the first samples after a wake look
        // exactly like the first samples after login.
        firstStepAt = nil
    }

    private func resetEpisode() {
        elevatedSince = nil
        criticalSince = nil
        peakLevel = nil
        alertedSeverityThisEpisode = nil
    }
}


// =====================================================================
// MARK: - 3. Authorization state
// =====================================================================

/// Where we stand with UNUserNotificationCenter.
///
/// THE macOS 26 TRAP THIS TYPE EXISTS FOR, verified on this machine: the
/// permission prompt is a BANNER, not a modal, with Разрешить/Не разрешать
/// hidden behind a hover-only «Параметры» chevron. Ignored until it times
/// out, the status becomes `.denied` — and from then on `add()` returns
/// `err == nil` and `getDeliveredNotifications` dutifully counts 1, 2, 3
/// while NOTHING is ever drawn on screen. `add()` lies. The only reliable
/// gate is `getNotificationSettings().authorizationStatus`, re-read
/// immediately before every post, which is what the engine does.
enum PressureAlertAuthorization: Equatable {
    /// The OS says `.notDetermined` and we have not asked. We only ask
    /// when there is finally something to say — see `attemptDelivery`.
    case notRequested
    /// Prompt is on screen. Never ask again while in this state.
    case requesting
    /// Authorized AND banners are on. Posts will be seen.
    case authorized
    /// Authorized, but the user turned banners off for MacPulse. Posts
    /// land silently in Notification Centre. Honest, but the panel says
    /// so rather than pretending the user was warned.
    case authorizedSilently
    /// The user said no, or let the macOS 26 banner time out. Recovery is
    /// System Settings only — `requestAuthorization` returns
    /// `UNErrorDomain Code=1` forever after this. NEVER re-prompt.
    case denied
    /// Not a user decision: the bundle is not registered with
    /// LaunchServices, so the OS refuses before any prompt is shown.
    /// MEASURED: running the Mach-O straight out of a Build/ directory
    /// LaunchServices has never seen gives an instant `Code=1` with no
    /// prompt. That looks exactly like a code bug and is not one. The fix
    /// is build.sh's existing copy to /Applications, not a retry.
    case unavailable(reason: String)

    var canPost: Bool {
        switch self {
        case .authorized, .authorizedSilently: return true
        default: return false
        }
    }

    /// True for the two states nothing we do can change. Asking again is a
    /// nag loop; the recovery is System Settings or a reinstall.
    var isFinal: Bool {
        switch self {
        case .denied, .unavailable: return true
        default: return false
        }
    }

    /// One short line for the panel.
    var panelLine: String {
        switch self {
        case .notRequested:       return "Разрешение спросим, когда будет о чём предупредить"
        case .requesting:         return "Запрашиваем разрешение…"
        case .authorized:         return "Уведомления включены"
        case .authorizedSilently: return "Уведомления без баннера — только в Центре уведомлений"
        case .denied:             return "Уведомления запрещены — включите в Настройках"
        case .unavailable:        return "Уведомления недоступны для этой сборки"
        }
    }
}


// =====================================================================
// MARK: - 4. The quit path
// =====================================================================

/// The app whose name goes in the alert, and the fingerprint that proves
/// the button still points at it when it is finally pressed.
struct PressureAlertCulprit: Equatable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let footprintBytes: UInt64
    /// `rusage_info_v4.ri_proc_start_abstime` at the moment the alert was
    /// composed.
    ///
    /// THE BUG THIS CLOSES: a notification can sit in Notification Centre
    /// for hours. PIDs are recycled. Without a fingerprint, pressing
    /// «Завершить Cursor» tomorrow could terminate whatever inherited that
    /// pid — possibly with unsaved work in it. The start time is unique
    /// per process and free to read, so the action re-reads it and refuses
    /// if it moved. nil when it could not be read, and a nil fingerprint
    /// is treated as a failed match, not as a pass.
    let startAbsoluteTime: UInt64?
}

/// The ONLY way this engine can cause an app to quit.
///
/// A protocol rather than a call to `NSRunningApplication.terminate()`,
/// deliberately: `IslandModel` already owns the guarded quit path —
/// graceful `terminate()` first, `forceTerminate()` only as an explicit
/// SECOND click after the graceful attempt has demonstrably failed, never
/// on a timer, only ever the one app whose button was pressed. A second
/// quit implementation living in a notification delegate would be a second
/// place for that contract to rot. So the engine hands the pid over and
/// stops. The conformance is at the bottom of this file and is four lines.
///
/// NOTE what is NOT here: no force-quit entry point. A notification button
/// must never escalate to `forceTerminate()` by itself.
protocol PressureAlertActionHandler: AnyObject {
    /// Called on the MAIN thread after the pid has been re-validated.
    func pressureAlertDidRequestQuit(pid: pid_t, name: String)
}


// =====================================================================
// MARK: - 5. What the panel draws
// =====================================================================

/// One row of the section's history, already formatted — same rule as
/// `AppRowState`: two ticks that would draw the same pixels compare equal,
/// so nothing republishes.
struct PressureAlertEntry: Equatable, Identifiable {
    let id: String
    /// "14:32", local time.
    let time: String
    let severity: PressureAlertSeverity
    let appName: String
    /// Already formatted, Russian units.
    let footprint: String
    /// What actually happened to this alert. Never claim the user was
    /// warned when the banner was swallowed.
    let delivery: Delivery

    enum Delivery: Equatable {
        /// Posted with banners on: the user saw it.
        case shown
        /// Posted, but banners are off for MacPulse — it is in Notification
        /// Centre and nowhere else.
        case silent
        /// Not posted at all, and why.
        case blocked(String)
    }
}

/// Everything the pressure fold at the bottom of «Память» draws, as
/// drawn. Published from `IslandModel`, which is the only object the
/// island's views observe.
///
/// It fed a «Давление» TAB until that tab was folded into «Память» — the
/// two were one subject in two chips. Nothing in this struct changed in
/// the move; `isQuiet` still decides whether the notifier is on screen at
/// all, it just gates 45 pt at the bottom of another section now instead
/// of a chip in the rail. See IslandPressureFold.swift.
struct PressureAlertState: Equatable {
    /// The user's switch, persisted. Muted is a deliberate choice and is
    /// therefore state worth a chip: it is the only way back.
    var isMuted = false
    var authorization: PressureAlertAuthorization = .notRequested
    /// Newest first, at most `PressureAlertBridge.historyLimit`, pruned
    /// after 24 h so a quiet machine goes back to having no chip at all.
    var history: [PressureAlertEntry] = []
    /// Alerts delivered in the rolling 24 h window, against the cap.
    var deliveredToday = 0
    var dailyCap = PressureEdgeThresholds().dailyCap
    /// What the sustained-pressure sysctls actually said, last time we
    /// looked. Empty when the oids are absent — we say nothing rather than
    /// guess.
    var killerLine = ""
    /// Why the user is not being bothered right now. Written ONLY while
    /// the panel is open; see the publishing rule at the top of
    /// IslandModel.
    var liveLine = ""

    /// The router's `hasState`. Nothing happened and nothing was switched
    /// off: no chip. This is the state of a quiet machine and it is the
    /// common case.
    var isQuiet: Bool { history.isEmpty && !isMuted }
}


// =====================================================================
// MARK: - 6. Events
// =====================================================================

enum PressureAlertEvent {
    case authorizationChanged(PressureAlertAuthorization)
    case suppressed(PressureAlertSuppression)
    /// The detector said fire but the engine could not deliver. The
    /// cooldown was NOT consumed.
    case couldNotDeliver(reason: String, trigger: PressureAlertTrigger)
    case posted(severity: PressureAlertSeverity,
                culprit: PressureAlertCulprit,
                identifier: String,
                bannerExpected: Bool)
    case quitRequested(pid: pid_t, name: String)
    /// The button was pressed but the pid no longer refers to the app the
    /// alert named. Nothing was terminated.
    case quitRefused(reason: String)
    case snoozed(seconds: TimeInterval)
}


// =====================================================================
// MARK: - 7. The engine
// =====================================================================

final class PressureAlertEngine: NSObject, UNUserNotificationCenterDelegate {

    static let shared = PressureAlertEngine()

    // MARK: Wiring

    /// The only object allowed to terminate anything. Weak: the engine
    /// must never keep the island alive.
    weak var actionHandler: PressureAlertActionHandler?

    /// Fires on the MAIN thread for everything the engine does. The bridge
    /// is the only listener; nothing here requires one.
    var onEvent: ((PressureAlertEvent) -> Void)?

    let detector = PressureEdgeDetector()

    // MARK: State

    private(set) var isActive = false
    private(set) var isMuted = false
    private(set) var authorization: PressureAlertAuthorization = .notRequested {
        didSet {
            guard authorization != oldValue else { return }
            // A trip to System Settings is the one thing that can undo a
            // final answer, so a new answer re-arms the one-shot report
            // below.
            reportedFinalBlock = nil
            emit(.authorizationChanged(authorization))
        }
    }
    /// The authorization value we have already told the panel we are
    /// blocked by. ONE report per answer: `attemptDelivery` is reached on
    /// every tick of a sustained episode, and a `.denied` user would
    /// otherwise collect a history row per second.
    private var reportedFinalBlock: PressureAlertAuthorization?
    /// Refreshed at activation, on the panel's open edge, and whenever an
    /// alert is composed. Never on a tick.
    private(set) var killer = SustainedPressureKiller(killCount: nil, windowSeconds: nil)

    /// nil when this process has no app bundle.
    ///
    /// THE CRASH THIS AVOIDS, reproduced: `UNUserNotificationCenter.current()`
    /// does not return nil or throw for a bundle-less process — it raises
    /// `NSInternalInconsistencyException: bundleProxyForCurrentProcess is
    /// nil`, which Swift cannot catch, and the process dies inside a
    /// `dispatch_once`. Touching `PressureAlertEngine.shared` was therefore
    /// enough to kill a plain command-line build, and `Probe.swift` is
    /// exactly such a build. So the center is resolved lazily behind a
    /// bundle check and the feature reports itself unavailable instead,
    /// per the project rule that a missing capability degrades rather than
    /// crashes.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    private let epoch = Mono.now()
    private var now: TimeInterval { Mono.seconds(since: epoch) }

    /// Wall-clock date of the previous snapshot, to spot sample-stream
    /// holes (sleep/wake) the monotonic clock cannot see: on Apple silicon
    /// `DispatchTime.uptimeNanoseconds` does not advance while the machine
    /// is asleep, so an 8-hour sleep looks like no time passing.
    private var lastSnapshotDate: Date?

    /// The engine retries a blocked post at most this often, so a stuck
    /// delivery does not cost a `getNotificationSettings` call every tick.
    private var lastDeliveryAttempt: TimeInterval?
    private let deliveryRetryInterval: TimeInterval = 10

    /// Lifetime prompt budget, persisted. `requestAuthorization` is called
    /// at most twice EVER: once the first time the feature genuinely has
    /// something to say, and once more in some later launch if the OS
    /// still says `.notDetermined`. After that the answer is "ask in
    /// System Settings". This makes "never re-prompt in a loop"
    /// structural rather than hoped for.
    private static let promptCountKey = "MacPulse.pressureAlert.authPromptCount"
    private static let maxLifetimePrompts = 2
    private var promptedThisProcess = false

    /// How long a posted alert's button stays valid. A banner that has sat
    /// in Notification Centre overnight points at a machine state that no
    /// longer exists.
    private let actionValidity: TimeInterval = 15 * 60
    /// Seconds «Не сейчас» suppresses alerts for.
    let snoozeDuration: TimeInterval = 2 * 60 * 60

    private static let categoryIdentifier = "MACPULSE_MEMORY_PRESSURE"
    private static let quitActionIdentifier = "MACPULSE_QUIT_CULPRIT"
    private static let snoozeActionIdentifier = "MACPULSE_SNOOZE"

    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Start watching. MAIN THREAD, once, from `PressureAlertBridge`.
    ///
    /// THIS NEVER PROMPTS. It registers the category, installs the
    /// delegate (so a button pressed on a banner left over from a previous
    /// launch still reaches us) and reads the OS's current answer. The
    /// prompt happens in `attemptDelivery`, at the one moment the feature
    /// has actually earned it.
    func activate() {
        precondition(Thread.isMainThread, "PressureAlertEngine.activate() is main-thread only")
        guard !isActive else { return }
        guard let center else {
            // No app bundle: a CLI build, or Probe.swift. Notifications
            // are structurally impossible here; say so once and stop.
            authorization = .unavailable(reason: "процесс запущен без bundle")
            return
        }
        isActive = true
        center.delegate = self
        registerCategory(culpritName: nil)
        killer = SustainedPressureKiller.read()
        refreshAuthorizationStatus()
    }

    /// The user's switch. Muting does not revoke anything with the OS —
    /// there is no API for that and pretending otherwise would be a lie in
    /// the UI. It stops evaluating and stops posting, and that is all.
    func setMuted(_ muted: Bool) {
        precondition(Thread.isMainThread)
        guard isMuted != muted else { return }
        isMuted = muted
        // Coming back from a mute is a hole in the sample stream: the
        // dwell we would otherwise claim was never measured.
        if !muted {
            detector.noteMeasurementGap()
            lastSnapshotDate = nil
        }
    }

    /// Re-read the OS's answer without ever prompting. Cheap enough to
    /// call when the panel opens, so the section notices the user flipping
    /// the switch in System Settings.
    func refreshAuthorizationStatus() {
        precondition(Thread.isMainThread)
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.adoptSettings(settings) }
        }
    }

    /// Re-read the three sustained-pressure oids. ~4 us. Called on the
    /// panel's open edge and when an alert is composed — never on a tick.
    func refreshKillerReading() {
        precondition(Thread.isMainThread)
        killer = SustainedPressureKiller.read()
    }

    // MARK: - The tick

    /// Feed one snapshot. MAIN THREAD — this is where `MetricsEngine`
    /// delivers. Costs a handful of comparisons: it reads no sysctl and
    /// walks no process list, because the pressure level and the per-app
    /// footprints are already in the snapshot.
    func ingest(_ snapshot: MetricsSnapshot) {
        guard isActive, !isMuted else { return }

        // Sleep/wake and stalled-tick detection. `snapshot.interval` is
        // monotonic and therefore also blind to sleep, so compare wall
        // clocks instead.
        if let previous = lastSnapshotDate {
            let wallGap = snapshot.date.timeIntervalSince(previous)
            if wallGap > 30 || wallGap < -5 {
                detector.noteMeasurementGap()
                lastSnapshotDate = snapshot.date
                emit(.suppressed(.measurementGap))
                return
            }
        }
        lastSnapshotDate = snapshot.date

        let t = now
        // THE CONSUMED VALUE. Not a fresh sysctl — MemorySampler already
        // read `kern.memorystatus_vm_pressure_level` for this tick.
        switch detector.evaluate(level: snapshot.memory?.pressureLevel, now: t) {
        case .quiet(let reason):
            emit(.suppressed(reason))
        case .fire(let trigger):
            attemptDelivery(trigger: trigger, snapshot: snapshot, at: t)
        }
    }

    // MARK: - Delivery

    private func attemptDelivery(trigger: PressureAlertTrigger,
                                 snapshot: MetricsSnapshot,
                                 at t: TimeInterval) {
        // A final answer is final. Retrying a `.denied` user forever would
        // cost an XPC round trip every ten seconds and change nothing.
        // `refreshAuthorizationStatus()` on the panel's open edge is what
        // lets them out of here after a trip to System Settings.
        guard !authorization.isFinal else {
            if reportedFinalBlock != authorization {
                reportedFinalBlock = authorization
                emit(.couldNotDeliver(reason: authorization.panelLine, trigger: trigger))
            }
            return
        }
        if let last = lastDeliveryAttempt, t - last < deliveryRetryInterval { return }
        lastDeliveryAttempt = t

        // An alert with no name and no button is anxiety, not information:
        // it tells the user something is wrong and gives them nothing to do
        // about it. Suppression for this reason deliberately does NOT
        // confirm the fire, so the cooldown is untouched and the next tick
        // with a readable process list alerts.
        guard let culprit = Self.culprit(in: snapshot) else {
            emit(.couldNotDeliver(reason: "нет приложения, которое можно назвать и завершить",
                                  trigger: trigger))
            return
        }

        killer = SustainedPressureKiller.read()
        let copy = PressureAlertCopy.compose(trigger: trigger,
                                             culprit: culprit,
                                             memory: snapshot.memory,
                                             killer: killer)

        // THE GATE. Never `add()` first and inspect the error: MEASURED,
        // `add()` returns err == nil and the delivered-notification count
        // climbs while the banner is silently swallowed, whenever the user
        // let the macOS 26 permission banner time out. The settings object
        // is the only thing that tells the truth.
        guard let center else {
            emit(.couldNotDeliver(reason: authorization.panelLine, trigger: trigger))
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, self.isActive, !self.isMuted else { return }
                self.adoptSettings(settings)

                // THE LAZY PROMPT, and the only place in MacPulse that asks
                // the user for anything. Not at launch and not from a
                // switch the user has to find: at the exact moment the app
                // has something worth saying. If they allow, the two-phase
                // detector still has the alert pending and the next tick
                // posts it; if they refuse, `authorization` becomes final
                // and we never ask again.
                if settings.authorizationStatus == .notDetermined {
                    self.requestOnce()
                    self.emit(.couldNotDeliver(reason: "спрашиваем разрешение", trigger: trigger))
                    return
                }
                guard self.authorization.canPost else {
                    self.emit(.couldNotDeliver(reason: self.authorization.panelLine, trigger: trigger))
                    return
                }
                self.post(trigger: trigger, culprit: culprit, copy: copy,
                          bannerExpected: settings.alertSetting == .enabled)
            }
        }
    }

    private func post(trigger: PressureAlertTrigger,
                      culprit: PressureAlertCulprit,
                      copy: (title: String, body: String),
                      bannerExpected: Bool) {
        // The action title names THIS app, so the category is
        // re-registered per alert. Categories are global and MacPulse owns
        // exactly one, so replacing the set is safe — but if a second
        // notification feature is ever added, both must come through one
        // registration point or they will stomp each other.
        registerCategory(culpritName: culprit.name)

        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = trigger.severity == .critical ? .default : nil
        content.interruptionLevel = trigger.severity == .critical ? .timeSensitive : .active
        content.threadIdentifier = "macpulse.memory.pressure"
        content.userInfo = [
            "pid": Int(culprit.pid),
            "name": culprit.name,
            "bundle": culprit.bundleIdentifier ?? "",
            // UInt64 is not plist-legal; a decimal string round-trips exactly.
            "startAbs": culprit.startAbsoluteTime.map(String.init) ?? "",
            "postedAt": Date().timeIntervalSinceReferenceDate,
            "severity": trigger.severity.rawValue
        ]

        let identifier = "macpulse.pressure.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        // `setNotificationCategories` is not synchronous with respect to
        // the notification service. One main-queue hop is enough for the
        // freshly-named action to be the one the banner shows. This is a
        // deferred block, not a sleep, and it is on main — nothing blocks.
        DispatchQueue.main.async { [weak self] in
            guard let self, let center = self.center else { return }
            center.add(request) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        // add() failing is rare and real. It does NOT fail
                        // for the denied case — that is the trap above.
                        self.emit(.couldNotDeliver(reason: String(describing: error),
                                                   trigger: trigger))
                        return
                    }
                    // ONLY NOW is the cooldown consumed.
                    self.detector.confirmFired(trigger, at: self.now)
                    self.emit(.posted(severity: trigger.severity,
                                      culprit: culprit,
                                      identifier: identifier,
                                      bannerExpected: bannerExpected))
                }
            }
        }
    }

    private func registerCategory(culpritName: String?) {
        // NO `.foreground`. MacPulse is an accessory app that otherwise
        // never activates, and MEASURED: the response still reaches
        // `didReceive` on the main thread without it. Making the island
        // jump to the front to answer a button press the user made
        // somewhere else is not worth it.
        let quitTitle = culpritName.map { "Завершить \($0)" } ?? "Завершить приложение"
        let quit = UNNotificationAction(identifier: Self.quitActionIdentifier,
                                        title: quitTitle,
                                        options: [.destructive])
        let snooze = UNNotificationAction(identifier: Self.snoozeActionIdentifier,
                                          title: "Не сейчас",
                                          options: [])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier,
                                              actions: [quit, snooze],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        center?.setNotificationCategories([category])
    }

    // MARK: - Authorization state machine

    /// The prompt. Called from `attemptDelivery` and nowhere else.
    private func requestOnce() {
        guard let center else { return }
        guard !promptedThisProcess else { return }
        let defaults = UserDefaults.standard
        let spent = defaults.integer(forKey: Self.promptCountKey)
        guard spent < Self.maxLifetimePrompts else {
            // Budget gone. On macOS 26 a prompt the user ignored leaves the
            // status at .denied and every further request returns Code=1
            // instantly and silently, so asking again is pure loop.
            authorization = .denied
            return
        }
        promptedThisProcess = true
        defaults.set(spent + 1, forKey: Self.promptCountKey)
        authorization = .requesting

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error as NSError?,
                   error.domain == UNErrorDomain, error.code == 1 {
                    // "Notifications are not allowed for this application".
                    // MEASURED, and this is the subtle part: Code=1 has TWO
                    // completely different causes and the same text.
                    //   * the bundle is not registered with LaunchServices
                    //     (running the Mach-O straight out of Build/) — no
                    //     prompt was ever shown, and the fix is build.sh's
                    //     copy to /Applications;
                    //   * the user has already refused — including by
                    //     letting the macOS 26 banner time out, which was
                    //     reproduced here twice, ~11 s after the prompt
                    //     appeared.
                    // Telling them apart matters because the recoveries are
                    // opposite, and only the OS's own status can: ask it
                    // rather than guessing from the error code.
                    self.resolveCodeOneCause()
                    return
                }
                _ = granted     // deliberately unused: `granted` is not the gate.
                // Ask the OS what it actually thinks, rather than trusting
                // the callback's boolean.
                self.refreshAuthorizationStatus()
            }
        }
    }

    /// `requestAuthorization` answered `UNErrorDomain Code=1`. Ask the OS
    /// which of its two causes this is: a real refusal, or a bundle the OS
    /// will not talk to at all.
    private func resolveCodeOneCause() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .denied {
                    self.authorization = .denied
                } else {
                    self.authorization = .unavailable(
                        reason: "bundle не зарегистрирован в LaunchServices (UNErrorDomain 1)")
                }
            }
        }
    }

    private func adoptSettings(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorization = settings.alertSetting == .enabled ? .authorized : .authorizedSilently
        case .denied:
            authorization = .denied
        case .notDetermined:
            // Keep `.requesting` while a prompt is on screen; otherwise we
            // simply have not asked.
            if authorization != .requesting { authorization = .notRequested }
        default:
            authorization = .notRequested
        }
    }

    /// Open the Notifications pane so a `.denied` user has somewhere to go.
    /// A `x-apple.systempreferences:` URL — a local URL scheme handled by
    /// System Settings. No network is involved and none is linked.
    func openNotificationSettings() {
        precondition(Thread.isMainThread)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Only reached when MacPulse happens to be frontmost. It is an
        // accessory app, so this is rare, but without this method the
        // default behaviour is to swallow the banner entirely.
        guard notification.request.content.categoryIdentifier == Self.categoryIdentifier else {
            handler([])
            return
        }
        handler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        guard content.categoryIdentifier == Self.categoryIdentifier else { handler(); return }

        DispatchQueue.main.async { [weak self] in
            defer { handler() }
            guard let self else { return }
            switch action {
            case Self.quitActionIdentifier:
                self.handleQuitAction(userInfo: content.userInfo)
            case Self.snoozeActionIdentifier:
                self.detector.snooze(for: self.snoozeDuration, at: self.now)
                self.emit(.snoozed(seconds: self.snoozeDuration))
            default:
                break   // opened, or dismissed
            }
        }
    }

    /// The answer to "does this button still point at the app it named?".
    enum QuitTarget: Equatable {
        case ok(pid: pid_t, name: String)
        case refused(String)
    }

    /// Pure-ish validation, split out from dispatch so it can be exercised
    /// directly. Reads `NSRunningApplication` and one `proc_pid_rusage`;
    /// terminates nothing.
    ///
    /// FAIL CLOSED is the rule. Anything we cannot confirm — an unreadable
    /// start time, a bundle id that moved, a notification older than
    /// `actionValidity` — refuses. The cost of a false refusal is one
    /// unhelpful button press; the cost of a false accept is terminating
    /// the wrong process, possibly with unsaved work in it.
    func validateQuitTarget(userInfo: [AnyHashable: Any], now: Date = Date()) -> QuitTarget {
        guard let rawPID = userInfo["pid"] as? Int else {
            return .refused("в уведомлении нет pid")
        }
        let pid = pid_t(rawPID)
        let name = (userInfo["name"] as? String) ?? "pid \(pid)"

        if let postedAt = userInfo["postedAt"] as? TimeInterval {
            let age = now.timeIntervalSinceReferenceDate - postedAt
            guard age <= actionValidity else {
                return .refused("уведомление устарело (\(Int(age)) с)")
            }
        }

        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            return .refused("\(name) уже не запущено")
        }

        // PID-reuse guard, two independent checks. Both must pass.
        let recordedBundle = (userInfo["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let recordedBundle {
            guard running.bundleIdentifier == recordedBundle else {
                return .refused("pid \(pid) теперь занят другим приложением")
            }
        }
        let recordedStart = (userInfo["startAbs"] as? String).flatMap(UInt64.init)
        if let recordedStart {
            guard let liveStart = Self.processStartAbsoluteTime(pid), liveStart == recordedStart else {
                return .refused("pid \(pid) переиспользован другим процессом")
            }
        }
        return .ok(pid: pid, name: name)
    }

    /// Re-validate, then hand the pid to whoever owns the guarded quit
    /// path. This method never calls `terminate()` or `forceTerminate()`.
    private func handleQuitAction(userInfo: [AnyHashable: Any]) {
        switch validateQuitTarget(userInfo: userInfo) {
        case .refused(let why):
            emit(.quitRefused(reason: why))
        case .ok(let pid, let name):
            guard let handler = actionHandler else {
                // No fallback, on purpose. If nobody wired the guarded quit
                // path, nothing gets terminated — this engine does not own
                // a second one and must not be given one.
                emit(.quitRefused(reason: "нет обработчика завершения"))
                return
            }
            emit(.quitRequested(pid: pid, name: name))
            handler.pressureAlertDidRequestQuit(pid: pid, name: name)
        }
    }

    // MARK: - Helpers

    /// The largest QUITTABLE app. `ProcessMetrics.apps` is already sorted
    /// by `footprintBytes` descending with helpers folded into their
    /// responsible app, so this is a `first(where:)`.
    ///
    /// WHY `isApplication` AND NOT SIMPLY `apps.first`: the biggest row can
    /// be something that is not an `NSRunningApplication` at all (a daemon,
    /// a helper whose responsible pid could not be resolved). Naming it
    /// would be useless and offering to quit it would break the island's
    /// rule that nothing which is not a real running application is ever
    /// touched.
    static func culprit(in snapshot: MetricsSnapshot) -> PressureAlertCulprit? {
        guard let apps = snapshot.processes?.apps else { return nil }
        guard let top = apps.first(where: { $0.isApplication && $0.footprintBytes > 0 }) else { return nil }
        return PressureAlertCulprit(
            pid: top.pid,
            name: top.name,
            bundleIdentifier: NSRunningApplication(processIdentifier: top.pid)?.bundleIdentifier
                ?? top.bundleIdentifier,
            footprintBytes: top.footprintBytes,
            startAbsoluteTime: processStartAbsoluteTime(top.pid)
        )
    }

    /// `ri_proc_start_abstime` — mach absolute time at which this pid's
    /// process started. Unique per process, so it is the fingerprint that
    /// survives pid reuse. nil for pids we cannot introspect (another uid).
    static func processStartAbsoluteTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0, info.ri_proc_start_abstime != 0 else { return nil }
        return info.ri_proc_start_abstime
    }

    private func emit(_ event: PressureAlertEvent) { onEvent?(event) }
}


// =====================================================================
// MARK: - 8. The words
// =====================================================================

/// Alert copy, built ONLY from values we actually measured this tick.
///
/// THE RULE THIS TYPE ENFORCES, and the reason the copy is not inline:
/// nothing here may claim macOS is about to kill anything. On this machine
/// `kern.memorystatus.kill_on_sustained_pressure_count` is 0 and stayed 0
/// through 63 s of sustained warning pressure, two critical excursions and
/// ~3.8 GB of incompressible allocation. The sustained-pressure killer is
/// dormant here. «macOS вот-вот завершит ваши приложения» would therefore
/// be a lie, and a lie the user can check with one sysctl. What IS true,
/// and what the copy says, is: memory is under pressure, this app is the
/// biggest, and here is what the kill counter actually reads.
enum PressureAlertCopy {

    static func compose(trigger: PressureAlertTrigger,
                        culprit: PressureAlertCulprit,
                        memory: MemoryMetrics?,
                        killer: SustainedPressureKiller) -> (title: String, body: String) {
        (title(trigger), body(trigger: trigger, culprit: culprit, memory: memory, killer: killer))
    }

    static func title(_ trigger: PressureAlertTrigger) -> String {
        switch trigger.severity {
        case .critical: return "Памяти почти нет"
        case .warning:  return "Память под давлением"
        }
    }

    static func body(trigger: PressureAlertTrigger,
                     culprit: PressureAlertCulprit,
                     memory: MemoryMetrics?,
                     killer: SustainedPressureKiller) -> String {
        var parts: [String] = []

        // 1. The actionable fact, always first — this is the whole point.
        parts.append("Больше всех — \(culprit.name): \(UIFmt.bytes(culprit.footprintBytes)).")

        // 2. ONE corroborating measurement, if we have one. A body longer
        //    than about two lines is truncated in the banner, so this is a
        //    single clause and it is only added when the number is real.
        if let churn = memory?.rates?.compressorChurnBytesPerSec, churn >= 20 * 1024 * 1024 {
            parts.append("Компрессор: \(UIFmt.mbps(churn)).")
        } else if let swap = memory?.swapUsedBytes, swap > 0 {
            parts.append("Своп: \(UIFmt.bytes(swap)).")
        }

        // 3. The truthful jetsam clause.
        let clause = killerClause(killer)
        if !clause.isEmpty { parts.append(clause) }

        return parts.joined(separator: " ")
    }

    /// The only code in MacPulse allowed to talk about macOS killing apps,
    /// and it only does so when the counter says it happened.
    static func killerClause(_ killer: SustainedPressureKiller) -> String {
        switch killer.verdict {
        case .unknown:
            // The oids are not here. Say nothing rather than guess.
            return ""
        case .dormant(let window):
            guard let minutes = minutes(window) else {
                return "macOS пока ничего не завершал."
            }
            return "За \(minutes) мин macOS ничего не завершал."
        case .hasKilled(let count, let window):
            let noun = pluralApps(count)
            guard let minutes = minutes(window) else {
                return "macOS уже завершил \(count) \(noun)."
            }
            return "macOS уже завершил \(count) \(noun) за \(minutes) мин."
        }
    }

    /// The same verdict, for the panel rather than the banner.
    static func killerPanelLine(_ killer: SustainedPressureKiller) -> String {
        switch killer.verdict {
        case .unknown:
            return "Счётчик принудительных завершений macOS недоступен"
        case .dormant(let window):
            guard let minutes = minutes(window) else {
                return "macOS ничего не завершал из-за памяти"
            }
            return "macOS ничего не завершал из-за памяти за последние \(minutes) мин"
        case .hasKilled(let count, let window):
            let noun = pluralApps(count)
            guard let minutes = minutes(window) else {
                return "macOS завершил \(count) \(noun) из-за памяти"
            }
            return "macOS завершил \(count) \(noun) из-за памяти за \(minutes) мин"
        }
    }

    private static func minutes(_ seconds: UInt64?) -> Int? {
        guard let seconds, seconds >= 60 else { return nil }
        return Int(seconds / 60)
    }

    /// 1 приложение / 2–4 приложения / 5+ приложений, with the Slavic
    /// teens exception.
    static func pluralApps(_ n: UInt64) -> String {
        let last2 = n % 100
        let last = n % 10
        if last2 >= 11 && last2 <= 14 { return "приложений" }
        switch last {
        case 1: return "приложение"
        case 2, 3, 4: return "приложения"
        default: return "приложений"
        }
    }

    /// Why the user is not being bothered, in one clause. Built ONLY while
    /// the panel is open — it changes every second during an episode and
    /// publishing it with the panel shut is exactly the churn IslandModel's
    /// header warns about.
    static func suppressionLine(_ reason: PressureAlertSuppression?) -> String {
        guard let reason else { return "Следим за давлением памяти" }
        switch reason {
        case .unmeasured:
            return "Уровень давления не читается — ждём измерения"
        case .measurementGap:
            return "Пропуск в измерениях — отсчёт начат заново"
        case .normal:
            return "Давление в норме"
        case .rearming(let remaining):
            return "Норма \(secs(remaining)) до готовности предупредить снова"
        case .episodeSettling(let normalFor):
            return "Давление спало \(secs(normalFor)) назад — эпизод ещё считается открытым"
        case .startupGrace(let remaining):
            return "Первая минута после запуска — молчим ещё \(secs(remaining))"
        case .dwellTooShort(let elapsed, let needed):
            return "Давление держится \(Int(elapsed)) с из \(Int(needed)) — порог не пройден"
        case .alreadyAlertedThisEpisode:
            return "Об этом эпизоде уже предупредили"
        case .notRearmed:
            return "Ждём, пока давление вернётся к норме на 2 мин"
        case .cooldown(let remaining):
            return "Пауза после предупреждения — ещё \(secs(remaining))"
        case .snoozed(let remaining):
            return "Отложено вами — ещё \(secs(remaining))"
        case .dailyCapReached(let cap):
            return "Достигнут предел \(cap) предупреждения в сутки"
        }
    }

    private static func secs(_ v: TimeInterval) -> String {
        let s = Int(max(v, 0).rounded())
        return s >= 60 ? "\(s / 60) мин" : "\(s) с"
    }
}


// =====================================================================
// MARK: - 9. The bridge into the island
// =====================================================================

/// Owns the engine's lifetime, persists the user's switch, and turns the
/// engine's events into the ONE `@Published` value the router reads.
///
/// WHY THIS IS NOT THE ENGINE ITSELF: the engine emits an event per tick
/// (`.suppressed`), and a `@Published` write per tick is precisely the
/// 0.3 %-of-a-core mistake documented at the top of IslandModel. The
/// bridge is the filter: `.suppressed` is turned into a published string
/// ONLY while the panel is open, and everything else — a posted alert, a
/// changed authorization, a flipped switch — publishes on the real change
/// and never otherwise.
final class PressureAlertBridge {

    /// A singleton for the same reason the engine is one: the section's
    /// switch has to reach it, and threading a reference from
    /// `makeBody` through to a button action would mean another property
    /// on IslandModel for no gain.
    static let shared = PressureAlertBridge()

    /// The section shows a history, not a log.
    static let historyLimit = 4
    /// Rows older than this are dropped, so a machine that had one bad
    /// afternoon goes back to having no chip at all.
    static let historyLifetime: TimeInterval = 86_400

    private static let mutedKey = "MacPulse.pressureAlert.muted"

    private weak var model: IslandModel?
    private var token: MetricsObserverToken?
    private var state = PressureAlertState()
    /// Wall-clock birthdays for `state.history`, parallel by index. Kept
    /// out of `PressureAlertEntry` so that two rows which draw identically
    /// compare equal.
    private var historyDates: [Date] = []
    /// The most recent reason the detector declined to fire. Deliberately
    /// NOT part of `PressureAlertState`: it changes every second during an
    /// episode and only the open panel ever renders it.
    private var lastSuppression: PressureAlertSuppression?
    private var panelWasOpen = false
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private init() {}

    /// MAIN THREAD, once, from `IslandModel.start()`.
    func start(model: IslandModel) {
        precondition(Thread.isMainThread)
        guard token == nil else { return }
        self.model = model
        let engine = PressureAlertEngine.shared
        engine.actionHandler = model
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.activate()
        engine.setMuted(UserDefaults.standard.bool(forKey: Self.mutedKey))

        state.isMuted = engine.isMuted
        state.authorization = engine.authorization
        state.killerLine = PressureAlertCopy.killerPanelLine(engine.killer)
        publish()

        // Its own observer rather than a line in `IslandModel.ingest`:
        // this feature has to keep watching while the panel is shut, and
        // it is the one thing in the app that must not be gated on
        // somebody looking.
        token = MetricsEngine.shared.observe { [weak self] snapshot in
            self?.tick(snapshot)
        }
    }

    func stop() {
        if let token { MetricsEngine.shared.remove(token) }
        token = nil
        PressureAlertEngine.shared.onEvent = nil
    }

    /// The whole per-tick cost of this feature.
    private func tick(_ snapshot: MetricsSnapshot) {
        PressureAlertEngine.shared.ingest(snapshot)

        // Everything below is panel-open work or once-a-day work.
        let isOpen = model?.status == .opened
        if isOpen != panelWasOpen {
            panelWasOpen = isOpen
            if isOpen {
                // ~4 us of sysctl, paid on a user action, so the section's
                // claim about the OS killer is current rather than a
                // memory of what it said at launch.
                PressureAlertEngine.shared.refreshKillerReading()
                PressureAlertEngine.shared.refreshAuthorizationStatus()
                state.killerLine = PressureAlertCopy.killerPanelLine(PressureAlertEngine.shared.killer)
            }
        }
        if !state.history.isEmpty { pruneHistory() }
        guard isOpen else { return }
        // One string per tick, compared before it is published, and only
        // while somebody can read it — the same deal `memorySection` has.
        state.liveLine = liveLine()
        publish()
    }

    private func liveLine() -> String {
        if state.isMuted { return "Предупреждения выключены" }
        if PressureAlertEngine.shared.authorization.isFinal {
            return PressureAlertEngine.shared.authorization.panelLine
        }
        return PressureAlertCopy.suppressionLine(lastSuppression)
    }

    private func handle(_ event: PressureAlertEvent) {
        switch event {
        case .suppressed(let reason):
            // NOT published. The panel reads it on its own tick, and only
            // while it is on screen.
            lastSuppression = reason

        case .authorizationChanged(let auth):
            state.authorization = auth
            publish()

        case .couldNotDeliver(let reason, let trigger):
            // Only worth a row when the reason is one the user can do
            // something about. "Waiting for a readable process list" is
            // our problem, not theirs.
            guard PressureAlertEngine.shared.authorization.isFinal else { return }
            // Belt and braces against a future edit to the engine's own
            // one-shot guard: never two identical blocked rows in a row.
            if case .blocked(let previous)? = state.history.first?.delivery,
               previous == reason { return }
            appendHistory(severity: trigger.severity,
                          appName: "—",
                          footprint: "",
                          delivery: .blocked(reason),
                          id: "blocked.\(Date().timeIntervalSinceReferenceDate)")

        case .posted(let severity, let culprit, let identifier, let bannerExpected):
            appendHistory(severity: severity,
                          appName: culprit.name,
                          footprint: UIFmt.bytes(culprit.footprintBytes),
                          delivery: bannerExpected ? .shown : .silent,
                          id: identifier)

        case .snoozed, .quitRequested, .quitRefused:
            // The island already shows the quit outcome on the app's own
            // row; a second rendering of it here would be a second source
            // of truth for the same fact.
            break
        }
    }

    private func appendHistory(severity: PressureAlertSeverity,
                               appName: String,
                               footprint: String,
                               delivery: PressureAlertEntry.Delivery,
                               id: String) {
        let entry = PressureAlertEntry(id: id,
                                       time: clock.string(from: Date()),
                                       severity: severity,
                                       appName: appName,
                                       footprint: footprint,
                                       delivery: delivery)
        state.history.insert(entry, at: 0)
        historyDates.insert(Date(), at: 0)
        if state.history.count > Self.historyLimit {
            state.history.removeLast()
            historyDates.removeLast()
        }
        state.deliveredToday = state.history.filter {
            if case .blocked = $0.delivery { return false }
            return true
        }.count
        publish()
    }

    private func pruneHistory() {
        let cutoff = Date().addingTimeInterval(-Self.historyLifetime)
        var changed = false
        while let oldest = historyDates.last, oldest < cutoff {
            historyDates.removeLast()
            state.history.removeLast()
            changed = true
        }
        if changed {
            state.deliveredToday = state.history.filter {
                if case .blocked = $0.delivery { return false }
                return true
            }.count
            publish()
        }
    }

    /// The user's switch, from the section.
    func setMuted(_ muted: Bool) {
        precondition(Thread.isMainThread)
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
        PressureAlertEngine.shared.setMuted(muted)
        state.isMuted = muted
        state.liveLine = liveLine()
        publish()
    }

    private func publish() {
        // `setPressureAlert` compares before it assigns — a tick that
        // would draw the same pixels publishes nothing.
        model?.setPressureAlert(state)
    }
}


// =====================================================================
// MARK: - 10. The quit path, wired to the island's own
// =====================================================================

/// Four lines, and they are the whole reason the engine takes a protocol.
/// `requestQuit` is `IslandModel`'s guarded path: graceful `terminate()`
/// only, one app, the one the user pressed the button for. Force quit is
/// never reachable from a notification — it lives behind a second,
/// explicit click on that app's row in the panel.
extension IslandModel: PressureAlertActionHandler {
    func pressureAlertDidRequestQuit(pid: pid_t, name: String) {
        requestQuit(pid: pid)
    }
}
