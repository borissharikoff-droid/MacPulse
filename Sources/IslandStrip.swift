import SwiftUI

// =====================================================================
// The collapsed strip: the two wings that straddle the camera housing.
//
// The housing is OPAQUE GLASS. Anything drawn in the middle
// `notchSize.width` points is invisible, so the readout lives entirely in
// the wings and the centre column is deliberately empty.
//
// THE TWO WINGS ARE NOT THE SAME KIND OF THING.
//
// LEADING (left of the housing) is frozen at 26 pt for good. Measured:
// the collapsed plate already starts at x=611.5 and the frontmost app's
// menus end at x=612 (zen, the longest menu bar on this machine). There
// is 0.5 pt of clearance. It holds the pressure dot and it will never
// hold anything else, because there is nowhere for it to go.
//
// TRAILING (right of the housing) has 172.5 pt before the first menu bar
// extra and is the only expandable surface the collapsed island has. It
// rests at 26 pt and grows on request up to the runtime bound in
// IslandMetrics.
//
// AT THIS PHASE THE TRAILING WING IS EMPTY AND RESTING. The mechanism
// — dynamic width, hit rect that follows it, runtime bound against our
// own status item — is what is built here; filling it is the next
// agent's job. `IslandModel.requestTrailingWing` is the entry point, and
// `IslandTrailingWing` below is where the content goes.
// =====================================================================

struct PressureDot: View {
    let level: MemoryPressureLevel?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(IslandPalette.color(for: level))
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(IslandPalette.color(for: level).opacity(0.35), lineWidth: size * 0.5)
                    .opacity(level == .critical ? 1 : 0)
            )
    }
}

/// LEFT of the camera housing: the kernel's pressure verdict as a single
/// coloured dot. That is the whole collapsed readout.
///
/// The island can never be narrower than the physical notch (183 pt here),
/// so the only width available to trade away is the wings. A sparkline and
/// the top app's name used to live here and cost 208 pt; a dot costs 26.
/// Everything that was there is one hover away in the panel.
struct IslandLeadingWing: View {
    let pressure: MemoryPressureLevel?

    var body: some View {
        PressureDot(level: pressure, size: 8)
            .padding(.trailing, 9)
    }
}

/// RIGHT of the camera housing. Empty at rest.
///
/// WHEN YOU FILL THIS: the width is not yours to choose from in here.
/// Call `model.requestTrailingWing(w)` — it clamps against the status
/// item — and lay out to `model.trailingWingWidth`, which is what the
/// controller's hit rect is derived from. Drawing wider than the
/// published width puts pixels outside the hit rect, where clicks go to
/// the menu bar instead of to you.
///
/// Also call `model.setStripSlotSection(...)` so that clicking the strip
/// opens the panel on the matching tab.
struct IslandTrailingWing: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        // Nothing yet, by design. The wing is at its resting 26 pt and the
        // island looks exactly as it did before it became asymmetric.
        Color.clear
    }
}
