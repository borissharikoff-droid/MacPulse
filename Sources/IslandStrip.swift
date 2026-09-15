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
// WHAT IS IN THE TRAILING WING NOW. Two things, and they are not equals:
//
//   * the PRIVACY RAIL, pinned at the far right, which nothing may
//     preempt and which is sized to fit inside the resting 26 pt so it
//     never has to ask for width at all;
//   * ONE live slot to its left, whatever `IslandModel`'s arbiter picked
//     — print progress this phase — which gets whatever is left.
//
// The arithmetic for "whatever is left" is in
// `IslandMetrics.trailingLayout` and nowhere else, for the same reason
// `collapsedPlate` is: two copies of a layout rule is how the drawn thing
// and the hit-tested thing drift apart.
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
    /// What the wing is ACTUALLY this wide right now. Collapsed that is
    /// `model.trailingWingWidth`; open it is half of whatever is left of
    /// the 560 pt panel. Passed in rather than read here so there is one
    /// answer, the one `IslandView` also used to lay out the row.
    let availableWidth: CGFloat

    private var layout: IslandMetrics.TrailingLayout {
        IslandMetrics.trailingLayout(wing: availableWidth,
                                     privacyVisible: !model.privacy.isQuiet,
                                     slotVisible: model.printer != nil)
    }

    var body: some View {
        let l = layout
        HStack(spacing: 0) {
            Spacer(minLength: 0).frame(width: IslandMetrics.slotLeadingGap)

            if l.slotWidth > 0, let reading = model.printer {
                PrintStripSlot(reading: reading, showsText: l.showsSlotText)
                    .frame(width: l.slotWidth, alignment: .leading)
            }

            Spacer(minLength: 0)

            // LAST, AND ALWAYS. Drawn after the Spacer so it is pinned to
            // the far right whatever else is in the wing.
            if l.railWidth > 0 {
                IslandPrivacyRail(state: model.privacy)
                    .frame(width: l.railWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
