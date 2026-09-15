import SwiftUI

// =====================================================================
// The privacy rail: two dots at the far right of the trailing wing.
//
// IT IS PINNED AND IT IS NEVER PREEMPTED. Everything else on the
// collapsed island competes for the live slot and can lose. This does
// not: it is sized (23 pt) to fit inside the RESTING 26 pt wing, so it
// never asks anyone for space and can never be told no. See
// IslandMetrics.privacyRailWidth — if you widen the dots, re-check that
// sum, because the failure mode is a safety signal that silently stops
// being drawn on a machine where the wing could not grow.
//
// COLOURS ARE THE SYSTEM'S, ON PURPOSE. macOS itself shows an ORANGE dot for
// the microphone and a GREEN dot for the camera in its own menu bar
// indicator. Matching them means the user does not have to learn a second
// vocabulary for the same fact, and a mismatch would be worse than
// useless on a privacy signal. The arch spike's "mic red / camera green"
// is overridden here for exactly that reason.
//
// WHAT THE TOOLTIPS ARE ALLOWED TO CLAIM — this is not a style question.
//
//   MIC: the underlying signal, kAudioProcessPropertyIsRunningInput,
//   means "this process has an ACTIVE INPUT STREAM". It does not mean
//   "this process is recording you this instant": an app that holds the
//   input device open while muted lights this dot. So the tooltip says
//   «держит микрофон» — holds the microphone — and never «записывает».
//   Erring toward "something has the mic" is the safe direction; the
//   failure that matters is the other one.
//
//   CAMERA: there is NO unprivileged way to name the app holding a
//   camera on macOS 26 (no per-process CoreMediaIO API; no /dev/video*
//   for lsof; the system log redacts every identifying field). So the
//   camera tooltip names the DEVICE and says outright that the app is
//   unknown. It must never guess.
// =====================================================================

struct IslandPrivacyRail: View {
    let state: PrivacyState

    private var size: CGFloat { IslandMetrics.privacyDotSize }

    var body: some View {
        HStack(spacing: IslandMetrics.privacyDotGap) {
            Spacer(minLength: 0)
            if state.micActive {
                SensorDot(color: IslandPalette.micInUse)
                    .help(Self.micTooltip(state))
            }
            if state.cameraActive {
                SensorDot(color: IslandPalette.cameraInUse)
                    .help(Self.cameraTooltip(state))
            }
        }
        .padding(.trailing, IslandMetrics.privacyRailPadding)
        .frame(maxHeight: .infinity)
    }

    static func micTooltip(_ state: PrivacyState) -> String {
        guard state.micActive else { return "" }
        if state.micApps.isEmpty {
            // The device-level signal fired but no process claimed an
            // input stream. Say so rather than invent a name.
            return "Микрофон занят (приложение определить не удалось)"
        }
        return "Микрофон держит: " + state.micApps.joined(separator: ", ")
    }

    static func cameraTooltip(_ state: PrivacyState) -> String {
        guard state.cameraActive else { return "" }
        let devices = state.cameraDevices.isEmpty
            ? "камера"
            : state.cameraDevices.joined(separator: ", ")
        return "Камера включена: \(devices). Какое приложение — системе "
            + "без спец. прав не узнать."
    }
}

private struct SensorDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: IslandMetrics.privacyDotSize, height: IslandMetrics.privacyDotSize)
            // A faint halo so the dot reads against the black plate at
            // 6 pt without being made bigger.
            .overlay(Circle().stroke(color.opacity(0.28), lineWidth: 2.5))
    }
}

// MARK: - Panel footer line

/// The same facts in words, for the bottom of the expanded panel. The
/// collapsed dot is a signal; this is the explanation, and it is the only
/// place the app names the apps in plain text.
enum PrivacyFooter {
    static func line(_ state: PrivacyState) -> String? {
        var parts: [String] = []
        if state.micActive {
            parts.append(state.micApps.isEmpty
                ? "Микрофон занят"
                : "Микрофон: " + state.micApps.joined(separator: ", "))
        }
        if state.cameraActive {
            parts.append("Камера включена")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
