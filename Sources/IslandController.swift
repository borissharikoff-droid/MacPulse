import AppKit
import SwiftUI

// =====================================================================
// Owns the island: the panel, the geometry, the event monitors and the
// closed -> popping -> opened state machine.
//
// Main thread only.
//
// NOTHING IN THIS FILE EVER ACTIVATES THE APP. There is no
// NSApp.activate, no makeKeyAndOrderFront, and no timer that re-orders
// the window. NotchDrop does the last two and that is exactly why it
// fights the frontmost app.
// =====================================================================

final class IslandController {
    private let model = IslandModel()
    private var panel: IslandPanel?
    private var hostingView: NSHostingView<IslandView>?

    private var geometry: NotchGeometry?
    /// `auxiliaryTopLeftArea` can return nil transiently right after wake
    /// or a display reconfiguration. Letting that nil through collapses
    /// the island to the fallback width and makes it visibly jump, so the
    /// last good metrics per display are kept and reused.
    private var lastGoodMetrics: [String: NotchMetrics] = [:]

    // Event monitors
    private var moveMonitor: EventMonitor?
    private var clickMonitor: EventMonitor?

    // Dwell / debounce. DispatchWorkItem on the main QUEUE, not a Timer:
    // a Timer scheduled in the default run-loop mode stops firing while a
    // menu is tracking or a window is being dragged, and the island would
    // visibly stall. Main-queue dispatch is drained in every mode.
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    /// ~0.3 s. Without a dwell, moving the cursor toward a menu bar item
    /// triggers a full expand and the user hates you.
    private let hoverDwell: TimeInterval = 0.30
    /// Shorter on the way out so crossing a 2pt gap does not flicker.
    private let closeDebounce: TimeInterval = 0.22

