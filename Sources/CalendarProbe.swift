import AppKit
import SwiftUI

// =====================================================================
// `--calendar-probe` — the diagnostic for «Встреча», in the same shape as
// --printer-probe and --privacy-probe: inert unless the flag is on the
// command line, and it prints what the SHIPPING code actually saw rather
// than what it was supposed to see.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --calendar-probe
//   ... --calendar-probe --png /tmp/out        # render the 560 x 186 body
//   ... --calendar-probe --allow-prompt        # may show the TCC dialog
//
// FOUR THINGS IT PROVES, in this order:
//
//   1. THE BUILD. Bundle id, both Info.plist usage-description keys, and
//      `hasUsageDescription` — the one missing key that makes the whole
//      feature fail SILENTLY (granted=false, error=nil, zero calendars,
//      indistinguishable from "this user has no calendars").
//   2. THE REAL READ. What the engine actually found in this machine's
//      calendars, with the shipping configuration, titles redacted.
//   3. THE IMMINENT GATE at its boundary — the 15 minutes that are the
//      only thing that earns a slot in the collapsed strip.
//   4. THE ROUTER. Whether the rail grows a chip, what the footer says,
//      and what the strip slot is showing — read off a real IslandModel
//      through the registered IslandSection, not re-implemented here.
//
// IT DOES NOT PROMPT unless you pass --allow-prompt. Without that flag it
// asks EventKit for nothing it has not already been granted, which is the
// same promise `startIfEnabled()` makes at launch.
//
// IT RESTORES WHAT IT TOUCHED. The probe has to open gate 1 to make the
// engine run, and gate 1 is a UserDefaults flag the user owns, so the
// original value is put back before it exits — a diagnostic that silently
// turns a feature on is a diagnostic nobody can trust.
//
// TITLES ARE NEVER PRINTED. Every event goes through
// `redactedDescription`; the title's LENGTH is printed instead, which is
// enough to prove the string is really there and tells you nothing about
// what it says.
// =====================================================================

enum CalendarProbe {

