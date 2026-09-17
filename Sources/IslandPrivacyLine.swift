// =====================================================================
// The privacy readout. ONE LINE, IN THE PANEL FOOTER, AND NOTHING ELSE.
//
// WHAT USED TO BE HERE, AND WHY IT IS NOT. This file drew two 6 pt dots
// pinned at the far right of the collapsed island's trailing wing —
// orange for the microphone, green for the camera, borrowed from the
// system's own indicator colours so the user would not have to learn a
// second vocabulary.
//
// Borrowing the system's vocabulary was the tell. macOS ALREADY DRAWS
// THAT INDICATOR, in its own menu bar, a few points to the right of where
// ours sat: the island's right edge is at x=858.5 on this machine and the
// system's orange mic dot appears in the extras region beyond it. Two dots
// of the same colour saying the same fact about the same microphone, on
// the same 24 pt strip of screen. The island's job is what the system does
// NOT say; restating what it does say is worse than silence, because it
// teaches the user that our dots are noise.
//
// That argument was already written down in this codebase — it is why
// `IslandModel.updateTrailingSlot` refuses the collapsed slot to the
// memory-pressure notifier, which speaks through Notification Centre.
// This is the same rule, applied to the same kind of duplication.
//
// WHAT THE SYSTEM DOES NOT SAY, AND WE DO: WHICH APP. macOS's indicator
// names nobody. `PrivacyWatcher` reads
// kAudioHardwarePropertyProcessObjectList and comes back with "zen" or
// "Telegram", with no entitlement and no TCC grant, and THAT is worth a
// pixel. It gets a clause in the 14 pt footer of a panel the user opened
// on purpose — see `IslandModel.refreshFooter`, where it is deliberately
// placed FIRST.
//
// The watcher itself is untouched: it still runs, still publishes on a
// real sensor transition, and still costs nothing at idle. Only the dot
// left. See FeaturePrivacy.swift.
//
// WHAT THE LINE IS ALLOWED TO CLAIM — this is not a style question.
//
//   MIC: the underlying signal, kAudioProcessPropertyIsRunningInput,
//   means "this process has an ACTIVE INPUT STREAM". It does not mean
//   "this process is recording you this instant": an app that holds the
//   input device open while muted lights it. So the line says «Микрофон:
//   <app>» — who is holding it — and never «записывает». Erring toward
//   "something has the mic" is the safe direction; the failure that
//   matters is the other one.
//
//   CAMERA: there is NO unprivileged way to name the app holding a camera
//   on macOS 26 (no per-process CoreMediaIO API; no /dev/video* for lsof;
//   the system log redacts every identifying field). So the camera clause
//   names no app at all. It must never guess.
// =====================================================================

/// The privacy clause for the bottom of the expanded panel.
///
/// The only place this app puts these app names on screen, and it is one
/// short clause because it shares a 14 pt line with every other live
/// section's summary.
enum PrivacyFooter {
    static func line(_ state: PrivacyState) -> String? {
        var parts: [String] = []
        if state.micActive {
            parts.append(state.micApps.isEmpty
                ? tr("Микрофон занят", "Microphone in use")
                : tr("Микрофон: ", "Microphone: ") + state.micApps.joined(separator: ", "))
        }
        if state.cameraActive {
            parts.append(tr("Камера включена", "Camera on"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