    private var screenSnapshot: [(uuid: String?, frame: CGRect)] = []
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start() {
        model.start()
        rebuildForCurrentScreens()
        installNotifications()
        startMonitors()

        // Hidden diagnostic, same convention as `--probe` in main.swift:
        // pins the panel open at launch so the expanded layout can be
        // screenshotted without a human hovering. Never reachable from the
        // UI, and does nothing unless the flag is on the command line.
        if CommandLine.arguments.contains("--expand-island") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.model.setPinned(true)
                self.expand()
            }
        }
    }

    func stop() {
        stopMonitors()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        model.stop()
        panel?.orderOut(nil)
        panel = nil
    }

    /// The menu's "показать/скрыть" entry point.
    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible {
            panel.orderFrontRegardless()
            // restartMonitors, not startMonitors: hiding never restores
            // ignoresMouseEvents, so if the pointer happened to be over the
            // island when it was hidden, the panel comes back still disarmed
            // and swallows clicks in the notch strip until the next mouse
            // move. Re-seeding from the pointer's real position closes that.
            restartMonitors()
        } else {
            collapse(animated: false)
            panel.orderOut(nil)
            stopMonitors()
        }
    }

    // MARK: - Window construction

    private func rebuildForCurrentScreens() {
        guard let screen = NSScreen.mp_islandScreen else { return }

        var metrics = NotchMetrics.detect(screen: screen)
        let uuid = screen.mp_displayUUID
        if let uuid {
            if metrics.hasPhysicalNotch {
                lastGoodMetrics[uuid] = metrics
            } else if let cached = lastGoodMetrics[uuid], cached.hasPhysicalNotch {
                // Transient nil right after wake — keep the known geometry.
                metrics = cached
            }
        }

        let geo = NotchGeometry(screen: screen, metrics: metrics)
        geometry = geo
        model.setGeometry(notchSize: metrics.notchSize, hasPhysicalNotch: metrics.hasPhysicalNotch)

        // The window frame is CONSTANT for the lifetime of this screen
        // configuration: full screen width by a height tall enough for the
        // largest expanded state plus room for the SwiftUI shadow. Only
        // the content inside animates.
        let height = IslandView.expandedHeight + 60
        let frame = NSRect(x: screen.frame.minX,
                           y: screen.frame.maxY - geo.topInset - height,
                           width: screen.frame.width,
                           height: height)

        if let panel, panel.frame != frame {
            panel.setFrame(frame, display: true)
        }

        if panel == nil {
            let p = IslandPanel(contentRect: frame)
            let root = IslandView(model: model)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: frame.size)
            host.autoresizingMask = [.width, .height]
            p.contentView = host
            // Re-assert after installing content: NSHostingView can resize
            // its window out from under you.
            p.setFrame(frame, display: true)
            // orderFrontRegardless, never makeKeyAndOrderFront.
            p.orderFrontRegardless()
            panel = p
            hostingView = host
        } else {
            hostingView?.frame = NSRect(origin: .zero, size: frame.size)
            panel?.orderFrontRegardless()
        }

        screenSnapshot = NSScreen.screens.map { ($0.mp_displayUUID, $0.frame) }

        // Seed the state machine: the pointer may already be sitting over
        // the notch, and it will not emit a .mouseMoved until it moves.
        handlePointer(NSEvent.mouseLocation)
    }

    // MARK: - Sizing

    private var collapsedBodySize: CGSize {
        let n = model.notchSize
        return CGSize(width: n.width + IslandView.collapsedSideWidth * 2 + 6 * 2,
                      height: n.height)
    }

    private var poppingBodySize: CGSize {
        var s = collapsedBodySize
        s.height += 3
        return s
    }

    private var openedBodySize: CGSize {
        CGSize(width: IslandView.expandedContentWidth + 19 * 2,
               height: IslandView.expandedHeight)
    }

    private var activeHitRect: CGRect {
        guard let geometry else { return .null }
        switch model.status {
        case .opened: return geometry.hitRect(size: openedBodySize)
        case .popping: return geometry.hitRect(size: poppingBodySize)
        case .closed: return geometry.hitRect(size: collapsedBodySize)
        }
    }

    private var collapsedHitRect: CGRect {
        geometry?.hitRect(size: collapsedBodySize) ?? .null
    }

    /// The strip row at the very top of the opened island — clicking there
    /// is "toggle the pin", as opposed to clicking into the dashboard.
    private var stripHitRect: CGRect {
        guard let geometry else { return .null }
        let opened = geometry.islandRect(size: openedBodySize)
        return CGRect(x: opened.minX,
                      y: opened.maxY - model.notchSize.height,
                      width: opened.width,
                      height: model.notchSize.height)
    }

    // MARK: - Monitors

    private func startMonitors() {
        stopMonitors()
        moveMonitor = EventMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handlePointer(NSEvent.mouseLocation)
        }
        clickMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleClick(NSEvent.mouseLocation)
        }
        moveMonitor?.start()
        clickMonitor?.start()
    }

    private func stopMonitors() {
        moveMonitor?.stop(); moveMonitor = nil
        clickMonitor?.stop(); clickMonitor = nil
    }

    /// Global monitors silently die across sleep, fast user switching and
    /// screen lock. Reinstall and re-seed.
    private func restartMonitors() {
        startMonitors()
        handlePointer(NSEvent.mouseLocation)
    }

    // MARK: - Pointer

    private func handlePointer(_ point: CGPoint) {
        guard let panel, geometry != nil else { return }

        let inActive = activeHitRect.contains(point)

        // ARMING. This must be driven from mouse-MOVED, never from
        // mouse-DOWN: by the time a mouse-down handler runs, the menu bar
        // already received the click. The window has to be armed on the
        // preceding move.
        let shouldIgnore = !inActive
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }

        let inCollapsed = collapsedHitRect.contains(point)

        switch model.status {
        case .closed:
            if inCollapsed {
                setStatus(.popping)
                scheduleOpen()
            }
        case .popping:
            if !inCollapsed {
                cancelOpen()
                setStatus(.closed)
            }
        case .opened:
            if inActive {
                cancelClose()
            } else if !model.isPinned {
                scheduleClose()
            }
        }
    }

    private func handleClick(_ point: CGPoint) {
        guard geometry != nil else { return }

        if model.status == .opened {
            if stripHitRect.contains(point) {
                // Click on the strip toggles the pin, and unpinning closes.
                if model.isPinned {
                    model.setPinned(false)
                    collapse(animated: true)
                } else {
                    model.setPinned(true)
                }
            } else if activeHitRect.contains(point) {
                // Click inside the dashboard: pin it, so the user can move
                // the pointer to a button without the panel folding away.
                model.setPinned(true)
                cancelClose()
            } else {
                // Click anywhere else dismisses. We never consumed that
                // click — the panel was disarmed, so it went to whatever
                // is underneath, which is what the user wanted.
                model.setPinned(false)
                collapse(animated: true)
            }
            return
        }

        if collapsedHitRect.contains(point) {
            cancelOpen()
            model.setPinned(true)
            expand()
        }
    }

    // MARK: - State transitions

    private func setStatus(_ status: IslandStatus) {
        guard model.status != status else { return }
        // boring.notch's pair: a livelier spring on the way out, a
        // critically damped one on the way back. Bouncing on collapse
        // reads as broken.
        let animation: Animation = status == .opened
            ? .spring(response: 0.42, dampingFraction: 0.80, blendDuration: 0)
            : .spring(response: 0.45, dampingFraction: 1.00, blendDuration: 0)
        withAnimation(animation) {
            model.setStatus(status)
        }
    }

    private func expand() {
        cancelClose()
        guard model.status != .opened else { return }
        setStatus(.opened)
        // Fresh numbers the instant the panel is looked at.
        MetricsEngine.shared.refreshNow()
        // One light tick on the open transition only. Deliberately NOT on
        // .popping: the pointer crosses the notch region dozens of times an
        // hour on the way to the menu bar, and buzzing every time is
        // obnoxious.
        if NSEvent.pressedMouseButtons == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }
    }

    private func collapse(animated: Bool) {
        cancelOpen(); cancelClose()
        model.setPinned(false)
        if animated {
            setStatus(.closed)
        } else {
            model.setStatus(.closed)
        }
    }

    private func scheduleOpen() {
        cancelOpen()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.status == .popping else { return }
            self.expand()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDwell, execute: work)
    }

    private func cancelOpen() {
        openWork?.cancel(); openWork = nil
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard self.model.status == .opened, !self.model.isPinned else { return }
            guard !self.activeHitRect.contains(NSEvent.mouseLocation) else { return }
            self.setStatus(.closed)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDebounce, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel(); closeWork = nil
    }

    // MARK: - Notifications

    private func installNotifications() {
        let nc = NotificationCenter.default
        let wc = NSWorkspace.shared.notificationCenter

        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenParametersChanged()
        })

        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartMonitors()
        })

        observers.append(wc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartMonitors()
            self?.rebuildForCurrentScreens()
        })

        observers.append(wc.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartMonitors()
        })

        observers.append(wc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let panel = self?.panel, !panel.isOnActiveSpace else { return }
            // Ordering front a window the server already believes is
            // visible on another Space is a no-op, so clear the stale
            // ordering first. And do NOT activate: the user just
            // switched Space and the app there keeps focus.
            if panel.isVisible { panel.orderOut(nil) }
            panel.orderFrontRegardless()
        })
    }

    /// didChangeScreenParameters fires repeatedly on wake, dock and
    /// resolution change. Acting on every one causes window thrash, so
    /// diff the actual (uuid, frame) set first.
    private func screenParametersChanged() {
        let current = NSScreen.screens.map { (uuid: $0.mp_displayUUID, frame: $0.frame) }
        // Compared as sorted strings rather than as Set<CGRect>: CGRect's
        // Hashable conformance is macOS 15+, and this has to build against
        // a 13.0 deployment target.
        let changed = current.count != screenSnapshot.count
            || fingerprint(current) != fingerprint(screenSnapshot)
        guard changed else { return }
        collapse(animated: false)
        rebuildForCurrentScreens()
        restartMonitors()
    }

    private func fingerprint(_ screens: [(uuid: String?, frame: CGRect)]) -> [String] {
        screens.map { s in
            String(format: "%@|%.1f,%.1f,%.1f,%.1f",
                   s.uuid ?? "?",
                   s.frame.origin.x, s.frame.origin.y, s.frame.width, s.frame.height)
        }.sorted()
    }
}
