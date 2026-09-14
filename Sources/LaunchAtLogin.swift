import Foundation
import ServiceManagement

/// "Start at login" via SMAppService (macOS 13+) — the modern replacement for
/// hand-rolled LaunchAgent plists. Critically, `register()` only schedules the
/// app for the *next* login; unlike a LaunchAgent with `RunAtLoad: true`
/// loaded via `launchctl load`, it does not also launch a second copy right
/// now, which is exactly the "toggling this launches a duplicate" bug a
/// manual plist has.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    guard SMAppService.mainApp.status != .enabled else { return }
                    try SMAppService.mainApp.register()
                } else {
                    guard SMAppService.mainApp.status == .enabled else { return }
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MacPulse: LaunchAtLogin toggle failed: \(error)")
            }
        }
    }
}
