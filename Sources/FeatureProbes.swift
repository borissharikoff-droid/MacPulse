import AppKit
import Combine
import Foundation

// =====================================================================
// Hidden diagnostics for the two features added in this phase, in the
// same style as `--probe`, `--wing-probe` and `--cost-log`: never
// reachable from the UI, and doing nothing unless the flag is on the
// command line.
//
// THEY EXERCISE THE SHIPPING CODE, NOT A COPY OF IT. `--printer-probe`
// goes through the real `PultLink` and the real `PrinterFeature.parse`;
// `--privacy-probe` starts the real `PrivacyWatcher` against a real
// `IslandModel` and prints what the island's views would see. A probe
// that reimplements the thing it is testing proves nothing about the
// thing that ships.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --printer-probe
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --printer-fuzz
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --privacy-probe 60
// =====================================================================

enum PrinterProbe {

    static func run(arguments: [String]) -> Never {
        print("=== MacPulse --printer-probe ===")
        print("")

        // `--printer-parse <file>` exercises the PARSER alone, against a
        // body that came from somewhere other than the socket. It exists
        // because this P1S is powered off most of the time, so the only
        // way to see the printing path is to feed it a payload produced by
        // the panel's own printer.parse_status(). It is an honest split:
        // the LINK is proven live by the default mode below, the PARSER is
        // proven here, and neither claims to have proven the other.
        if let i = arguments.firstIndex(of: "--printer-parse"), i + 1 < arguments.count {
            let path = arguments[i + 1]
            guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("cannot read \(path)")
                exit(2)
            }
            print("--- PARSER ONLY, body from \(path) (no socket opened) ---")
            print("")
            report(body: body, transportNote: "read from file, \(body.utf8.count) bytes")
        }

        print("Where the kernel says this socket lands (getpeername, not our own")
        print("source): \(PultLink.describePeerForProbe())")
        print("")

        let started = Date()
        let body: String
        do {
            body = try PultLink.fetchPrinterStatus()
        } catch {
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "fetch FAILED after %.0f ms: ", ms) + "\(error)")
            print("")
            print("This is a NORMAL state, not an error: the panel LaunchAgent may be")
            print("stopped. The island renders it as no chip and no ring.")
            exit(2)
        }
        let ms = Date().timeIntervalSince(started) * 1000
        report(body: body,
               transportNote: String(format: "GET /api/printer -> 200, %d bytes in %.0f ms",
                                     body.utf8.count, ms))
    }

    private static func report(body: String, transportNote: String) -> Never {
        print(transportNote)
        print("")
        print("--- RAW JSON, exactly as the panel sent it -------------------------")
        print(body.count > 4000 ? String(body.prefix(4000)) + " …[truncated]" : body)
        print("")
        print("--- WHAT PrinterFeature.parse MADE OF IT ---------------------------")
        guard let r = PrinterFeature.parse(body) else {
            print("parse -> nil")
            print("")
            print("nil is the deliberate outcome for all of: {\"ok\": false} (panel up,")
            print("printer unreachable), a printer that is IDLE, and a body that is not")
            print("the JSON we expect. The island cannot tell them apart and must not:")
            print("every one of them means \"draw nothing\" — no chip, no ring, no")
            print("footer clause.")
            exit(0)
        }
        row("stage", r.stage)
        row("stageRu", r.stageRu)
        row("isPrinting", "\(r.isPrinting)")
        row("percent", r.percent.map(String.init))
        row("fraction (ring)", r.fraction.map { String(format: "%.2f", $0) })
        row("remainMin", r.remainMin.map(String.init))
        row("  -> strip text", PrinterFeature.remaining(r.remainMin))
        row("  -> panel ETA", PrinterFeature.eta(r.remainMin))
        row("layer", r.layer.map(String.init))
        row("layersTotal", r.layersTotal.map(String.init))
        row("job", r.job)
        row("nozzle", PrinterFeature.temperature(r.nozzle, target: r.nozzleTarget))
        row("bed", PrinterFeature.temperature(r.bed, target: r.bedTarget))
        row("chamber", r.chamber.map { "\($0)°" })
        row("trayColor", r.trayColor)
        row("errorCodes", r.errorCodes.isEmpty ? nil : r.errorCodes.joined(separator: ", "))
        row("needsAttention", "\(r.needsAttention)")
        print("")
        // Push the reading through the real model so the strings below are
        // the ones the island would actually draw, router and all.
        let model = IslandModel()
        model.setPrinter(r)
        print("strip tooltip:   \(PrintStripSlot.tooltip(r))")
        print("footer clause:   \(IslandSection.printer.footerSummary(model) ?? "—")")
        print("chip is live:    \(IslandSection.printer.hasState(model))")
        print("strip slot tab:  \(model.stripSlotSection)")
        print("trailing wing:   requested \(IslandMetrics.maxTrailingWingWidth) pt, "
              + "model granted \(model.trailingWingWidth) pt "
              + "(a probe process has no status item, so nothing has proved there is "
              + "room and the wing refuses to grow past the resting width)")
        let layout = IslandMetrics.trailingLayout(wing: IslandMetrics.maxTrailingWingWidth,
                                                  slotVisible: true)
        print("at the \(IslandMetrics.maxTrailingWingWidth) pt ceiling (the widest row):")
        print("   lead-in \(layout.leadingGap) pt, slot \(layout.slotWidth) pt, "
              + "time text \(layout.showsSlotText), "
              + "spent \(layout.spent) / \(IslandMetrics.maxTrailingWingWidth) pt")
        exit(0)
    }

    private static func row(_ label: String, _ value: String?) {
        let pad = label.count >= 18 ? label : label + String(repeating: " ", count: 18 - label.count)
        print("  \(pad)  \(value ?? "— (nil: not reported)")")
    }
}

