import AppKit
import Foundation
import ServiceManagement

// =====================================================================
// «Запускать при входе» — and the checkmark tells the truth about it.
//
// SMAppService (macOS 13+) replaces the hand-rolled LaunchAgent plist,
// and it fixes one bug for free: `register()` only schedules the app for
// the NEXT login. A plist with `RunAtLoad: true` loaded via `launchctl
// load` ALSO starts a second copy immediately, so toggling the switch
// gave you two islands.
//
// WHAT THIS FILE IS REALLY FOR. The first version was a `var isEnabled`
// whose setter swallowed its own errors into NSLog, and the menu item
// set its checkmark to whatever the user had just asked for. Those two
// things together make a switch that cannot fail in front of the user
// and can fail behind them:
//
//   * `register()` throws — an app still in ~/Downloads under quarantine
//     is the common one — and the checkmark goes on anyway. The user
//     reboots, no island, and nothing on screen ever admitted it.
//   * macOS answers `.requiresApproval`: registered, but switched off
//     under Login Items. `status == .enabled` is false, so the old
//     getter called that "off", and the next click called `register()`
//     on something already registered, which changes nothing. The
//     switch does nothing, forever, with no explanation.
//   * The user turns it off in System Settings. Our checkmark was read
//     once when the menu was built and stays on for the life of the
//     process.
//
// So: no setter. `state` asks macOS every time, `set(_:)` returns what
// macOS says AFTER the attempt, and the caller draws that. The switch
// is now allowed to refuse.
// =====================================================================

enum LaunchAtLogin {

    /// What macOS says right now — never what the user last asked for.
    enum State: Equatable {
        /// Registered and switched on. It will start at the next login.
        case on
        /// Not registered. Clicking will register it.
        case off
        /// Registered, but the user (or a policy) has it switched off in
        /// System Settings → «Объекты входа». We cannot switch it back on
        /// from here — only the user can, in that pane.
        case needsApproval
        /// The attempt itself was refused. The reason is worth showing:
        /// it is nearly always "the app is not where it will live" —
        /// still in ~/Downloads, still quarantined, or running out of a
        /// DMG under App Translocation.
        ///
        /// Only ever produced by `set(_:)`, never by reading `state`.
        /// A status read cannot tell a refusal from a deliberate off.
        case unavailable(String)

        /// Only `.on` draws a checkmark. `.needsApproval` deliberately
        /// does not: the app will NOT start at login in that state, and a
        /// checkmark would say it will.
        var isChecked: Bool { self == .on }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .on
        case .requiresApproval: return .needsApproval

        // BOTH of these are off, and the difference between them is not
        // something to show anybody.
        //
        // Apple documents `.notFound` as "an error occurred and the
        // framework couldn't find this service", which reads like a
        // fault worth reporting. It is not. `--login-probe roundtrip`
        // measured what actually happens on a clean machine:
        //
        //     notFound (3)  -- register() -->  enabled (1)
        //     enabled  (1)  -- unregister() -> notRegistered (0)
        //
        // `.notFound` is simply the state of a bundle id macOS has no
        // record of yet — every user's FIRST look at this menu — and
        // registering from it works. Only after the first round trip
        // does a record exist and "off" start reporting as
        // `.notRegistered`. Calling `.notFound` an error would have put
        // a red herring in front of every new user, and did, until the
        // probe caught it.
        case .notRegistered, .notFound: return .off

        @unknown default: return .off
        }
    }

    /// Ask for `wanted`, then report what macOS actually did.
    ///
    /// The return value is the point. Every caller draws THIS, not
    /// `wanted` — which is the whole difference between a switch that
    /// reports and one that decorates.
    @discardableResult
    static func set(_ wanted: Bool) -> State {
        let before = state

        // Nothing to do, and calling through anyway would throw
        // `kSMErrorAlreadyRegistered`, which reads as a failure.
        if wanted && before == .on { return before }
        if !wanted && before == .off { return before }

        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                // `unregister()` is also the way OUT of `.needsApproval`:
                // it clears the registration so that the next click makes
                // a fresh one, and a fresh one prompts again.
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacPulse: launch-at-login \(wanted ? "register" : "unregister") failed: \(error)")
            // Ask again rather than assuming the throw means nothing
            // happened — `register()` can throw AFTER registering, with
            // approval pending.
            let after = state
            if after != before { return after }
            return .unavailable(reason(for: error))
        }
        return state
    }

    /// The pane where `.needsApproval` is undone. No API can flip that
    /// switch for the user, by design, so this is the whole of what we
    /// can do about it.
    @discardableResult
    static func openLoginItemsSettings() -> Bool {
        // Ventura+ identifier for the Login Items pane. If it ever stops
        // resolving, macOS opens System Settings at its front page, which
        // is still closer than nothing.
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// A line the user can act on, not an NSError description.
    ///
    /// The common failure has one cause and one fix, and "The operation
    /// couldn’t be completed. (SMAppServiceErrorDomain error 1.)" names
    /// neither.
    private static func reason(for error: Error) -> String {
        let bundlePath = Bundle.main.bundlePath
        // App Translocation. Launched straight out of a quarantined DMG
        // or zip, macOS runs the app from a random read-only mount under
        // /private/var/folders, and `register()` cannot point a login
        // item at a path that will not exist next week. This is what a
        // stranger who double-clicks inside the DMG hits, so it is worth
        // naming exactly rather than reporting as a folder they have
        // never heard of.
        if bundlePath.contains("/AppTranslocation/") {
            return "macOS открыл MacPulse из временной копии — перетащите "
                 + "приложение в «Программы» и запустите оттуда"
        }
        let installed = bundlePath.hasPrefix("/Applications/")
                     || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if !installed {
            return "перенесите MacPulse в «Программы» — для копии в «"
                 + niceFolder(bundlePath) + "» автозапуск не регистрируется"
        }
        let ns = error as NSError
        return "macOS отказал (\(ns.domain) \(ns.code))"
    }

    private static func niceFolder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}
