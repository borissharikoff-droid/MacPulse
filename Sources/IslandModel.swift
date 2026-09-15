import AppKit
import Combine

// =====================================================================
// View model for the island. Main thread only.
//
// Everything that SwiftUI reads lives here; the controller (windows,
// monitors, geometry) owns this object and pokes `status` at it. Every
// @Published write is guarded by an equality check — publishing the raw
// pointer position at pointer sample rate would re-lay-out the whole
// SwiftUI tree ~120x/second for nothing.
// =====================================================================

enum IslandStatus: Int, Equatable {
    /// Pointer elsewhere. Bare strip, no dashboard in the view tree.
    case closed
    /// Pointer over the strip. It grows a couple of points; the dwell
    /// timer is running.
    case popping
    /// Dashboard is out, either by dwell or by an explicit click.
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

final class IslandModel: ObservableObject {
    // ---- live data ----
    @Published private(set) var snapshot: MetricsSnapshot?
    /// Decompression bytes/s, downsampled to 2-second buckets, oldest

    // ---- interaction state ----
    @Published private(set) var status: IslandStatus = .closed
    /// Click-to-pin: the panel stays out until the user clicks again.
    @Published private(set) var isPinned = false

    @Published private(set) var quitPhases: [pid_t: QuitPhase] = [:]

    /// Set from the controller so the SwiftUI layer can draw the correct
    /// body width without knowing anything about NSScreen.
    @Published private(set) var notchSize = CGSize(width: 180, height: 32)
    @Published private(set) var hasPhysicalNotch = true

    private var token: MetricsObserverToken?

    // MARK: - Lifecycle

    func start() {
        precondition(Thread.isMainThread)
        MetricsEngine.shared.start()
        token = MetricsEngine.shared.observe { [weak self] snap in
            self?.ingest(snap)
        }
    }

    func stop() {
        if let token { MetricsEngine.shared.remove(token) }
        token = nil
    }

    func setGeometry(notchSize: CGSize, hasPhysicalNotch: Bool) {
        if self.notchSize != notchSize { self.notchSize = notchSize }
        if self.hasPhysicalNotch != hasPhysicalNotch { self.hasPhysicalNotch = hasPhysicalNotch }
    }

    private func ingest(_ snap: MetricsSnapshot) {
        snapshot = snap


        // Retire finished quit rows once the app is really gone.
        pruneQuitPhases()
    }

    // MARK: - Interaction state

    func setStatus(_ new: IslandStatus) {
        guard status != new else { return }
        status = new
    }

    func setPinned(_ new: Bool) {
        guard isPinned != new else { return }
        isPinned = new
    }

    // MARK: - Derived readouts for the collapsed strip

    var pressureLevel: MemoryPressureLevel? { snapshot?.memory?.pressureLevel }

    var topApp: AppUsage? { snapshot?.processes?.apps.first }

    /// Rows for the expanded panel. Only apps we could actually offer a
    /// Quit button for are worth showing a button on; the rest still show
    /// their footprint, just without an action.
    var topApps: [AppUsage] {
        Array((snapshot?.processes?.apps ?? []).prefix(5))
    }

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

    func requestQuit(_ app: AppUsage) {
        precondition(Thread.isMainThread)
        guard quitPhase(for: app.pid) == .idle else { return }
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            quitPhases[app.pid] = .failed("не приложение")
            return
        }
        quitPhases[app.pid] = .asked
        let ok = running.terminate()          // graceful: sends the Quit Apple event
        if !ok {
            quitPhases[app.pid] = .needsForce
            return
        }
        // Give it time to put up a save dialog and for the user to answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.quitPhase(for: app.pid) == .asked else { return }
            if NSRunningApplication(processIdentifier: app.pid)?.isTerminated ?? true {
                self.quitPhases[app.pid] = .gone
            } else {
                self.quitPhases[app.pid] = .needsForce
            }
        }
    }

    func forceQuit(_ app: AppUsage) {
        precondition(Thread.isMainThread)
        guard quitPhase(for: app.pid) == .needsForce else { return }
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            quitPhases[app.pid] = .gone
            return
        }
        quitPhases[app.pid] = .forced
        _ = running.forceTerminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if NSRunningApplication(processIdentifier: app.pid)?.isTerminated ?? true {
                self.quitPhases[app.pid] = .gone
            } else {
                self.quitPhases[app.pid] = .failed("не отвечает")
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