// MARK: -

/// `--printer-fuzz`: replay every payload that is known to have broken the
/// parser, plus the neighbouring cases, through the REAL
/// `PrinterFeature.parse`. Exit status is 0 only if all of them survived
/// AND produced the expected reading.
///
/// WHY THIS EXISTS AS A PERMANENT PROBE. The panel's JSON is untrusted
/// input from another process that itself parses JSON off the network from
/// a printer, and the first version of `PrinterFeature.int` used the
/// TRAPPING `Int(_: Double)`. `{"percent": 1e300}` therefore killed the
/// whole shipping app with SIGTRAP (exit 133) — through this very binary's
/// own `--printer-parse`. A crash that is reachable from a device on the
/// LAN is not something to fix once and hope about; every payload below is
/// one that did it, or one that would if the guard were weakened again.
///
/// A case FAILS if parse traps (the process dies, so no summary prints),
/// or if the value it produced is not the expected one. Expecting the
/// value matters as much as surviving: clamping 1e300 to 100 would also
/// "not crash" while drawing a full ring for a number nobody sent.
enum PrinterFuzz {

    private struct Case {
        let name: String
        let body: String
        /// Holds on whatever parse returned, reading or nil. Written over
        /// the Optional on purpose: for a hostile number the acceptable
        /// answers are "a reading with that field nil" AND "no reading at
        /// all" (JSONSerialization rejects some of these bodies outright),
        /// and both are correct — what must never happen is a trap, or a
        /// fabricated value.
        let expect: (PrinterReading?) -> Bool
        let why: String
    }

    /// The field is nil, or there is no reading at all. The shape every
    /// hostile-number case wants.
    private static func absent(_ field: @escaping (PrinterReading) -> Bool)
        -> (PrinterReading?) -> Bool {
        { $0.map(field) ?? true }
    }

