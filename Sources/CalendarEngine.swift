import Foundation
import AppKit
import EventKit

// =====================================================================
// «Встреча» — time until the next meeting. The sampler half; the view
// lives in IslandSectionCalendar.swift.
//
// IT IS NOT ON THE 1 Hz TICK, AND THAT IS THE DESIGN. MetricsEngine's
// base tick stays 1 Hz and this engine is not on it: it is event-driven
// (.EKEventStoreChanged, wake, clock change) with a 60 s backstop that
// tightens to 15 s only while a meeting is already inside the imminent
// window. On a machine where the user has never turned the feature on it
// does not run at all — not one EventKit call, not one timer, not one
// EKEventStore. And the countdown the island draws costs a subtraction,
// because `CalendarEvent` computes it against `Date()` at READ time
// instead of having the engine republish a number every second.
//
// PUBLIC API SURFACE at the top, the engine below it. Everything the UI
// touches is an immutable value type produced on a private serial queue
// and handed to the main thread — the same shape as MetricsEngine.
//
// FOUR RULES THIS FILE IS BUILT AROUND
//
//   1. PRIVACY. `CalendarEvent.title` is the user's private calendar and
//      it exists in memory and nowhere else. This file contains no
//      `print`, no `NSLog`, no `os_log`, no file write and no
//      UserDefaults write that can ever see a title — and both
//      `description` and `debugDescription` on the event and the
//      snapshot are REDACTED, so that an accidental `print(event)`
//      three files away still cannot leak it. If you add logging here,
//      log `event.redactedDescription`, never `event`.
//
//   2. NIL IS NOT ZERO. Same rule as MetricTypes.swift. `next == nil`
//      means "nothing to count down to"; `minutesUntilStart == nil`
//      means the event has already started, so a *time until start* no
//      longer exists. Neither is a measured 0, and the UI renders them
//      as "—".
//
//   3. NEVER PROMPT UNINVITED. EventKit is the first TCC permission
//      MacPulse would ever ask for. The store is not even constructed
//      until the user explicitly turns the feature on. See "THE LAZY
//      TRIGGER" below.
//
//   4. DENIED IS PERMANENT AND QUIET. A denial tears the feature down
//      for the rest of the process and is never retried. There is no
//      nag loop: `requestAccess` is called AT MOST ONCE per process
//      launch, and only from a user gesture.
//
// ---------------------------------------------------------------------
// INFO.PLIST — REQUIRED, AND THE FAILURE MODE IS SILENT
//
// MacPulse's Info.plist today has NO usage-description keys at all.
// Without the key below, `requestFullAccessToEvents` does not crash and
// does not prompt: it calls back with `granted=false, error=nil` about
// 4 ms later and `calendars(for: .event)` returns an empty array — i.e.
// it looks exactly like "this user has no calendars" (measured on this
// machine, macOS 26.6.2, in the spike).
//
// Add to Info.plist:
//
//   <key>NSCalendarsFullAccessUsageDescription</key>
//   <string>MacPulse показывает время до следующей встречи в островке.</string>
//
// and, because build.sh targets arm64-apple-macos13.0 while
// `requestFullAccessToEvents` is macOS 14+, also add the legacy key that
// the macOS 13 fallback path below (`requestAccess(to:)`) reads:
//
//   <key>NSCalendarsUsageDescription</key>
//   <string>MacPulse показывает время до следующей встречи в островке.</string>
//
// NO ENTITLEMENTS. `com.apple.security.personal-information.calendars`
// is an App Sandbox entitlement and MacPulse is not sandboxed and not
// hardened-runtime. No notarization. One TCC prompt, which then lives in
// System Settings > Privacy & Security > Calendars.
//
// build.sh must gain `-framework EventKit` on the swiftc line. MEASURED
// cost to the no-network contract, which build.sh asserts with `otool -L`
// after every build: EventKit adds exactly TWO lines to the link map —
// EventKit.framework and /usr/lib/swift/libswiftCoreLocation.dylib, the
// Swift overlay EventKit's structured-location API drags in. No
// CFNetwork, no Network.framework, no Security.framework, no
// NetworkExtension, and `lsof` on the running process shows zero sockets:
// calaccessd does any iCloud sync out of process, over XPC. Nothing here
// constructs a CLLocationManager and no location prompt is possible —
// worth knowing before someone greps the link map and panics.
//
// ---------------------------------------------------------------------
// THE LAZY TRIGGER — WHAT I CHOSE AND WHY
//
// Two gates, and BOTH must be open before a single EventKit call is
// made:
//
//   gate 1  UserDefaults["MacPulse.calendar.enabled"], default FALSE.
//   gate 2  the TCC status is already `.fullAccess`.
//
//   * At launch the app calls `startIfEnabled()`. On a machine where
//     the user has never touched the feature, gate 1 is shut, so the
//     engine does nothing at all: no EKEventStore, no query, no timer,
//     and above all no prompt. Cost at launch is one
//     `UserDefaults.bool` read.
//
//   * The ONLY thing that can prompt is `setEnabled(true)`, which is
//     wired to the checkmarked NSMenuItem "Показывать следующую встречу"
//     in the status-item menu, next to "Запускать при входе" — a
//     deliberate click, made one gesture before the dialog appears, on a
//     menu the user opened themselves. That is the difference between a
//     permission dialog and an ambush. NOTHING ELSE MAY CALL IT: this is
//     the first TCC permission MacPulse has ever asked for, and an app
//     that throws a calendar dialog at login stops being a system
//     monitor and becomes something the user distrusts.
//
//   * Once granted, gate 2 is open forever, so every later launch
//     starts the feature straight from `startIfEnabled()` with no
//     prompt and no dialog.
//
// Opening the island panel is deliberately NOT the trigger: opening the
// panel is how you look at memory, and a calendar dialog thrown at that
// moment is exactly the ambush above.
//
// ---------------------------------------------------------------------
// REFRESH STRATEGY
//
//   * `.EKEventStoreChanged` is the primary signal, debounced by 0.75 s
//     because calaccessd posts it in bursts during a sync.
//   * A self-rescheduling one-shot backstop: 60 s normally, 15 s while
//     an event is imminent, and always pulled in to land just after the
//     current event starts (so the countdown rolls over to the next
//     meeting on time) and just as it enters the imminent window.
//   * Wake from sleep and a system-clock change re-query immediately.
//   * There is no hard poll. Between those wakes the queue is idle.
//
// UNVERIFIED, SAY IT OUT LOUD: I did not prove `.EKEventStoreChanged`
// actually fires, because the only way to do that is to write an event
// into the user's real calendar. The backstop timer is what makes that
// acceptable — worst case the countdown is up to 60 s stale.
// =====================================================================

