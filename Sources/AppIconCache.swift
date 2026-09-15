import AppKit

// =====================================================================
// App icons, by pid, fetched at most once each.
//
// WHY THIS EXISTS. `AppRow.body` used to call
// `NSRunningApplication(processIdentifier:)?.icon` inline. SwiftUI
// evaluates a body whenever anything it reads changes, which at a 1 Hz
// tick was five of those lookups a second forever. Measured (probe_icon):
// 746 us for five rows uncached, 0.0 us cached. That is ~0.075% of one
// core burned on re-fetching five icons that had not changed since the
// last time — and the lookup is a round trip to the launch services
// database, not a dictionary read.
//
// PID REUSE is the reason this is not a bare [pid: NSImage]. The kernel
// recycles pids, and an island that shows Telegram's icon next to
// Safari's name because pid 4711 was reused is worse than showing no icon
// at all. Every entry therefore records the bundle identifier it was
// fetched for, and a lookup whose caller-supplied bundle id disagrees is
// treated as a miss.
//
// A MISS IS CACHED TOO. Not every row is an NSRunningApplication — daemons
// and helpers are not — and without a negative entry those rows would pay
// the full lookup on every single evaluation, which is the exact cost
// this file exists to remove.
//
// Main thread only: NSRunningApplication and NSWorkspace are.
// =====================================================================

final class AppIconCache {

    private struct Entry {
        /// nil means "looked it up, there is no icon". A cached negative.
        let icon: NSImage?
        /// What the row claimed this pid was when the icon was fetched.
        let bundleIdentifier: String?
    }

    private var entries: [pid_t: Entry] = [:]
    private var terminationObserver: NSObjectProtocol?

    init() {
        precondition(Thread.isMainThread)
        // Push, not poll: the moment an app dies its entry is wrong, and
        // NSWorkspace already tells us for free.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.entries.removeValue(forKey: app.processIdentifier)
        }
    }

    deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    /// The icon for a row, fetching it at most once per (pid, bundle id).
    ///
    /// NEVER call this from a SwiftUI `body`. Call it while building the
    /// published row state, which happens only when the row set actually
    /// changed and only while the panel is open.
    func icon(pid: pid_t, bundleIdentifier: String?, isApplication: Bool) -> NSImage? {
        precondition(Thread.isMainThread)
        if let hit = entries[pid], hit.bundleIdentifier == bundleIdentifier {
            return hit.icon
        }
        // A row we already know is not an NSRunningApplication never gets
        // an icon, so do not pay the lookup to find that out again.
        let icon = isApplication
            ? NSRunningApplication(processIdentifier: pid)?.icon
            : nil
        entries[pid] = Entry(icon: icon, bundleIdentifier: bundleIdentifier)
        return icon
    }

    /// Drop everything that is not in `pids`. Called when the visible row
    /// set changes, so the cache stays the size of the panel rather than
    /// the size of the process table.
    func retainOnly(_ pids: Set<pid_t>) {
        precondition(Thread.isMainThread)
        guard entries.count > pids.count else { return }
        entries = entries.filter { pids.contains($0.key) }
    }
}
