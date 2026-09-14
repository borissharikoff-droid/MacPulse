import AppKit

// =====================================================================
// Global + local event monitor pair.
//
// Why both, always: `addGlobalMonitorForEvents` does NOT fire while our
// own app is frontmost, and `addLocalMonitorForEvents` does NOT fire
// while it isn't. Install only one and the island goes dead in exactly
// one of the two situations — and since clicking the island delivers the
// event to us, "only global" means the island stops responding the
// moment you touch it.
//
// The local closure MUST return the event or we swallow it for our own
// app (which would kill every button inside the island).
//
// Mouse-event monitors need no Accessibility permission; only keyboard
// monitors do. MacPulse asks for no TCC permission at all.
// =====================================================================

final class EventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit { stop() }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
            return event          // never swallow
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