// MARK: - Access

/// TCC state for `EKEntityType.event`, mirrored out of EventKit so that
/// nothing above this file has to `import EventKit`.
///
/// Switched on `rawValue` rather than on `EKAuthorizationStatus`'s cases
/// on purpose: `.fullAccess` and `.writeOnly` are macOS 14+ cases and
/// `.authorized` is deprecated in macOS 14, so naming any of them forces
/// `#available` noise into a file that deploys to macOS 13. The raw
/// values are stable ABI: 0/1/2/3/4.
public enum CalendarAccess: Int, Sendable, Equatable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    /// `.authorized` on macOS 13, `.fullAccess` on macOS 14+. Same value.
    case fullAccess = 3
    case writeOnly = 4
    /// A value this build does not know about — a future macOS adding a
    /// case. Treated exactly like `.restricted`: no access, no retry.
    case unknown = -1

    fileprivate init(rawStatus: Int) {
        self = CalendarAccess(rawValue: rawStatus) ?? .unknown
    }
}

/// Why the calendar section is not available. Every case is a dead end
/// for this process; none of them is retried automatically.
public enum CalendarUnavailable: Sendable, Equatable {
    /// The user said no. Sticky: `requestFullAccessToEvents` will not
    /// re-prompt. Point at System Settings, once, and never again.
    case denied
    /// MDM / Screen Time / parental controls. Not the user's to fix.
    case restricted
    /// Granted, but write-only — EventKit will not hand us events.
    case writeOnly
    /// BUILD ERROR, not a user problem: Info.plist is missing
    /// `NSCalendarsFullAccessUsageDescription`, so a request would fail
    /// silently. See the header.
    case missingUsageDescription
    /// The request came back with an error, or came back not-granted
    /// while the status stayed `.notDetermined` (the silent-failure
    /// shape).
    case requestFailed
}

/// Lifecycle of the feature, as the UI sees it.
public enum CalendarStatus: Sendable, Equatable {
    /// Gate 1 or gate 2 is shut. Nothing has been asked and nothing is
    /// running. Draw no section; offer the menu toggle.
    case off
    /// A TCC prompt is on screen right now.
    case requesting
    /// Dead end. Draw no section. `CalendarUnavailable` says why.
    case unavailable(CalendarUnavailable)
    /// Access granted and the engine is live. `CalendarSnapshot.next`
    /// says whether there is anything to show.
    case ready

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

// MARK: - Colour

/// A calendar's colour as plain sRGB components.
///
/// Deliberately NOT an `NSColor`/`CGColor`: the colour is read on the
/// sampling queue and the snapshot crosses to the main thread, and
/// shipping an AppKit object across that boundary is the kind of thing
/// that works for a year and then does not. Four Doubles are trivially
/// `Sendable`; `nsColor` rebuilds the AppKit object on whichever thread
/// asks.
public struct CalendarTint: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green),
                blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// nil — not black — when there is no colour or it will not convert.
    /// A black chip is a lie; an absent chip is the truth.
    ///
    /// Public because it is the bridge from `EKCalendar.cgColor`, and a
    /// panel view that wants to colour a per-calendar legend needs the
    /// same conversion the engine uses.
    public init?(cgColor: CGColor?) {
        guard let cgColor else { return nil }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3
        else { return nil }
        let a = c.count >= 4 ? c[3] : converted.alpha
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(a))
    }
}

// MARK: - Event

