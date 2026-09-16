import AppKit
import ApplicationServices
import Darwin

// =====================================================================
// THE APP'S ACTUAL WINDOWS, AND WHY THIS FILE HAD TO EXIST AT ALL.
//
// The grey badge on a «Память» row is `AppUsage.memberPIDs.count` — how
// many PROCESSES the kernel's responsibility table folds into one app.
// It is not a window count and never was. Measured on this machine:
//
//     Cursor    10 processes   1 window
//     Telegram   3 processes   1 window
//     Finder     1 process     N windows
//
// So "click the badge and close nine of the ten" cannot mean the badge's
// own number. The nine are Electron helpers — tab renderers, the
// extension host, the GPU process. Offering a per-process Quit there
// would let one click kill the extension host or a renderer holding an
// unsaved tab, and the app would respawn it a second later: a footgun
// that looks like a feature. That button does not exist anywhere in this
// file, and §B of IslandWindowPopover.swift says so on screen in one
// line.
//
// What the badge opens instead is THIS: the app's real windows, read
// through the Accessibility API, each closable by pressing its own red
// dot.
//
// ---------------------------------------------------------------------
// HOW A WINDOW IS CLOSED HERE, AND WHY IT IS THE SAFE VERB
//
//     AXUIElementCreateApplication(pid)
//       -> kAXWindowsAttribute          the windows
//       -> kAXTitleAttribute            what to call each one
//       -> kAXCloseButtonAttribute      the red dot itself
//       -> AXUIElementPerformAction(kAXPressAction)
//
// Pressing the close button is EXACTLY what the user's own mouse does.
// The app gets its own `windowShouldClose:`, puts up its own "Save
// changes?" sheet, and can refuse. Nothing is bypassed, no window is
// destroyed behind the app's back, and MacPulse never sends a signal,
// never calls terminate() and never touches a process here. The one
// termination affordance in the whole panel is still the row's own
// «Завершить», which is NSRunningApplication.terminate() — see
// IslandModel's "the one action with a real effect".
//
// ---------------------------------------------------------------------
// ACCESSIBILITY IS A REAL COST AND IT IS PAID LAZILY
//
// MacPulse asked for ZERO permissions before this. The README said so.
// Reading another app's windows is not possible without Accessibility —
// there is no unprivileged API for it, which is the same wall
// IslandMetrics ran into trying to measure other apps' menu bar extras.
//
// So the rule is the calendar's rule, copied deliberately (see
// CalendarEngine.swift, "THE LAZY TRIGGER"):
//
//   * NOTHING here runs at launch. `AXIsProcessTrusted` is not read, no
//     AXUIElement is created, no observer is installed. The whole file
//     is cold until a click.
//   * The prompt (`AXIsProcessTrustedWithOptions` with
//     kAXTrustedCheckOptionPrompt) is raised ONLY from
//     `IslandModel.openWindowPopover`, i.e. one gesture after the user
//     clicked the badge, and AT MOST ONCE PER LAUNCH — `hasPrompted`
//     below is the same one-shot interlock as the calendar's
//     `hasRequestedThisLaunch`. There is no nag loop and no timer that
//     can start one.
//   * DENIED IS A CALM PERMANENT STATE. The popover still opens, the
//     process half below still renders, and the window half says one
//     line and offers one button that opens System Settings at the
//     Accessibility pane. It never asks again.
//   * Granting it in System Settings arrives as a distributed
//     notification (`com.apple.accessibility.api`), observed ONLY while
//     the popover is open, so the list fills in without a relaunch and
//     without a poll.
//
// ---------------------------------------------------------------------
// THREADING AND COST
//
// IN THE APP, EVERY CALL IN HERE IS ON THE MAIN THREAD, because every
// caller is `IslandModel` and `IslandModel` is main-thread only — all
// four entry points assert it. They therefore must NEVER run on the 1 Hz
// metrics tick: nothing in this file is reachable from
// `IslandModel.ingest`. They run when the popover opens, when the user
// clicks a button in it, and when the accessibility grant changes. That
// is all.
//
// The thread assertion lives THERE and not here, and that is deliberate
// rather than sloppy. `--windows-probe self` reads MacPulse's OWN
// accessibility tree, and a process cannot do that from the main thread:
// the main thread is what would have to answer the request, so it
// deadlocks and comes back as `.notResponding` at the messaging timeout
// (measured — that is exactly what the first version of the probe did).
// Self-inspection is the one caller that must be off main, and asserting
// main HERE would have meant either no self-test or a test hook in
// shipping code. The invariant the app actually needs is "IslandModel is
// main-thread only", and IslandModel states it itself.
//
// `AXUIElementSetMessagingTimeout(app, 0.2)` bounds the damage from an
// app that is wedged: a hung target costs 200 ms per attribute instead
// of blocking the island for the system default (6 s). The scan is also
// capped at `maxWindows`, so the worst case is bounded in both factors.
// =====================================================================