    static func run() -> Never {
        print("=== MacPulse --printer-fuzz ===")
        print("")
        print("Every payload below goes through the SHIPPING PrinterFeature.parse.")
        print("The first five are the ones that crashed the shipping binary with")
        print("SIGTRAP (exit 133) before Int(exactly:) replaced Int(_:Double).")
        print("")

        // `printing: true` everywhere, because an IDLE printer parses to nil
        // before any number is looked at and would prove nothing.
        func status(_ fields: String) -> String {
            "{\"ok\":true,\"status\":{\"printing\":true,\"stage\":\"RUNNING\",\(fields)}}"
        }

        let nothing: (PrinterReading?) -> Bool = { $0 == nil }

        let cases: [Case] = [
            // ---- THE FIVE THAT CRASHED THE SHIPPING BINARY ----
            Case(name: "percent 1e300", body: status("\"percent\":1e300"),
                 expect: absent { $0.percent == nil && $0.fraction == nil },
                 why: "finite, far outside Int — isFinite did not bound it"),
            Case(name: "remainMin 1e300", body: status("\"remainMin\":1e300"),
                 expect: absent { $0.remainMin == nil },
                 why: "same field, same trap"),
            Case(name: "layer 9.9e18", body: status("\"layer\":9.9e18"),
                 expect: absent { $0.layer == nil },
                 why: "just past Int.max (9.223e18) — the nastiest one to eyeball"),
            Case(name: "nozzle -1e300", body: status("\"nozzle\":-1e300"),
                 expect: absent { $0.nozzle == nil },
                 why: "the negative side of the same hole"),
            Case(name: "percent 99999999999999999999999",
                 body: status("\"percent\":99999999999999999999999"),
                 expect: absent { $0.percent == nil },
                 why: "an integer literal too big for Int arrives here as a Double"),

            // ---- the neighbours of those five ----
            Case(name: "percent 1e309 -> +infinity", body: status("\"percent\":1e309"),
                 expect: absent { $0.percent == nil },
                 why: "overflows to +inf while parsing; Int(_:Double) traps on it too"),
            Case(name: "percent -1e309 -> -infinity", body: status("\"percent\":-1e309"),
                 expect: absent { $0.percent == nil },
                 why: "and on -inf"),
            Case(name: "percent \"nan\" (string)", body: status("\"percent\":\"nan\""),
                 expect: absent { $0.percent == nil },
                 why: "JSON has no NaN literal, but the panel's _int can hand back a string"),
            Case(name: "layer 9223372036854775807 (Int.max)",
                 body: status("\"layer\":9223372036854775807"),
                 expect: absent { $0.layer == nil },
                 why: "representable, and still nowhere near the 0...1000000 range"),
            Case(name: "percent 4096-digit string",
                 body: status("\"percent\":\"" + String(repeating: "9", count: 4096) + "\""),
                 expect: absent { $0.percent == nil },
                 why: "length-bounded, and NOT truncated to a shorter number that fits"),

            // ---- absurd but representable: rejected, never clamped ----
            Case(name: "percent 101", body: status("\"percent\":101"),
                 expect: absent { $0.percent == nil },
                 why: "one past the plausible range — rejected, not clamped down to 100"),
            Case(name: "percent -1", body: status("\"percent\":-1"),
                 expect: absent { $0.percent == nil },
                 why: "a negative percentage is not a percentage"),
            Case(name: "layer -5", body: status("\"layer\":-5"),
                 expect: absent { $0.layer == nil },
                 why: "a negative layer count"),
            Case(name: "remainMin 44640 (31 days)", body: status("\"remainMin\":44640"),
                 expect: absent { $0.remainMin == nil },
                 why: "longer than any real print — a corrupt field, not a print"),
            Case(name: "nozzle 5000", body: status("\"nozzle\":5000"),
                 expect: absent { $0.nozzle == nil },
                 why: "no nozzle is at 5000 C; physically implausible is dropped"),
            Case(name: "bed -273", body: status("\"bed\":-273"),
                 expect: absent { $0.bed == nil },
                 why: "and neither is a bed at absolute zero"),
            Case(name: "layer 312 of 238", body: status("\"layer\":312,\"layersTotal\":238"),
                 expect: { $0?.layer == nil && $0?.layersTotal == 238 },
                 why: "a layer past the total is nonsense; drop the layer, keep the total"),

            // ---- strings, which reach the screen ----
            Case(name: "job: 48 KB with embedded newlines",
                 body: status("\"job\":\"" + String(repeating: "A\\nB", count: 16000) + "\""),
                 expect: { ($0?.job?.count ?? 99) <= 48 && $0?.job?.contains("\n") == false },
                 why: "the longest untrusted string in the reply, bounded before it is drawn"),
            Case(name: "job: C0 control characters",
                 body: status("\"job\":\"pl\\u0007ate\\u0000_1\""),
                 expect: { $0?.job == "plate_1" },
                 why: "control characters are dropped, never drawn"),
            Case(name: "job: a path, as the panel really sends it",
                 body: status("\"job\":\"/data/Metadata/plate_1.gcode\""),
                 expect: { $0?.job == "plate_1" },
                 why: "the ordinary case still has to work after all that hardening"),
            Case(name: "stage: 4096 characters",
                 body: status("\"stage\":\"" + String(repeating: "X", count: 4096) + "\""),
                 expect: { ($0?.stage?.count ?? 99) <= 24 },
                 why: "every string is length-bounded, not just the job name"),
            Case(name: "tray colour \"#<scrip\"",
                 body: status("\"trayNow\":0,\"trays\":[{\"slot\":1,\"color\":\"#<scrip\"}]"),
                 expect: absent { $0.trayColor == nil },
                 why: "this string reaches a SwiftUI Color; #RRGGBB or nothing"),
            Case(name: "tray colour \"#ff8800\" (valid)",
                 body: status("\"trayNow\":0,\"trays\":[{\"slot\":1,\"color\":\"#ff8800\"}]"),
                 expect: { $0?.trayColor == "#ff8800" },
                 why: "and a valid one still gets through"),
            Case(name: "trayNow 1e300", body: status("\"trayNow\":1e300,\"trays\":[]"),
                 expect: absent { $0.trayColor == nil },
                 why: "the tray index goes through the same converter"),
            Case(name: "tray slot 1e300",
                 body: status("\"trayNow\":0,\"trays\":[{\"slot\":1e300,\"color\":\"#FF0000\"}]"),
                 expect: absent { $0.trayColor == nil },
                 why: "and so does the slot number inside each tray"),
            Case(name: "500 HMS errors",
                 body: status("\"errors\":[" + Array(repeating: "{\"code\":\"HMS_0001\"}", count: 500)
                              .joined(separator: ",") + "]"),
                 expect: { ($0?.errorCodes.count ?? 99) <= 3 && $0?.needsAttention == true },
                 why: "bounded in count before it reaches a one-line footer"),

            // ---- the ordinary reading, so the hardening cannot have eaten it ----
            Case(name: "percent 47.6 (a real fractional percent)",
                 body: status("\"percent\":47.6"),
                 expect: { $0?.percent == 48 && $0?.fraction == 0.48 },
                 why: "rounds and survives — the parser still has to work"),
            Case(name: "percent \"47\" (numeric string)", body: status("\"percent\":\"47\""),
                 expect: { $0?.percent == 47 },
                 why: "the panel's _int hands back strings too, depending on the printer"),

            // ---- shapes, not numbers ----
            Case(name: "status is an array", body: "{\"ok\":true,\"status\":[1,2,3]}",
                 expect: nothing, why: "wrong shape degrades to no section at all"),
            Case(name: "percent is an object", body: status("\"percent\":{\"a\":1}"),
                 expect: absent { $0.percent == nil },
                 why: "a wrong type for a number is nil, never a guess"),
            Case(name: "ok:false", body: "{\"ok\":false,\"error\":\"printer offline\"}",
                 expect: nothing, why: "the normal state: panel up, printer off. Silent."),
            Case(name: "not JSON at all", body: "<html>502 Bad Gateway</html>",
                 expect: nothing, why: "an unintelligible body draws nothing"),
            Case(name: "empty body", body: "",
                 expect: nothing, why: "so does no body at all"),
            Case(name: "400-deep nested arrays",
                 body: String(repeating: "[", count: 400) + String(repeating: "]", count: 400),
                 expect: nothing, why: "not a dictionary; rejected before anything recurses"),
        ]

        var failures: [String] = []
        for c in cases {
            // If parse traps, the process dies HERE and no summary is printed —
            // which is itself the failure signal, and is exactly how the
            // original bug showed up: exit 133, no output.
            let reading = PrinterFeature.parse(c.body)
            let ok = c.expect(reading)
            let got = describe(reading)
            if !ok { failures.append("\(c.name) -> \(got)") }
            print("  \(ok ? "ok  " : "FAIL") \(pad(c.name, 40))  \(got)")
            print("       \(c.why)")
        }

        print("")
        print("\(cases.count) payloads, \(cases.count - failures.count) as specified.")
        if failures.isEmpty {
            print("OK — nothing trapped, and no field was clamped into a value the")
            print("panel never sent. Every rejected number came out nil, which the")
            print("island draws as a dash.")
            exit(0)
        }
        for f in failures { print("FAIL — \(f)") }
        exit(1)
    }

