import Foundation

// =====================================================================
// Bambu P1S print status, read from the user's OWN local panel.
//
// No SwiftUI in this file. It owns the poll cadence, the defensive parse
// and nothing else; `IslandSectionPrinter.swift` draws it.
//
// WHERE THE DATA COMES FROM. The user already runs a LaunchAgent
// (com.pult.p1s) serving a panel on 127.0.0.1:8787. MacPulse reads one
// route from it, GET /api/printer, over a raw loopback socket — see
// PultLink.swift for why that is the only shape of this feature that
// keeps the no-networking contract. MacPulse does NOT talk to the printer
// itself: that would mean MQTT over TLS to a LAN address, i.e.
// Security.framework in the link map and genuine off-box egress.
//
// READ-ONLY, AND STRUCTURALLY SO. The panel exposes pause/resume/stop on
// POST /api/printer/cmd. PultLink has no POST path at all, so there is no
// code here that could send one. A mis-click that ruins a nine-hour print
// is not a risk worth carrying for a feature nobody asked for.
//
// THE ENDPOINT IS UNTRUSTED INPUT. It is JSON from another local process
// that itself parses JSON off the network from a printer. Everything
// below treats it as hostile: every field optional, every number range-
// checked, every string length-bounded before it can reach a view, no
// force-unwraps, and an unparseable reply degrades to "no print section"
// rather than to an error chip.
//
// CADENCE. A 3D print is measured in hours, so this polls slowly and only
// when somebody could see the answer:
//
//   every   8 s  while a print is live (the strip ring is on screen) or
//                while the panel is open
//   every 300 s  otherwise — the discovery poll, so the ring can appear
//                on its own when a print STARTS. Without it the strip
//                could not notice until the user opened the panel, which
//                defeats the one feature with an unrecoverable deadline.
//                Five minutes rather than one because of what a discovery
//                poll costs SOMEBODY ELSE: measured, /api/printer takes
//                3.0 s per call with the printer powered down, because
//                the panel runs its own 3 s TCP probe of the printer
//                before giving up. Polling every minute would mean a SYN
//                on the LAN every minute for a machine that is switched
//                off. A print runs for hours, five minutes to grow a ring
//                is nothing, and opening the island answers immediately.
//   every 600 s  after 3 consecutive failures, because the panel being
//                down is a normal state too (its LaunchAgent may simply
//                be stopped) and must cost nothing at all.
//
// The fetch itself is BLOCKING for up to ~11 s — the panel does a 3 s TCP
// probe plus an 8 s MQTT wait on its own request thread — so it runs on a
// utility queue, never overlaps itself, and publishes on main.
// =====================================================================

/// One reading, already clamped and bounded. Everything is Optional;
/// nil means "the panel did not tell us", which renders as a dash.
struct PrinterReading: Equatable {
    /// Raw Bambu gcode_state: RUNNING, PAUSE, PREPARE, FINISH, FAILED, IDLE.
    var stage: String?
    /// The panel's own Russian label for the stage.
    var stageRu: String?
    /// The panel's `printing` flag: stage is RUNNING, PAUSE or PREPARE.
    var isPrinting: Bool = false
    var percent: Int?
    var remainMin: Int?
    var layer: Int?
    var layersTotal: Int?
    var job: String?
    var nozzle: Int?
    var nozzleTarget: Int?
    var bed: Int?
    var bedTarget: Int?
    var chamber: Int?
    /// "#RRGGBB" of the tray that is loaded right now, if the panel knew.
    var trayColor: String?
    /// HMS codes, already bounded in count and length.
    var errorCodes: [String] = []

    /// Something has gone wrong and the user should look: paused, failed,
    /// or the printer raised an HMS error.
    var needsAttention: Bool {
        !errorCodes.isEmpty || stage == "FAILED" || stage == "PAUSE"
    }

    /// 0...1 for the ring, or nil when the panel has not produced a
    /// percentage yet (it has none during PREPARE and SLICING). nil draws
    /// an EMPTY ring, never a zero-filled one.
    var fraction: Double? {
        guard let percent else { return nil }
        return Double(min(max(percent, 0), 100)) / 100
    }
}

/// What the strip and the panel are allowed to show. `nil` everywhere
/// else in the app means "no print section, no chip, no ring" — which is
/// the correct and by far the most common state.
enum PrinterFeature {

    // MARK: - Parsing

