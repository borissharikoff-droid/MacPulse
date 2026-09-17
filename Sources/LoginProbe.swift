import AppKit
import Foundation
import ServiceManagement

// =====================================================================
// «Запускать при входе» — the switch, exercised for real.
//
// THE QUESTION. The menu item cannot be clicked from here, and the last
// version of this feature was wrong in a way that clicking would not
// have shown either: it set its own checkmark and swallowed the error,
// so it looked identical whether it worked or not. What can be measured
// is the thing underneath — what macOS says this copy's status is, and
// what it says AFTER a real register/unregister.
//
//   ... --login-probe              report only, changes nothing
//   ... --login-probe roundtrip    register, read back, restore
//
// `roundtrip` leaves the setting exactly as it found it, and says so
// per step. It is the only way to prove the switch moves; a status read
// on its own proves only that the API answers.
// =====================================================================

enum LoginProbe {

    static func run(arguments: [String]) -> Never {
        print("=== MacPulse --login-probe ===")
        print("bundle   \(Bundle.main.bundlePath)")
        print("id       \(Bundle.main.bundleIdentifier ?? "(none!)")")
        // Where the app sits decides whether this feature can work at
        // all, so it is the first line and not a footnote.
        print("location \(locationVerdict())")
        print("")

        print("--- what macOS says right now ---------------------------------")
        report(LaunchAtLogin.state, raw: SMAppService.mainApp.status)

        guard arguments.contains("roundtrip") else {
            print("")
            print("Read-only. Pass `roundtrip` to register and unregister for real.")
            exit(0)
        }

        let original = LaunchAtLogin.state
        print("")
        print("--- roundtrip -------------------------------------------------")
        print("Original state will be restored at the end.")
        print("")

        // Drive it through whichever half is not already true, so the
        // probe measures a real transition either way.
        let first = original != .on
        print("  set(\(first)) ...")
        let afterFirst = LaunchAtLogin.set(first)
        report(afterFirst, raw: SMAppService.mainApp.status, indent: "    ")
        let moved = afterFirst != original
        print("    -> " + (moved ? "the switch MOVED" : "*** no change — the switch did nothing"))

        // Restored against STATE, not against the raw status, and the
        // difference is real: a machine that has never registered this
        // bundle id reports `notFound`, and no unregister will ever put
        // that back — once a record exists, off reports as
        // `notRegistered`. Both mean off. Comparing raw values here
        // would fail a roundtrip that did everything right.
        print("")
        print("  restoring to \(describe(original)) ...")
        let restored = LaunchAtLogin.set(original == .on)
        report(restored, raw: SMAppService.mainApp.status, indent: "    ")
        let backAsFound = restored == original
        print("    -> " + (backAsFound
                           ? "back as found"
                           : "*** LEFT AS \(describe(restored)), NOT \(describe(original))"))

        print("")
        print("=== done ===")
        // A switch that will not move, or a probe that does not put the
        // machine back, are both defects with an answer that does not
        // depend on this Mac.
        exit(moved && backAsFound ? 0 : 1)
    }

    private static func report(_ state: LaunchAtLogin.State,
                               raw: SMAppService.Status,
                               indent: String = "  ") {
        print(indent + "SMAppService.status  \(rawName(raw)) (\(raw.rawValue))")
        print(indent + "LaunchAtLogin.state  \(describe(state))")
        print(indent + "menu checkmark       " + (state.isChecked ? "on" : "off"))
    }

    private static func describe(_ state: LaunchAtLogin.State) -> String {
        switch state {
        case .on:                  return "on"
        case .off:                 return "off"
        case .needsApproval:       return "needsApproval (registered, switched off by the user)"
        case .unavailable(let why): return "unavailable — \(why)"
        }
    }

    private static func rawName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown"
        }
    }

    /// The single most common reason this feature fails for somebody who
    /// just downloaded the app.
    private static func locationVerdict() -> String {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "*** App Translocation — running from a temporary read-only copy. "
                 + "Login items cannot point here."
        }
        if path.hasPrefix("/Applications/") { return "/Applications — correct" }
        if path.hasPrefix(NSHomeDirectory() + "/Applications/") { return "~/Applications — fine" }
        return "*** outside Applications — macOS will usually refuse to register this"
    }
}