/// One upcoming meeting, flattened out of EventKit.
///
/// The countdown fields are COMPUTED against `Date()` at the moment you
/// read them, not frozen at query time. That is what lets the engine
/// stay quiet: MacPulse already redraws the island at 1 Hz off
/// `MetricsEngine`, so `minutesUntilStart` and `isImminent` are correct
/// on every frame without this engine publishing a snapshot a second.
/// `capturedAt` is there for anyone who needs to know how stale the
/// underlying fetch is.
public struct CalendarEvent: Sendable, Equatable, Identifiable,
                             CustomStringConvertible, CustomDebugStringConvertible {

    /// EventKit's `eventIdentifier`. Useful for "is this still the same
    /// meeting"; nil for calendars that do not vend one.
    public let id: String?

    /// PRIVATE. In memory only. Never logged, never persisted, never
    /// included in `description`. nil when the event genuinely has no
    /// title (EventKit returns an optional and empty titles exist).
    public let title: String?

    public let startDate: Date
    /// nil if EventKit did not give one (it is optional on EKEvent).
    public let endDate: Date?

    /// All-day events are excluded from the countdown by default — a
    /// holiday or a birthday has no "in 12 minutes" — but the flag is
    /// carried so a panel view can still say so if it wants.
    public let isAllDay: Bool

    public let calendarTitle: String?
    /// nil when the calendar has no colour or it would not convert.
    public let calendarTint: CalendarTint?

    /// The window this event calls itself imminent inside. Carried IN
    /// the value so `isImminent` stays a pure function of the value plus
    /// the clock — no reaching back into engine configuration from a
    /// struct that may outlive it.
    public let imminentWindow: TimeInterval
    /// When the fetch that produced this happened.
    public let capturedAt: Date

    public init(id: String?,
                title: String?,
                startDate: Date,
                endDate: Date?,
                isAllDay: Bool,
                calendarTitle: String?,
                calendarTint: CalendarTint?,
                imminentWindow: TimeInterval,
                capturedAt: Date) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.calendarTint = calendarTint
        self.imminentWindow = imminentWindow
        self.capturedAt = capturedAt
    }

    // ---- countdown, evaluated now ----

    /// Seconds from `now` to the start. nil once the meeting has begun:
    /// a "time until start" no longer exists, and that is an ABSENT
    /// value, not a zero.
    public func secondsUntilStart(asOf now: Date = Date()) -> TimeInterval? {
        let d = startDate.timeIntervalSince(now)
        return d > 0 ? d : nil
    }

    /// Minutes until the start, rounded UP, so the label reads "1 мин"
    /// for the whole last minute instead of flicking to 0 thirty
    /// seconds early. nil once the meeting has begun.
    public func minutesUntilStart(asOf now: Date = Date()) -> Int? {
        guard let s = secondsUntilStart(asOf: now) else { return nil }
        return Int((s / 60).rounded(.up))
    }

    public var minutesUntilStart: Int? { minutesUntilStart(asOf: Date()) }

    /// THE STRIP GATE. The arch spike ruled that a countdown only earns
    /// space in the collapsed strip in the last 15 minutes before an
    /// event; outside that window the meeting belongs in the expanded
    /// panel and nowhere else.
    ///
    /// Strictly `0 < remaining <= imminentWindow`: a meeting that has
    /// already started is not imminent, it is late.
    public func isImminent(asOf now: Date = Date()) -> Bool {
        guard let s = secondsUntilStart(asOf: now) else { return false }
        return s <= imminentWindow
    }
    public var isImminent: Bool { isImminent(asOf: Date()) }

    // ---- redaction ----

    /// Safe to print. Says everything about the event EXCEPT what it is.
    public var redactedDescription: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let mins = minutesUntilStart.map(String.init) ?? "—"
        return "CalendarEvent(start: \(f.string(from: startDate)), in: \(mins) min, "
             + "allDay: \(isAllDay), imminent: \(isImminent), "
             + "calendar: \(calendarTitle ?? "—"), title: <\(title == nil ? "none" : "redacted")>)"
    }

    /// `description` and `debugDescription` are the redacted string, on
    /// purpose. String interpolation of an event — anywhere, by anyone,
    /// now or in two years — cannot leak the title.
    public var description: String { redactedDescription }
    public var debugDescription: String { redactedDescription }
}

// MARK: - Snapshot

/// What the engine publishes to the main thread. Immutable, cheap to
/// copy, safe to hold.
public struct CalendarSnapshot: Sendable, Equatable,
                                CustomStringConvertible, CustomDebugStringConvertible {
    public let status: CalendarStatus
    /// The next countdown-worthy meeting, or nil. nil with
    /// `status == .ready` and a non-nil `lastQueryAt` means a real query
    /// ran and found nothing in the horizon — that is a MEASURED
    /// "nothing", not a failure.
    public let next: CalendarEvent?
    /// nil until a query has actually completed.
    public let lastQueryAt: Date?
    /// How far ahead the query looked.
    public let horizon: TimeInterval
    /// Readable event calendars, after exclusions. nil if never queried.
    public let calendarCount: Int?
    /// Events in the horizon that survived filtering. nil if never
    /// queried. 0 is a real, measured zero.
    public let candidateCount: Int?

    public init(status: CalendarStatus,
                next: CalendarEvent? = nil,
                lastQueryAt: Date? = nil,
                horizon: TimeInterval = 0,
                calendarCount: Int? = nil,
                candidateCount: Int? = nil) {
        self.status = status
        self.next = next
        self.lastQueryAt = lastQueryAt
        self.horizon = horizon
        self.calendarCount = calendarCount
        self.candidateCount = candidateCount
    }

    /// `IslandSection.hasState` material: cheap, pure, and FALSE
    /// whenever there is nothing to say. "The calendar is connected" is
    /// not state; "there is a meeting coming" is.
    public var hasState: Bool { next != nil }

    /// The strip only wants this one bit.
    ///
    /// READ IT ON A TICK, NOT OFF A PUBLISH. It is derived from the CLOCK,
    /// and `isMeaningfullyEqual` compares the meeting, not the countdown —
    /// so when a meeting crosses into the 15-minute window the engine
    /// re-queries (the backstop is pulled in to that exact instant) and
    /// then publishes NOTHING, because the same meeting is still the next
    /// meeting. That is correct and deliberate: the transition belongs to
    /// whoever draws, and `IslandModel.refreshCalendarStrip()` evaluates
    /// it on the island's existing 1 Hz tick for the cost of one Optional
    /// read. An engine that published a snapshot a second so the strip
    /// could notice would be paying 60 wake-ups a minute for one event a
    /// day.
    public var isImminent: Bool { next?.isImminent ?? false }

    /// Equal in every way the UI can see — i.e. everything EXCEPT
    /// `lastQueryAt`.
    ///
    /// This is the distinction that makes the backstop free. Synthesized
    /// `==` includes `lastQueryAt`, which moves on every single query,
    /// so deduplicating on `==` would deduplicate nothing and every
    /// 60-second backstop tick would wake every observer to say that
    /// the same meeting is still the next meeting. Dropping
    /// `lastQueryAt` from the comparison instead lets the engine keep
    /// an HONEST staleness stamp in `snapshot` while staying silent.
    ///
    /// `==` is deliberately left synthesized and strict, so a test that
    /// wants exact equality still gets it.
    public func isMeaningfullyEqual(to other: CalendarSnapshot) -> Bool {
        status == other.status
            && next == other.next
            && horizon == other.horizon
            && calendarCount == other.calendarCount
            && candidateCount == other.candidateCount
    }

    /// Redacted, like the event. Safe to print.
    public var description: String {
        "CalendarSnapshot(status: \(status), next: \(next?.redactedDescription ?? "nil"), "
        + "calendars: \(calendarCount.map(String.init) ?? "—"), "
        + "candidates: \(candidateCount.map(String.init) ?? "—"))"
    }
    public var debugDescription: String { description }
}