// MARK: - What a scan can produce

/// One window of one app, as the Accessibility API reports it.
///
/// `id` is the window's index in the app's `kAXWindows` array at scan
/// time, and it is only meaningful against the element table captured by
/// the SAME scan — `IslandModel` keeps the two together and never acts on
/// an index from an older read. Every optional here is a real "could not
/// measure" and the view draws it as a dash.
struct AppWindowRow: Identifiable, Equatable {
    let id: Int
    /// nil when the window has no title at all (some panels do not).
    let title: String?
    /// The one that survives «Закрыть остальные».
    let isMain: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    /// False when the window has no close button — a modal sheet, some
    /// utility panels. The row then offers no button rather than a button
    /// that would do nothing.
    let canClose: Bool
}

/// Why a window list could not be produced. Four genuinely different
/// answers that would otherwise all look like an empty list.
enum WindowScanFailure: Equatable {
    /// Accessibility has not been granted to MacPulse.
    case notTrusted
    /// Granted, but the app did not answer within the messaging timeout.
    case notResponding
    /// The PID is gone.
    case noSuchProcess
    /// COUNTED BUT NOT READABLE, and this case exists because it was
    /// measured rather than imagined.
    ///
    /// `kAXWindows` comes back with the right NUMBER of entries — checked
    /// against `CGWindowListCopyWindowInfo`, which touches no
    /// accessibility at all — and then not one entry resolves to a
    /// window: every element reports `AXRole == AXApplication`, CFEquals
    /// the application element, and has no close button.
    ///
    /// WHAT PRODUCES IT HERE: a LOCKED SCREEN. Timed on this machine —
    /// the screen locked at 22:25:28 (`CGSSessionScreenIsLocked`), and a
    /// read twenty seconds earlier, from the same unsigned binary with
    /// the same borrowed trust, returned proper `AXStandardWindow`
    /// elements with titles and close buttons. Every read after the lock
    /// returned this. macOS will say how many windows an app has while
    /// the screen is locked; it will not hand out the windows themselves.
    ///
    /// It is NOT the same thing as having no permission: an untrusted
    /// process is refused cleanly and early with kAXErrorAPIDisabled
    /// (-25211), which is `.notTrusted` above — also measured, from a
    /// freshly built bundle with an identity macOS had never seen.
    ///
    /// Without this case the popover would have drawn N rows all titled
    /// with the app's own name, every one of them showing a dash instead
    /// of a button, under a «Закрыть остальные (0)» that could never do
    /// anything. Silently useless is the worst available answer, so the
    /// state is named instead. The count travels with it because the
    /// count IS trustworthy, and it is what the header prints.
    case unresolved(Int)
}

/// The result of one scan. `windows == nil` iff `failure != nil`.
/// An EMPTY array is a measured "this app has no windows" — which is the
/// whole point of the feature, because that is what a ten-process
/// Electron app usually reports.
struct AppWindowScan: Equatable {
    let windows: [AppWindowRow]?
    let failure: WindowScanFailure?

    static func failed(_ why: WindowScanFailure) -> AppWindowScan {
        AppWindowScan(windows: nil, failure: why)
    }

