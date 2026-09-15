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
        // the LINK is proven live by the default mode above, the PARSER is
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
              + "(no status item in a probe process, so only the static ceiling applies)")
        let layout = IslandMetrics.trailingLayout(wing: 79.5,
                                                  privacyVisible: true,
                                                  slotVisible: true)
        print("at the 79.5 pt this machine really grants, with both privacy dots up:")
        print("   slot \(layout.slotWidth) pt, time text \(layout.showsSlotText), "
              + "rail \(layout.railWidth) pt")
        exit(0)
    }

    private static func row(_ label: String, _ value: String?) {
        let pad = label.count >= 18 ? label : label + String(repeating: " ", count: 18 - label.count)
        print("  \(pad)  \(value ?? "— (nil: not reported)")")
    }
}

// MARK: -

enum PrivacyProbe {

    /// Prints one line per PUBLISHED change of `IslandModel.privacy`, with
    /// a timestamp, for as long as asked. Start and stop a recording while
    /// it runs and the transitions appear here.
    static func run(arguments: [String]) -> Never {
        var seconds: TimeInterval = 60
        if let i = arguments.firstIndex(of: "--privacy-probe"), i + 1 < arguments.count,
           let v = Double(arguments[i + 1]), v > 0 {
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