    /// Turn the panel's JSON envelope into a reading, or nil.
    ///
    /// nil is returned for every uninteresting or unintelligible case:
    /// `{"ok": false, ...}` (panel up, printer unreachable), a body that
    /// is not a JSON object, a status block that is not a dictionary, and
    /// a printer that is simply IDLE. The caller cannot tell those apart
    /// and must not: they all mean "draw nothing".
    static func parse(_ body: String) -> PrinterReading? {
        guard let data = body.data(using: .utf8),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // {"ok": false, "error": "..."} — the printer is off or the LAN
        // is blocking. Normal. Silent.
        if let ok = top["ok"] as? Bool, ok == false { return nil }
        guard let status = top["status"] as? [String: Any] else { return nil }

        var r = PrinterReading()
        r.stage = string(status["stage"], max: 24)
        r.stageRu = string(status["stageRu"], max: 32)
        r.isPrinting = (status["printing"] as? Bool) ?? false
        r.percent = int(status["percent"], min: 0, max: 100)
        // A print longer than 30 days is a corrupt field, not a print.
        r.remainMin = int(status["remainMin"], min: 0, max: 60 * 24 * 30)
        r.layer = int(status["layer"], min: 0, max: 1_000_000)
        r.layersTotal = int(status["layersTotal"], min: 0, max: 1_000_000)
        r.job = jobName(status["job"])
        r.nozzle = int(status["nozzle"], min: -50, max: 500)
        r.nozzleTarget = int(status["nozzleTarget"], min: 0, max: 500)
        r.bed = int(status["bed"], min: -50, max: 200)
        r.bedTarget = int(status["bedTarget"], min: 0, max: 200)
        r.chamber = int(status["chamber"], min: -50, max: 200)
        r.trayColor = activeTrayColor(status)
        r.errorCodes = errorCodes(status["errors"])

        // A layer count that exceeds the total is nonsense; drop the pair
        // rather than draw "312 / 238".
        if let l = r.layer, let t = r.layersTotal, t > 0, l > t {
            r.layer = nil
        }

        // IDLE with nothing wrong is not state. No chip, no ring.
        guard r.isPrinting || r.needsAttention || r.stage == "FINISH" else { return nil }
        return r
    }

    /// The job name is the single longest untrusted string in the reply
    /// and the panel falls back from `subtask_name` to `gcode_file`, which
    /// can be "/data/Metadata/plate_1.gcode". Strip the path, strip the
    /// extension, bound the length, and drop control characters.
    private static func jobName(_ any: Any?) -> String? {
        guard var s = string(any, max: 160) else { return nil }
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let dot = s.lastIndex(of: "."), dot != s.startIndex { s = String(s[s.startIndex..<dot]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return String(s.prefix(48))
    }

    /// Colour of the tray the printer says is loaded. Validated as
    /// `#RRGGBB` and rejected otherwise — this string goes into a Color.
    private static func activeTrayColor(_ status: [String: Any]) -> String? {
        guard let now = int(status["trayNow"], min: 0, max: 15),
              let trays = status["trays"] as? [Any] else { return nil }
        for case let tray as [String: Any] in trays.prefix(16) {
            // The panel numbers slots from 1; `trayNow` is 0-based.
            guard int(tray["slot"], min: 0, max: 16) == now + 1 else { continue }
            guard (tray["empty"] as? Bool) != true else { return nil }
            guard let hex = string(tray["color"], max: 9), hex.count == 7, hex.hasPrefix("#"),
                  hex.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
            return hex
        }
        return nil
    }

    private static func errorCodes(_ any: Any?) -> [String] {
        guard let list = any as? [Any] else { return [] }
        var out: [String] = []
        // Three is all that fits on the line; the printer can raise more.
        for case let e as [String: Any] in list.prefix(3) {
            if let code = string(e["code"], max: 24) { out.append(code) }
        }
        return out
    }

    /// Accepts a JSON number OR a numeric string (the panel's `_int` can
    /// hand back either depending on what the printer sent), rejects
    /// anything outside a sane range, and never traps on overflow.
    private static func int(_ any: Any?, min lo: Int, max hi: Int) -> Int? {
        var v: Int?
        if let n = any as? Int { v = n }
        else if let d = any as? Double { v = d.isFinite ? Int(d.rounded()) : nil }
        else if let s = any as? String { v = Int(s.prefix(12)) }
        guard let v, v >= lo, v <= hi else { return nil }
        return v
    }

    private static func string(_ any: Any?, max: Int) -> String? {
        guard let s = any as? String else { return nil }
        let clean = s.prefix(max).filter { !$0.isNewline && $0 != "\r" && $0 != "\t" }
        return clean.isEmpty ? nil : String(clean)
    }

    // MARK: - Formatting

    /// "47м", "1ч23", "23ч", "—".
    ///
    /// The minutes are dropped past ten hours for a layout reason that is
    /// also a legibility one: "23ч59" lays out at 29.3 pt and the strip
    /// slot has 25 (see IslandMetrics), and at twenty-three hours to go the
    /// minutes were never information anyway. The widest string this can
    /// return is therefore "9ч59" at 23.4 pt, measured.
    static func remaining(_ minutes: Int?) -> String {
        guard let minutes else { return "—" }
        if minutes < 60 { return "\(minutes)м" }
        let hours = minutes / 60
        if hours >= 10 { return "\(hours)ч" }
        return "\(hours)ч\(String(format: "%02d", minutes % 60))"
    }

    /// Wall-clock ETA — "готово 16:42". Far more useful than "83 минуты",
    /// which the user then has to add to the current time themselves.
    static func eta(_ minutes: Int?, now: Date = Date()) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: now.addingTimeInterval(TimeInterval(minutes) * 60))
    }