/// Opaque handle from `CalendarEngine.observe`. Same contract as
/// `MetricsObserverToken`: dropping it does NOT unsubscribe, call
/// `remove(_:)`.
public struct CalendarObserverToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

// MARK: - Engine

/// ============================================================================
/// THE ONE OBJECT THE UI TALKS TO.
///
///     CalendarEngine.shared.startIfEnabled()          // once, from
///                                     // applicationDidFinishLaunching.
///                                     // NEVER PROMPTS.
///     calendarToken = CalendarEngine.shared.observe { [weak self] snap in
///         self?.setCalendar(snap)     // MAIN THREAD. IslandModel.
///     }
///     CalendarEngine.shared.snapshot                  // latest, main only
///     CalendarEngine.shared.setEnabled(true)          // USER GESTURE ONLY.
///                                                     // The only prompt.
///
/// The token works like `MetricsObserverToken`: hold it, and call
/// `remove(_:)` to unsubscribe — dropping it does nothing.
///
/// `snapshot`, `observe`, `remove`, `setEnabled`, `startIfEnabled`,
/// `stop`, `refreshNow`, `revalidate` and `configure` are
/// MAIN-THREAD-ONLY. Everything EventKit is on the private serial queue
/// and nothing on that queue ever touches main except to publish.
/// ============================================================================
public final class CalendarEngine {

    public static let shared = CalendarEngine()

    // NO `didUpdateNotification` HERE, although MetricsEngine has one.
    // That one broadcasts CPU load to the whole process; this one would
    // broadcast a snapshot with the user's meeting title inside it to
    // every observer of the default NotificationCenter, including code
    // that has not been written yet. `observe(_:)` hands the snapshot to
    // exactly the callers that asked for it, which is the whole need —
    // so the broadcast is one privacy surface the feature can simply not
    // have. See rule 1 in the header.

    /// The key whose absence makes the whole feature fail silently.
    public static let usageDescriptionKey = "NSCalendarsFullAccessUsageDescription"

    /// Gate 1. Survives relaunch so a user who turned the feature on
    /// once never sees the toggle reset — and, just as importantly, so
    /// a user who never turned it on never gets EventKit touched.
    public static let enabledDefaultsKey = "MacPulse.calendar.enabled"

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// How far ahead to look. 24 h so that an evening glance still
        /// sees tomorrow's 10:00 stand-up; anything longer is a calendar
        /// app, not a notch.
        public var horizon: TimeInterval = 24 * 3600
        /// The strip budget from the arch spike.
        public var imminentWindow: TimeInterval = 15 * 60
        /// Backstop re-query while nothing is close.
        public var backstopInterval: TimeInterval = 60
        /// Backstop re-query while something IS close — so a meeting
        /// cancelled eight minutes out disappears from the strip.
        public var imminentBackstopInterval: TimeInterval = 15
        /// All-day events have no start time worth counting to.
        public var skipsAllDayEvents = true
        /// A meeting the user declined is not the user's next meeting.
        public var skipsDeclinedEvents = true
        /// `EKEventStatus.canceled`.
        public var skipsCanceledEvents = true
        /// Keep showing a meeting for this long AFTER it starts. 0 =
        /// the countdown is strictly about the future, which is what
        /// "time until the next meeting" means. Raise it if you want
        /// "Стендап · сейчас" to linger.
        public var includesInProgressFor: TimeInterval = 0
        /// `EKCalendar.calendarIdentifier`s to ignore. All-day noise
        /// (Дни рождения, US Holidays) is already handled by
        /// `skipsAllDayEvents`; this is for a chatty work calendar.
        public var excludedCalendarIdentifiers: Set<String> = []
        /// OFF BY DEFAULT and unverified. `refreshSourcesIfNecessary()`
        /// asks calaccessd to pull remote sources; it is synchronous and
        /// can block this queue for an unbounded time. calaccessd syncs
        /// on its own schedule and posts `.EKEventStoreChanged` when it
        /// does, so we do not need it. Turn it on only with a measurement.
        public var refreshesRemoteSources = false