    static func run(arguments: [String]) -> Never {
        let engine = CalendarEngine.shared
        let allowPrompt = arguments.contains("--allow-prompt")
        let pngDir = value(after: "--png", in: arguments)

        // `--tee <file>` exists because of TCC, not because of taste. A
        // permission dialog is only offered to a process LaunchServices
        // started — run the binary straight out of Contents/MacOS from a
        // shell and macOS holds the SHELL responsible, so the request
        // comes back granted=false/error=nil in two milliseconds with no
        // dialog at all. The way to see the dialog is
        //   open -a MacPulse.app --args --calendar-probe --allow-prompt
        // and that throws stdout away. This puts it in a file instead.
        if let tee = value(after: "--tee", in: arguments) {
            _ = freopen(tee, "w", stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
        }

        print("=== MacPulse --calendar-probe ===")
        print("")

        // ---- 1. the build ----
        print("--- BUILD ---")
        print("bundle                \(Bundle.main.bundleIdentifier ?? "<none>")")
        for key in ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"] {
            let v = Bundle.main.object(forInfoDictionaryKey: key) as? String
            print("Info.plist            \(key) = \(v ?? "<ABSENT>")")
        }
        print("hasUsageDescription   \(engine.hasUsageDescription)")
        if !engine.hasUsageDescription {
            print("  ^ BUILD ERROR, not a user problem. Without this key a request comes")
            print("    back granted=false / error=nil with zero calendars and NO dialog.")
        }
        print("")

        // ---- 2. the gates, and the cost of the launch path ----
        let gate1WasOpen = engine.isEnabledByUser
        print("--- GATES (both must be open before one EventKit call is made) ---")
        print("gate 1  UserDefaults[\(CalendarEngine.enabledDefaultsKey)] = \(gate1WasOpen)")
        print("gate 2  TCC authorizationStatus                            = \(engine.access)")

        var t0 = DispatchTime.now().uptimeNanoseconds
        engine.startIfEnabled()
        var us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        print(String(format: "startIfEnabled() returned in %.1f us", us)
              + ", status \(engine.snapshot.status) — this is the")
        print("launch path, and it cannot reach a permission dialog at all.")
        print("")

        // ---- 3. the live read ----
        print("--- LIVE READ (shipping configuration) ---")
        if engine.access == .fullAccess {
            print("access is already granted; no dialog is possible from here.")
        } else if allowPrompt {
            print("access is \(engine.access) and --allow-prompt was passed: macOS may")
            print("show the TCC dialog now. Answer it; the probe waits 120 s.")
        } else {
            print("access is \(engine.access). NOT ASKING — pass --allow-prompt to let")
            print("this probe show the dialog. Everything below will be empty.")
        }

        if engine.access == .fullAccess || allowPrompt {
            t0 = DispatchTime.now().uptimeNanoseconds
            engine.setEnabled(true)          // the only call that can prompt
            us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            print(String(format: "setEnabled(true) returned in %.1f us (main never blocks)", us))
            // Wait for the ANSWER, not for a fixed interval: a dialog the
            // user walks up to two minutes later still has to be recorded,
            // and a machine that is already granted must not stall for it.
            let deadline = Date().addingTimeInterval(engine.access == .fullAccess ? 3 : 120)
            while Date() < deadline {
                spin(0.25)
                if case .requesting = engine.snapshot.status { continue }
                if engine.snapshot.lastQueryAt != nil || engine.snapshot.status.isUnavailable {
                    break
                }
            }
        }

        let live = engine.snapshot
        dump(live, label: "SNAPSHOT AS PUBLISHED")
        print("")

        // ---- 3b. the same calendars, with the all-day filter off ----
        //
        // "5 calendars, 0 candidates" is a weak proof on its own: it looks
        // identical to a read that failed quietly. So widen the window and
        // drop the one filter that is doing all the work on this machine,
        // and the events appear — which is what shows the store really was
        // read. Titles stay redacted; only the length is printed.
        if case .ready = live.status {
            print("--- THE SAME CALENDARS, NOT THE SHIPPING CONFIGURATION ---")
            print("horizon 45 d and skipsAllDayEvents = false, to show that the empty")
            print("answer above is a FILTER doing its job and not a failed read.")
            var wide = CalendarEngine.Configuration()
            wide.horizon = 45 * 24 * 3600
            wide.skipsAllDayEvents = false
            engine.configure(wide)
            spin(1.5)
            dump(engine.snapshot, label: "WIDENED")
            print("")
            print("Restoring the shipping configuration (24 h, all-day events skipped):")
            engine.configure(CalendarEngine.Configuration())
            spin(1.5)
            dump(engine.snapshot, label: "SHIPPING AGAIN")
            print("")
        }

        // ---- 3c. what this costs on the island's 1 Hz tick ----
        print("--- PER-TICK COST ---")
        print("What IslandModel.refreshCalendarStrip() does on every metrics tick is")
        print("`calendar.isImminent`, and then a string format only inside the window.")
        let quiet = CalendarSnapshot(status: .ready, lastQueryAt: Date(), horizon: 24 * 3600)
        let far = CalendarSnapshot(status: .ready,
                                   next: synthetic(start: Date().addingTimeInterval(3600)),
                                   lastQueryAt: Date(), horizon: 24 * 3600)
        let near = CalendarSnapshot(status: .ready,
                                    next: synthetic(start: Date().addingTimeInterval(600)),
                                    lastQueryAt: Date(), horizon: 24 * 3600)
        bench("isImminent, next == nil (this machine, every tick)") { _ = quiet.isImminent }
        bench("isImminent, meeting outside the window") { _ = far.isImminent }
        bench("isImminent + CalendarFmt.strip (inside the window only)") {
            if near.isImminent { _ = CalendarFmt.strip(near.next) }
        }
        print("")

        // ---- 4. the imminent gate, at the boundary ----
        print("--- THE 15-MINUTE GATE, AT ITS BOUNDARY ---")
        print("The arch spike's rule: a countdown earns a slot in the collapsed strip")
        print("only inside the imminent window. `isImminent` is 0 < remaining <= window,")
        print("so a meeting that has already STARTED is not imminent, it is late.")
        print("")
        print("  " + pad("offset", 12) + pad("isImminent", 13) + pad("approach", 11)
              + pad("strip", 9) + "countdown")
        let now = Date()
        for offset in [3600.0, 901, 900, 899, 450, 60, 1, 0, -1, -60] {
            let e = synthetic(start: now.addingTimeInterval(offset))
            let approach = MeetingFeature.approach(e, asOf: now)
                .map { String(format: "%.3f", $0) } ?? "—"
            print("  " + pad(String(format: "%+.0f s", offset), 12)
                  + pad(e.isImminent(asOf: now) ? "true" : "false", 13)
                  + pad(approach, 11)
                  + pad(CalendarFmt.strip(e, asOf: now), 9)
                  + CalendarFmt.countdown(e, asOf: now))
        }
        print("")
        print("`approach` is nil — an EMPTY ring, never a zero-length arc — outside the")
        print("window, because there is no percentage of the way to a meeting.")
        print("")

        // ---- 5. the router, through the registered section ----
        print("--- THE ROUTER (real IslandModel, real IslandSection.calendar) ---")
        let model = IslandModel()
        IslandSectionRegistry.register(.calendar)
        model.setStatus(.opened)

        model.setCalendar(live)
        report(model, "with THIS MACHINE'S real snapshot")

        let soon = synthetic(start: Date().addingTimeInterval(12 * 60 + 30))
        model.setCalendar(CalendarSnapshot(status: .ready, next: soon, lastQueryAt: Date(),
                                           horizon: 24 * 3600,
                                           calendarCount: live.calendarCount ?? 5,
                                           candidateCount: 2))
        report(model, "with a SYNTHETIC meeting 12.5 min out (inside the window)")

        let later = synthetic(start: Date().addingTimeInterval(65 * 60))
        model.setCalendar(CalendarSnapshot(status: .ready, next: later, lastQueryAt: Date(),
                                           horizon: 24 * 3600,
                                           calendarCount: live.calendarCount ?? 5,
                                           candidateCount: 3))
        report(model, "with a SYNTHETIC meeting 65 min out (outside the window)")
        print("")

        // ---- 6. pixels ----
        if let pngDir {
            print("--- RENDER (the registered section's own body, 560 x 186) ---")
            model.setCalendar(live)
            render(model, to: pngDir + "/calendar-empty.png", label: "empty (this machine)")
            model.setCalendar(CalendarSnapshot(status: .ready, next: soon, lastQueryAt: Date(),
                                               horizon: 24 * 3600,
                                               calendarCount: live.calendarCount ?? 5,
                                               candidateCount: 2))
            render(model, to: pngDir + "/calendar-imminent.png", label: "12.5 min out")
            model.setCalendar(CalendarSnapshot(status: .ready, next: later, lastQueryAt: Date(),
                                               horizon: 24 * 3600,
                                               calendarCount: live.calendarCount ?? 5,
                                               candidateCount: 3))
            render(model, to: pngDir + "/calendar-later.png", label: "65 min out")
            print("")
        }

        // ---- 7. put gate 1 back exactly as it was ----
        if !gate1WasOpen {
            engine.setEnabled(false)
            print("gate 1 restored to false (the probe opened it; it was not yours).")
        }
        print("=== done ===")
        exit(0)
    }