    /// How many windows the app reported, even when their elements could
    /// not be resolved — the array length survives `.unresolved`.
    var count: Int? {
        if let windows { return windows.count }
        if case .unresolved(let n) = failure { return n }
        return nil
    }
    /// Windows «Закрыть остальные» would actually close: everything that
    /// is not the main one AND has a close button to press. The number the
    /// button prints is this one, so the count is a promise.
    var closableOthers: [AppWindowRow] {
        (windows ?? []).filter { !$0.isMain && $0.canClose }
    }
}

/// One member process of a grouped row. DIAGNOSTIC ONLY — there is no
/// action on it anywhere in this app. See the note in the popover.
struct MemberProcessRow: Identifiable, Equatable {
    let pid: pid_t
    var id: pid_t { pid }
    let name: String
    /// `ri_phys_footprint`, or nil for a process this uid cannot read.
    let footprintBytes: UInt64?
}

// MARK: - The Accessibility layer

enum AppWindowList {

    /// Cap on one scan. A browser with 200 windows would otherwise cost
    /// 200 synchronous round trips on the main thread.
    static let maxWindows = 60

    /// How long any one attribute read may take before we give up on the
    /// target app. The system default is 6 s, which is an eternity to
    /// freeze an overlay for.
    private static let messagingTimeout: Float = 0.2

    // MARK: Trust

    /// Has the user granted MacPulse Accessibility? READS ONLY — this
    /// never prompts and is safe to call from anywhere.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// True once this process has shown the system prompt. One per
    /// launch, for ever — same interlock as CalendarEngine.
    private(set) static var hasPrompted = false