    private static func describe(_ r: PrinterReading?) -> String {
        guard let r else { return "nil (no section)" }
        func o(_ v: Int?) -> String { v.map(String.init) ?? "—" }
        return "percent=\(o(r.percent)) remain=\(o(r.remainMin)) "
            + "layer=\(o(r.layer))/\(o(r.layersTotal)) nozzle=\(o(r.nozzle)) bed=\(o(r.bed)) "
            + "tray=\(r.trayColor ?? "—") errors=\(r.errorCodes.count) "
            + "stage=\(r.stage.map { "\"\($0.prefix(12))\"" } ?? "—") "
            + "job=\(r.job.map { "\"\($0)\"" } ?? "—")"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

// MARK: -

enum PrivacyProbe {

    /// Prints one line per PUBLISHED change of `IslandModel.privacy`, with
    /// a timestamp, for as long as asked. Start and stop a recording while
    /// it runs and the transitions appear here.
    static func run(arguments: [String]) -> Never {
        var seconds: TimeInterval = 60
        // `Double("1e400")` is +infinity and passes `v > 0`, and `Int(inf)`
        // TRAPS — the same class of bug as the printer parser's. A duration
        // from a string gets a finite range check, not a sign check.
        if let i = arguments.firstIndex(of: "--privacy-probe"), i + 1 < arguments.count,
           let v = Double(arguments[i + 1]), v.isFinite, v > 0, v <= 86_400 {
            seconds = v
        }

        let model = IslandModel()
        let watcher = PrivacyWatcher(model: model)

        print("=== MacPulse --privacy-probe, \(Int(seconds)) s ===")
        print("Camera devices found (CoreMediaIO, unprivileged):")
        for device in PrivacyWatcher.videoDevices() {
            print("  dev=\(device)  \(PrivacyWatcher.cameraName(device) ?? "?")"
                  + "  running=\(PrivacyWatcher.cameraIsRunning(device))")
        }
        print("")
        print("Every line below is a PUBLISHED change of IslandModel.privacy —")
        print("exactly what the island's views observe. Silence means nothing")
        print("changed, which is the correct behaviour for a listener-driven")
        print("feature and the reason this costs 0% at rest.")
        print("")

        var bag: AnyCancellable?
        bag = model.$privacy.sink { state in
            let t = stamp()
            let mic = state.micActive
                ? "MIC=ON  [" + (state.micApps.isEmpty ? "(unattributed)"
                                                       : state.micApps.joined(separator: ", ")) + "]"
                : "MIC=off"
            let cam = state.cameraActive
                ? "CAM=ON  [" + state.cameraDevices.joined(separator: ", ") + "]"
                : "CAM=off"
            print("\(t)  \(mic)   \(cam)")
            // The raw CoreAudio holders behind that line, so a verification
            // run can show WHICH process was found and how its name was
            // resolved — not just that the dot lit up.
            for raw in PrivacyWatcher.describeHoldersForProbe() {
                print("            raw: \(raw)")
            }
            fflush(stdout)
        }

        watcher.start()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        watcher.stop()
        bag?.cancel()
        print("=== done ===")
        exit(0)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