    // MARK: - Helpers

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Column padding done by hand: `String(format:)`'s width modifiers do
    /// not apply to `%@`, and a table that silently loses its columns is a
    /// table nobody reads.
    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    /// A stand-in event with the SHIPPING imminent window, so the gate the
    /// table exercises is the one the app ships. The title is a literal,
    /// never a real one — this file must never read the user's calendar
    /// for anything it prints.
    private static func synthetic(start: Date) -> CalendarEvent {
        CalendarEvent(id: "probe",
                      title: "Синтетическая встреча",
                      startDate: start,
                      endDate: start.addingTimeInterval(3600),
                      isAllDay: false,
                      calendarTitle: "Рабочий",
                      calendarTint: CalendarTint(red: 0.796, green: 0.188, blue: 0.878),
                      imminentWindow: CalendarEngine.Configuration().imminentWindow,
                      capturedAt: Date())
    }

    /// Runs the MAIN run loop, because that is where the engine publishes.
    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Nanoseconds per call, over enough iterations that the clock's own
    /// resolution is not what is being measured.
    private static func bench(_ label: String, _ body: () -> Void) {
        let n = 1_000_000
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { body() }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(n)
        print(String(format: "  %10.1f ns/call   ", ns) + label)
    }

    private static func dump(_ s: CalendarSnapshot, label: String) {
        print("\(label):")
        print("  status              \(s.status)")
        print("  calendarCount       \(s.calendarCount.map(String.init) ?? "— (never queried)")")
        print("  candidateCount      \(s.candidateCount.map(String.init) ?? "— (never queried)")")
        print("  lastQueryAt         \(s.lastQueryAt.map { "\($0)" } ?? "— (no query ever ran)")")
        print("  hasState            \(s.hasState)      <- IslandSection.hasState")
        print("  isImminent          \(s.isImminent)      <- the strip's only gate")
        if let next = s.next {
            print("  next                \(next.redactedDescription)")
            print("  title in memory     \(next.title.map { "<\($0.count) chars, not printed>" } ?? "nil")")
            print("  countdown           \(CalendarFmt.countdown(next))")
            print("  strip               \(CalendarFmt.strip(next))")
        } else {
            print("  next                nil")
        }
        print("  footerSummary       \(CalendarFmt.footer(s) ?? "nil")")
        print("  footnote            \(MeetingFeature.footnote(s))")
    }

    private static func report(_ model: IslandModel, _ label: String) {
        print("  \(label):")
        print("    visibleSections   \(model.visibleSections.map(\.rawValue))")
        print("    rail has Встреча  \(model.visibleSections.contains(.calendar))")
        print("    selectedSection   \(model.selectedSection.rawValue)")
        print("    footerLine        \"\(model.footerLine)\"")
        print("    stripSlotSection  \(model.stripSlotSection.rawValue)")
        print("    calendarStrip     \(model.calendarStrip.map { "\"\($0)\"" } ?? "nil (no slot)")")
    }

    /// Renders the REGISTERED section's body — `IslandSection.calendar
    /// .makeBody(model)`, the same AnyView the router puts on screen — on
    /// the plate's own dark ground, so the 560 x 186 canvas can be looked
    /// at on a machine with no notch.
    private static func render(_ model: IslandModel, to path: String, label: String) {
        _ = NSApplication.shared
        let size = NSSize(width: IslandMetrics.panelWidth, height: IslandMetrics.bodyHeight)
        let root = ZStack {
            Color(white: 0.06)
            IslandSection.calendar.makeBody(model)
        }
        .frame(width: size.width, height: size.height)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        // Far off any screen: this is a render, not a window anybody sees.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        spin(0.35)

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("  render FAILED (no bitmap rep): \(label)")
            window.orderOut(nil)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
            print("  render FAILED (could not write): \(path)")
            return
        }
        print("  \(label) -> \(path)  (\(data.count) bytes)")
    }
}