        public init() {}
    }

    /// Main-thread mirror of the configuration. Assign through
    /// `configure(_:)` — the queue gets its own copy so the sample path
    /// never reads a value main is writing.
    public private(set) var configuration = Configuration()

    // MARK: - Main-thread state

    /// Latest published snapshot. Main thread only.
    public private(set) var snapshot = CalendarSnapshot(status: .off)

    private var observers: [CalendarObserverToken: (CalendarSnapshot) -> Void] = [:]
    private var nextObserverID: UInt64 = 1

    /// Set the instant a request is dispatched and never cleared. THE
    /// anti-nag interlock: at most one TCC request per process launch,
    /// however many times the menu item is clicked.
    private var hasRequestedThisLaunch = false
    private var isRunning = false

    // MARK: - Queue state (NEVER touch from main)

    private let queue = DispatchQueue(label: "com.local.macpulse.calendar", qos: .utility)
    /// Built on the queue, the first time access is known to be granted.
    /// Nil while the feature is off — constructing an EKEventStore is
    /// not free and the whole point is to not do it.
    private var store: EKEventStore?
    private var storeChangedObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?
    private var pendingTick: DispatchWorkItem?
    private var queueConfig = Configuration()
    private var lastQueryAt: Date?

    private init() {}

    // MARK: - Access, read-only

    /// Current TCC state. Reading this does NOT prompt (verified: a
    /// process with no usage-description key reads `notDetermined(0)`
    /// and no dialog appears).
    public var access: CalendarAccess {
        CalendarAccess(rawStatus: Int(EKEventStore.authorizationStatus(for: .event).rawValue))
    }

    /// Gate 1. False until the user turns the feature on.
    public var isEnabledByUser: Bool {
        UserDefaults.standard.bool(forKey: CalendarEngine.enabledDefaultsKey)
    }

    /// The build check the spike demanded: without this key the request
    /// fails with `granted=false, error=nil` and zero calendars, which
    /// is indistinguishable from "the user has no calendars".
    public var hasUsageDescription: Bool {
        (Bundle.main.object(forInfoDictionaryKey: CalendarEngine.usageDescriptionKey) as? String)?
            .isEmpty == false
    }

    // MARK: - Lifecycle

    /// Call once from `applicationDidFinishLaunching`, on main.
    ///
    /// NEVER PROMPTS. Starts only if the user has already turned the
    /// feature on AND access is already granted. On a fresh machine this
    /// costs one `UserDefaults.bool` and returns.
    public func startIfEnabled() {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        guard isEnabledByUser else {
            publish(CalendarSnapshot(status: .off))
            return
        }
        guard hasUsageDescription else {
            // Programmer error, not a user problem. No personal data in
            // this message; it is the only thing this file ever logs.
            NSLog("MacPulse: Info.plist is missing %@ — the calendar feature cannot work.",
                  CalendarEngine.usageDescriptionKey)
            publish(CalendarSnapshot(status: .unavailable(.missingUsageDescription)))
            return
        }
        switch access {
        case .fullAccess:
            begin()
        case .denied:
            publish(CalendarSnapshot(status: .unavailable(.denied)))
        case .restricted, .unknown:
            publish(CalendarSnapshot(status: .unavailable(.restricted)))
        case .writeOnly:
            publish(CalendarSnapshot(status: .unavailable(.writeOnly)))
        case .notDetermined:
            // The flag says on, but TCC was reset (or the app was moved
            // and re-signed). Do NOT prompt from launch — that is the
            // ambush this design exists to avoid. Sit in `.off` and let
            // the menu toggle re-arm it.
            publish(CalendarSnapshot(status: .off))
        }
    }

    /// THE ONLY CALL THAT CAN SHOW A PERMISSION DIALOG.
    ///
    /// Wire it to an explicit user gesture and nothing else — a
    /// checkmarked NSMenuItem in the status-item menu. `true` persists
    /// gate 1 and, if TCC has never been asked, asks it ONCE.
    ///
    /// `false` turns the feature off and tears everything down. It does
    /// not and cannot revoke the TCC grant; only System Settings does
    /// that.
    public func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        UserDefaults.standard.set(enabled, forKey: CalendarEngine.enabledDefaultsKey)
        guard enabled else {
            stop()
            publish(CalendarSnapshot(status: .off))
            return
        }
        guard hasUsageDescription else {
            NSLog("MacPulse: Info.plist is missing %@ — the calendar feature cannot work.",
                  CalendarEngine.usageDescriptionKey)
            publish(CalendarSnapshot(status: .unavailable(.missingUsageDescription)))
            return
        }

        switch access {
        case .fullAccess:
            begin()

        case .denied:
            // STICKY. `requestFullAccessToEvents` will not re-prompt
            // here, and asking again would be a nag even if it did.
            // One calm dead end, and `openPrivacySettings()` for the
            // user who wants to undo it.
            publish(CalendarSnapshot(status: .unavailable(.denied)))

        case .restricted, .unknown:
            publish(CalendarSnapshot(status: .unavailable(.restricted)))

        case .notDetermined, .writeOnly:
            // `.writeOnly` -> `.fullAccess` is a legitimate escalation
            // and macOS will show the prompt for it. Both go through the
            // same one-shot interlock.
            //
            // A second click while the first request is still in flight
            // returns and publishes NOTHING. The earlier version
            // published `.unavailable(.requestFailed)` here, and the
            // live harness caught it: three clicks in a row made the
            // section flash a permanent-looking dead end 2.2 s before
            // the user actually granted access. The truth about an
            // in-flight request is whatever its own completion
            // publishes; a second click knows nothing new.
            guard !hasRequestedThisLaunch else { return }
            hasRequestedThisLaunch = true
            publish(CalendarSnapshot(status: .requesting))
            requestAccessOnce()
        }
    }

    /// Stop sampling and release the store. Idempotent. Does not change
    /// gate 1 — use `setEnabled(false)` for that.
    public func stop() {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        isRunning = false
        queue.async { [weak self] in self?.teardownOnQueue() }
    }

    /// Fresh numbers the instant the user looks. Cheap; safe to call
    /// from `menuWillOpen`.
    public func refreshNow() {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        guard isRunning else { return }
        queue.async { [weak self] in self?.query() }
    }

    /// Re-read TCC and start if it has changed underneath us.
    ///
    /// EventKit does not post a notification when the user flips the
    /// switch in System Settings, and this engine deliberately stops
    /// polling once it is in a `.unavailable` state. So there is exactly
    /// one recovery path and it is free: call this when the user opens
    /// the status-item menu (`menuWillOpen`). No timer, no polling.
    public func revalidate() {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        guard isEnabledByUser, !isRunning else { return }
        if access == .fullAccess { begin() }
    }

    /// Replace the configuration. Takes effect on the next query, which
    /// is scheduled immediately if the engine is live.
    public func configure(_ configuration: Configuration) {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        self.configuration = configuration
        let copy = configuration
        queue.async { [weak self] in
            guard let self else { return }
            self.queueConfig = copy
            if self.store != nil { self.query() }
        }
    }

    /// Opens System Settings > Privacy & Security > Calendars. The one
    /// thing to offer a user who hit `.denied` and changed their mind.
    /// Returns false if LaunchServices refused.
    ///
    /// NOT A NETWORK CALL: `x-apple.systempreferences:` is handled by
    /// LaunchServices in another process.
    @discardableResult
    public static func openPrivacySettings() -> Bool {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Observers

    @discardableResult
    public func observe(_ body: @escaping (CalendarSnapshot) -> Void) -> CalendarObserverToken {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        let token = CalendarObserverToken(id: nextObserverID)
        nextObserverID &+= 1
        observers[token] = body
        // Seed immediately so a late subscriber is not blank until the
        // next change — the same courtesy MetricsEngine's menu header
        // relies on.
        body(snapshot)
        return token
    }

    public func remove(_ token: CalendarObserverToken) {
        precondition(Thread.isMainThread, "CalendarEngine is main-thread only")
        observers[token] = nil
    }

    // MARK: - Permission request

    /// One request, one time, from the queue. The completion arrives on
    /// an arbitrary thread — EventKit makes no promise — so it hops
    /// straight back onto our queue and touches nothing else.
    private func requestAccessOnce() {
        queue.async { [weak self] in
            guard let self else { return }
            let store = self.makeStoreIfNeeded()
            CalendarEngine.requestFullAccess(store) { [weak self] granted, error in
                guard let self else { return }
                self.queue.async {
                    let status = self.accessOnQueue()
                    if granted, status == .fullAccess {
                        self.beginOnQueue()
                        return
                    }
                    // Three distinguishable failures, and they are not
                    // the same thing:
                    let reason: CalendarUnavailable
                    if error != nil {
                        reason = .requestFailed
                    } else if status == .denied {
                        reason = .denied                      // user clicked "Не разрешать"
                    } else if status == .restricted || status == .unknown {
                        reason = .restricted
                    } else if status == .writeOnly {
                        reason = .writeOnly
                    } else {
                        // granted=false, error=nil, still notDetermined:
                        // the silent Info.plist failure shape.
                        reason = .requestFailed
                    }
                    self.publishFromQueue(CalendarSnapshot(status: .unavailable(reason)))
                    self.stopFromQueue()
                }
            }
        }
    }

    /// `requestFullAccessToEvents` is macOS 14+; build.sh targets
    /// macOS 13, so the old call has to stay reachable. It is walled off
    /// in a `deprecated:`-marked helper purely so the macOS 13 branch
    /// does not spray deprecation warnings over a clean build.
    private static func requestFullAccess(_ store: EKEventStore,
                                          completion: @escaping (Bool, Error?) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            requestEventAccessLegacy(store, completion: completion)
        }
    }

    @available(macOS, introduced: 10.9, deprecated: 14.0,
               message: "macOS 13 fallback for requestFullAccessToEvents")
    private static func requestEventAccessLegacy(_ store: EKEventStore,
                                                 completion: @escaping (Bool, Error?) -> Void) {
        store.requestAccess(to: .event, completion: completion)
    }

    // MARK: - Start / stop on the queue

    private func begin() {
        precondition(Thread.isMainThread)
        guard !isRunning else {
            refreshNow()
            return
        }
        isRunning = true
        let cfg = configuration
        queue.async { [weak self] in
            guard let self else { return }
            self.queueConfig = cfg
            self.beginOnQueue()
        }
    }

    private func beginOnQueue() {
        _ = makeStoreIfNeeded()
        installObserversOnQueue()
        query()
    }

    private func makeStoreIfNeeded() -> EKEventStore {
        if let store { return store }
        // EKEventStore and every EKEvent it vends are used ONLY on this
        // queue. Nothing EventKit-shaped ever crosses to main; the
        // snapshot is plain values.
        let s = EKEventStore()
        store = s
        return s
    }

    private func installObserversOnQueue() {
        let center = NotificationCenter.default

        if storeChangedObserver == nil {
            // `object: nil`, not `object: store`. Apple documents the
            // store as the notification object, but registering on the
            // instance means a single wrong assumption about which
            // store posts makes the whole refresh path silently dead —
            // and the cost of the wider filter is one extra
            // `queue.async` in a process that has exactly one store.
            //
            // `queue: nil` so the block runs on the posting thread and
            // we hop to our own queue ourselves. Routing it through
            // main would put EventKit's notification storm on the
            // thread that draws.
            storeChangedObserver = center.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.scheduleDebouncedQuery() }
            }
        }

        if clockObserver == nil {
            // NTP step, timezone change, DST. Every cached interval is
            // suspect; re-fetch rather than reason about it.
            clockObserver = center.addObserver(
                forName: .NSSystemClockDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.query() }
            }
        }

        if wakeObserver == nil {
            // A lid opened after four hours: the backstop's pending
            // one-shot fires late and the countdown would show a
            // meeting that ended before lunch.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.query() }
            }
        }
    }

    /// Tear down AND tell main the engine is no longer live.
    ///
    /// The distinction matters: `isRunning` is main-thread state, and a
    /// queue-side teardown that leaves it `true` gives you an engine
    /// that `refreshNow()` keeps waking (rebuilding the store just to
    /// discover it still has no access) and that `revalidate()` will
    /// never restart, because it thinks it is already running.
    private func stopFromQueue() {
        teardownOnQueue()
        DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    }

    private func teardownOnQueue() {
        pendingTick?.cancel()
        pendingTick = nil
        let center = NotificationCenter.default
        if let o = storeChangedObserver { center.removeObserver(o); storeChangedObserver = nil }
        if let o = clockObserver { center.removeObserver(o); clockObserver = nil }
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        store = nil
        lastQueryAt = nil
    }

    // MARK: - Scheduling

    /// Coalesce `.EKEventStoreChanged` bursts. calaccessd posts it once
    /// per changed object during a sync, which is a handful of
    /// notifications inside a second; each one pushes the deadline out
    /// by 0.75 s.
    ///
    /// The `staleness` escape hatch is what stops a pathological stream
    /// of notifications from starving the query forever: once the data
    /// is more than 5 s old we stop deferring and run.
    private func scheduleDebouncedQuery() {
        let stale = lastQueryAt.map { Date().timeIntervalSince($0) > 5 } ?? true
        scheduleTick(after: stale ? 0 : 0.75)
    }

    private func scheduleTick(after delay: TimeInterval) {
        pendingTick?.cancel()
        guard delay > 0 else {
            pendingTick = nil
            query()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTick = nil
            self.query()
        }
        pendingTick = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// ONE self-rescheduling one-shot instead of a repeating timer, so
    /// the next wake can be pulled in to a meaningful instant rather
    /// than landing on an arbitrary 60 s grid.
    ///
    /// Wake at the earliest of:
    ///   * the backstop (60 s, or 15 s while something is imminent),
    ///   * one second after the current event starts — the ROLLOVER, so
    ///     the strip moves on to the next meeting instead of holding a
    ///     dead countdown for up to a minute,
    ///   * the moment the current event enters the imminent window, so
    ///     observers hear about it at the boundary.
    private func scheduleBackstop(after snapshot: CalendarSnapshot) {
        let cfg = queueConfig
        var delay = snapshot.isImminent ? cfg.imminentBackstopInterval : cfg.backstopInterval

        if let start = snapshot.next?.startDate {
            let toRollover = start.timeIntervalSinceNow + cfg.includesInProgressFor + 1
            if toRollover > 0.5, toRollover < delay { delay = toRollover }
            let toImminent = start.timeIntervalSinceNow - cfg.imminentWindow
            if toImminent > 0.5, toImminent < delay { delay = toImminent }
        }
        scheduleTick(after: max(delay, 1))
    }

    // MARK: - The query

    private func accessOnQueue() -> CalendarAccess {
        CalendarAccess(rawStatus: Int(EKEventStore.authorizationStatus(for: .event).rawValue))
    }

    /// Runs ON THE SERIAL QUEUE. Never call from main.
    private func query() {
        let cfg = queueConfig

        // TCC can be revoked while we run — System Settings does not
        // tell us, it just starts refusing. Re-check every time; it is
        // a cheap local call and the alternative is an engine that
        // quietly returns nothing forever.
        let status = accessOnQueue()
        guard status == .fullAccess else {
            let reason: CalendarUnavailable
            switch status {
            case .denied: reason = .denied
            case .writeOnly: reason = .writeOnly
            case .notDetermined: reason = .requestFailed
            default: reason = .restricted
            }
            publishFromQueue(CalendarSnapshot(status: .unavailable(reason), horizon: cfg.horizon))
            stopFromQueue()
            return
        }

        let store = makeStoreIfNeeded()
        if cfg.refreshesRemoteSources {
            store.refreshSourcesIfNecessary()
        }

        let now = Date()
        let calendars = store.calendars(for: .event).filter {
            !cfg.excludedCalendarIdentifiers.contains($0.calendarIdentifier)
        }
        lastQueryAt = now

        guard !calendars.isEmpty else {
            // A real, measured "there is nothing here" — not a failure.
            publishFromQueue(CalendarSnapshot(status: .ready,
                                              next: nil,
                                              lastQueryAt: now,
                                              horizon: cfg.horizon,
                                              calendarCount: 0,
                                              candidateCount: 0))
            scheduleBackstop(after: CalendarSnapshot(status: .ready))
            return
        }

        // `predicateForEvents` returns everything OVERLAPPING the
        // window, so a three-hour meeting that started before `now`
        // comes back too. Start the window at `now - includesInProgressFor`
        // and drop anything whose START is behind us in the filter below.
        let windowStart = now.addingTimeInterval(-max(cfg.includesInProgressFor, 0))
        let windowEnd = now.addingTimeInterval(max(cfg.horizon, 60))
        let predicate = store.predicateForEvents(withStart: windowStart,
                                                 end: windowEnd,
                                                 calendars: calendars)

        let candidates = store.events(matching: predicate)
            .filter { CalendarEngine.isCountdownWorthy($0, now: now, config: cfg) }
            .sorted { $0.startDate < $1.startDate }

        let next = candidates.first.map { event -> CalendarEvent in
            CalendarEvent(
                id: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar?.title,
                calendarTint: CalendarTint(cgColor: event.calendar?.cgColor),
                imminentWindow: cfg.imminentWindow,
                capturedAt: now
            )
        }

        let snap = CalendarSnapshot(status: .ready,
                                    next: next,
                                    lastQueryAt: now,
                                    horizon: cfg.horizon,
                                    calendarCount: calendars.count,
                                    candidateCount: candidates.count)
        publishFromQueue(snap)
        scheduleBackstop(after: snap)
    }

    /// Everything that disqualifies an event from being "the next
    /// meeting". Pure, so the harness can exercise it, and static so it
    /// cannot accidentally reach into queue state.
    private static func isCountdownWorthy(_ event: EKEvent,
                                          now: Date,
                                          config: Configuration) -> Bool {
        // EKEvent.startDate is declared non-optional in Swift but is
        // bridged from an ObjC `NSDate *` that detached/malformed
        // events really can leave nil. Round-tripping through Optional
        // is the only way to survive one without a crash.
        guard let start = (event.startDate as Date?) else { return false }

        if config.skipsAllDayEvents && event.isAllDay { return false }
        if config.skipsCanceledEvents && event.status == .canceled { return false }

        // Strictly the future (plus the optional in-progress grace).
        if start.timeIntervalSince(now) <= -max(config.includesInProgressFor, 0) { return false }

        if config.skipsDeclinedEvents,
           let attendees = event.attendees,
           let me = attendees.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined {
            return false
        }
        return true
    }

    // MARK: - Publishing

    private func publishFromQueue(_ snapshot: CalendarSnapshot) {
        DispatchQueue.main.async { [weak self] in self?.publish(snapshot) }
    }

    /// Main thread. The snapshot is ALWAYS stored — so `lastQueryAt`
    /// stays an honest staleness stamp — but observers are woken only
    /// when something they can see actually changed. The backstop
    /// re-runs the same query every 60 s and almost always produces the
    /// same answer; waking every observer to say so is how an app that
    /// idles at 0.475% of one core becomes the 1.74% one it used to be.
    ///
    /// Note `CalendarEvent`'s countdown fields are computed at READ
    /// time, so they are deliberately not part of the comparison — the
    /// deduplication never hides a ticking clock, only an unchanged
    /// meeting. The island redraws at 1 Hz off `MetricsEngine` anyway,
    /// and reads a fresh `minutesUntilStart` on every one of those
    /// frames.
    private func publish(_ snapshot: CalendarSnapshot) {
        precondition(Thread.isMainThread)
        let changed = !snapshot.isMeaningfullyEqual(to: self.snapshot)
        self.snapshot = snapshot
        guard changed else { return }
        for body in observers.values { body(snapshot) }
    }
}