    /// THE ONLY THING IN MACPULSE THAT CAN RAISE THE ACCESSIBILITY
    /// PROMPT. Called from exactly one place: the first time the user
    /// opens a badge popover. Returns the trust state after the call.
    ///
    /// A second call is a plain `AXIsProcessTrusted()` — the prompt
    /// option is passed at most once per launch, so there is no nag loop
    /// even if the user opens the popover fifty times.
    @discardableResult
    static func requestTrustOnce() -> Bool {
        precondition(Thread.isMainThread, "AX is main-thread only")
        if hasPrompted { return AXIsProcessTrusted() }
        hasPrompted = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings > Privacy & Security > Accessibility. The one
    /// thing to offer a user who said no and changed their mind.
    ///
    /// NOT A NETWORK CALL: `x-apple.systempreferences:` is a local URL
    /// scheme handled by LaunchServices in another process — the same one
    /// CalendarEngine.openPrivacySettings uses.
    @discardableResult
    static func openAccessibilitySettings() -> Bool {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// The notification macOS posts when the Accessibility grant changes.
    /// Observed ONLY while a popover is open — see IslandModel.
    static let trustDidChangeNotification =
        Notification.Name("com.apple.accessibility.api")

    // MARK: Scanning

    /// Read one app's windows. Main thread, synchronous, bounded.
    ///
    /// Returns the rows AND the elements they were read from, in the same
    /// order: the caller must keep them together, because a row's `id` is
    /// an index into that exact array and into no other.
    static func scan(pid: pid_t) -> (scan: AppWindowScan, elements: [AXUIElement]) {
        guard isTrusted else { return (.failed(.notTrusted), []) }
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else {
            return (.failed(.noSuchProcess), [])
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        guard let elements = copyElements(app, kAXWindowsAttribute) else {
            // Trusted, but the app did not answer. An app with genuinely
            // no windows answers with an EMPTY array, not an error, so
            // these two are distinguishable and are not conflated.
            return (.failed(.notResponding), [])
        }
        // KEEP ONLY WHAT IS ACTUALLY A WINDOW. Two things make this
        // necessary and neither is hypothetical:
        //
        //   * a client whose trust is borrowed gets the app element back
        //     for every entry (see `.unresolved`), and
        //   * `kAXWindows` legitimately contains sheets and drawers in
        //     some apps, and a sheet is not a window the user closes —
        //     it belongs to the window behind it.
        //
        // One extra round trip per window, bounded by `maxWindows`.
        let capped = Array(elements.prefix(maxWindows))
            .filter { stringValue($0, kAXRoleAttribute) == kAXWindowRole }
        if capped.isEmpty && !elements.isEmpty {
            return (.failed(.unresolved(elements.count)), [])
        }

        // WHICH ONE SURVIVES «Закрыть остальные», in the order the task
        // requires: kAXMain, then the app's focused window, then the
        // first. Every step is a real reading; the last is a fallback and
        // is the only one that could be wrong, which is why the surviving
        // window is NAMED in the popover before anything is closed.
        var mainIndex: Int? = capped.firstIndex { boolValue($0, kAXMainAttribute) == true }
        if mainIndex == nil, let focused = copyElement(app, kAXFocusedWindowAttribute) {
            mainIndex = capped.firstIndex { CFEqual($0, focused) }
        }
        if mainIndex == nil, !capped.isEmpty { mainIndex = 0 }

        let rows = capped.enumerated().map { i, window in
            AppWindowRow(
                id: i,
                title: stringValue(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 },
                isMain: i == mainIndex,
                isMinimized: boolValue(window, kAXMinimizedAttribute) == true,
                // Not a public constant on every SDK this builds against,
                // and it is simply the string either way.
                isFullScreen: boolValue(window, "AXFullScreen") == true,
                canClose: copyElement(window, kAXCloseButtonAttribute) != nil
            )
        }
        return (AppWindowScan(windows: rows, failure: nil), capped)
    }

    // MARK: Acting

    /// Press one window's close button. Returns false if the window has
    /// no close button or the press was refused.
    ///
    /// This is the red dot, not a kill: the app runs `windowShouldClose:`,
    /// may put up a save sheet, and may decline. A `true` here means the
    /// press was delivered, NOT that the window went away — the caller
    /// re-scans to find out, which is the only honest way to know.
    @discardableResult
    static func close(_ window: AXUIElement) -> Bool {
        guard let button = copyElement(window, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: - Member processes (diagnostics only)

    /// Footprint and executable name for each PID folded into one app row.
    ///
    /// ONE SHOT, ON A CLICK — not sampling. `ProcessSampler` owns the 1 Hz
    /// walk and stays on its own queue; this is ~10 `proc_pid_rusage` and
    /// ~10 `proc_pidpath` calls, once, when the user opens the popover,
    /// measured at well under a millisecond for a 10-process group. It is
    /// here rather than in the sampler precisely so that the per-process
    /// breakdown costs nothing at all while nobody is looking at it.
    static func members(_ pids: [pid_t]) -> [MemberProcessRow] {
        pids.map { pid in
            MemberProcessRow(pid: pid,
                             name: executableName(pid) ?? "pid \(pid)",
                             footprintBytes: footprint(pid))
        }
    }

    private static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    /// The last path component of the executable. `proc_name` truncates to
    /// 16 characters, which turns every Electron helper into "Cursor
    /// Helper (" — indistinguishable from each other, i.e. useless for the
    /// one question this list exists to answer ("which helper got fat?").
    private static func executableName(_ pid: pid_t) -> String? {
        // 4 * MAXPATHLEN. PROC_PIDPATHINFO_MAXSIZE is a C macro Swift
        // cannot import ("structure not supported"), so the value is
        // spelled out against the header it comes from.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if !path.isEmpty {
                let leaf = (path as NSString).lastPathComponent
                if !leaf.isEmpty { return leaf }
            }
        }
        var short = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &short, UInt32(short.count)) > 0 else { return nil }
        let name = String(cString: short)
        return name.isEmpty ? nil : name
    }

    // MARK: - AX plumbing
    //
    // Every accessor is type-checked with CFGetTypeID before the cast.
    // AXUIElementCopyAttributeValue hands back whatever the TARGET APP
    // put there, and a force-cast of somebody else's data is how a
    // monitor crashes because a text editor returned a number where the
    // documentation promised a string.

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let v = copyValue(element, attribute), CFGetTypeID(v) == CFStringGetTypeID()
        else { return nil }
        return (v as! CFString) as String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let v = copyValue(element, attribute), CFGetTypeID(v) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copyValue(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID()
        else { return nil }
        return (v as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let v = copyValue(element, attribute), CFGetTypeID(v) == CFArrayGetTypeID()
        else { return nil }
        let array = v as! CFArray
        var out: [AXUIElement] = []
        out.reserveCapacity(CFArrayGetCount(array))
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let child = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            out.append(child)
        }
        return out
    }
}