    static func temperature(_ value: Int?, target: Int?) -> String {
        guard let value else { return "—" }
        guard let target, target > 0 else { return "\(value)°" }
        return "\(value)/\(target)°"
    }
}

// MARK: - The poller

/// Owns the timer and the background fetch. One instance, created by
/// `IslandModel`. Main thread for everything public.
final class PrinterPoller {

    /// While a print is on screen — strip ring live, or the panel open.
    private let activeInterval: TimeInterval = 8
    /// Discovery, so the strip can notice a print that STARTS while the
    /// panel is shut. One loopback socket every five minutes — and see the
    /// header for why five and not one: the call costs the user's own
    /// panel a 3 s TCP probe of a printer that is usually switched off.
    private let idleInterval: TimeInterval = 300
    /// The panel is down, or the printer has been off for a while. This
    /// machine spends most of its life here.
    private let backoffInterval: TimeInterval = 600
    private let failuresBeforeBackoff = 3

    /// Nothing at all happens for this long after launch. The arch spike's
    /// rule: never do discovery work in didFinishLaunching.
    private let launchDelay: TimeInterval = 15

    private let queue = DispatchQueue(label: "com.local.macpulse.pult", qos: .utility)

    private weak var model: IslandModel?
    private var running = false
    private var panelOpen = false
    private var showing = false
    private var failures = 0
    /// Bumped on every (re)schedule so a stale timer callback is dropped
    /// instead of firing a second overlapping fetch.
    private var generation: UInt64 = 0
    private var inFlight = false
    /// FINISH stays on screen briefly and then stops being state. Without
    /// this the "done" chip would either vanish instantly or stick until
    /// the next print.
    private var finishFirstSeen: Date?
    private let finishLinger: TimeInterval = 5 * 60

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        schedule(after: launchDelay)
    }

    func stop() {
        precondition(Thread.isMainThread)
        running = false
        generation &+= 1
    }

    /// The panel opened or closed. Opening pulls a fresh reading at once —
    /// a user who opens the printer tab should not look at an eight-second
    /// old number when a live one costs one loopback round trip.
    func setPanelOpen(_ open: Bool) {
        precondition(Thread.isMainThread)
        guard panelOpen != open else { return }
        panelOpen = open
        guard running else { return }
        if open {
            schedule(after: 0)
        } else {
            schedule(after: currentInterval())
        }
    }

    private func currentInterval() -> TimeInterval {
        if failures >= failuresBeforeBackoff && !panelOpen { return backoffInterval }
        if panelOpen || showing { return activeInterval }
        return idleInterval
    }

    private func schedule(after delay: TimeInterval) {
        generation &+= 1
        let g = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // `running` and `generation` are main-thread state; read them
            // there and only there.
            DispatchQueue.main.async {
                guard self.running, g == self.generation, !self.inFlight else { return }
                self.inFlight = true
                self.queue.async { self.fetch() }
            }
        }
    }

    /// UTILITY QUEUE. Blocking for up to ~12 s in the worst case.
    private func fetch() {
        let body = try? PultLink.fetchPrinterStatus()
        // Parse off-main too: it is JSON from an untrusted source and
        // there is no reason for main to pay for it.
        let reading = body.flatMap { PrinterFeature.parse($0) }
        let ok = body != nil
        DispatchQueue.main.async { [weak self] in
            self?.publish(reading: reading, reachable: ok)
        }
    }

    private func publish(reading: PrinterReading?, reachable: Bool) {
        precondition(Thread.isMainThread)
        inFlight = false
        failures = reachable ? 0 : min(failures + 1, failuresBeforeBackoff)

        // FINISH lingers, then stops counting as state.
        var shown = reading
        if reading?.stage == "FINISH" {
            let first = finishFirstSeen ?? Date()
            finishFirstSeen = first
            if Date().timeIntervalSince(first) > finishLinger { shown = nil }
        } else {
            finishFirstSeen = nil
        }

        showing = shown != nil
        model?.setPrinter(shown)
        guard running else { return }
        schedule(after: currentInterval())
    }
}