// MARK: - Formatting

/// Russian-unit formatting for the island, the twin of `UIFmt`.
/// Every function takes an Optional and returns "—" for nil.
///
/// NOTHING HERE TAKES A TITLE. Formatting the title is the caller's
/// business, in a view, at draw time — keeping it out of a shared
/// formatter is one more place it cannot end up in a log line.
public enum CalendarFmt {

    /// "12 мин", "1 ч 05 мин", "сейчас", "—".
    public static func countdown(_ event: CalendarEvent?, asOf now: Date = Date()) -> String {
        guard let event else { return "—" }
        guard let seconds = event.secondsUntilStart(asOf: now) else { return "сейчас" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60
        return String(format: "%d ч %02d мин", hours, minutes % 60)
    }

    /// Compact strip form: "12′", "1:05", "—".
    public static func strip(_ event: CalendarEvent?, asOf now: Date = Date()) -> String {
        guard let event else { return "—" }
        guard let seconds = event.secondsUntilStart(asOf: now) else { return "сейчас" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)′" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// "14:30". Local time, 24 h — this is a Russian-language UI.
    public static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// One short clause for `IslandSection.footerSummary`. Never
    /// includes the title — the footer is 18 pt of shared space and the
    /// title is private.
    public static func footer(_ snapshot: CalendarSnapshot) -> String? {
        guard let next = snapshot.next else { return nil }
        return "Встреча через " + countdown(next)
    }

    /// What to draw INSTEAD of a section when there is nothing.
    /// `nil` means "draw nothing at all", which is the right answer for
    /// every dead end — a permanently-broken row is worse than no row.
    public static func unavailableHint(_ status: CalendarStatus) -> String? {
        guard case .unavailable(let reason) = status else { return nil }
        switch reason {
        case .denied:
            return "Доступ к Календарю запрещён. Системные настройки → Конфиденциальность."
        case .restricted:
            return "Доступ к Календарю ограничен политикой системы."
        case .writeOnly:
            return "Календарь разрешил только запись — события недоступны."
        case .missingUsageDescription, .requestFailed:
            return nil
        }
    }
}
