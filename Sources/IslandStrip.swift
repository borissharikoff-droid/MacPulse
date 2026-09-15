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
// TRAILING (right of the housing) is the only expandable surface the
// collapsed island has. It rests at 26 pt and grows on request up to the
// bound in IslandMetrics — which is derived from our OWN status item and
// from the widest row the wing can draw, never from where some other
// app's menu bar extra was once measured to be.
//
// WHAT IS IN THE TRAILING WING NOW. One thing: the live slot the arbiter
// in `IslandModel.updateTrailingSlot` picked — print progress, or the
// meeting countdown.
//
// THE PRIVACY RAIL IS NOT HERE ANY MORE. It was two 6 pt dots pinned at
// the far right, and it is gone because macOS already draws an orange
// microphone indicator in its own menu bar, a few points to the right of
// where ours sat. Ours restated it. That is the same argument written
// beside `IslandModel.updateTrailingSlot` for keeping the pressure
// notifier out of the wing, applied consistently.
//
// The part macOS does NOT provide — WHICH app is holding the microphone —
// is still said, in words, in the panel footer. `PrivacyWatcher` runs and
// publishes exactly as before; only the 6 pt dot left. See
// IslandPrivacyLine.swift.
//
// SO THE COLLAPSED ISLAND LIGHTS EXACTLY ONE AMBER DOT, in the leading
// wing, and it is the kernel's memory-pressure verdict. Before adding a
// second, check whether the system already draws it.
//
// The arithmetic for how the wing is spent is in
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

/// RIGHT of the camera housing: one live slot, and nothing else.
///
/// Empty at rest, which is most of the time — no print and no imminent
/// meeting means the slot is absent and the wing is back at 26 pt.
///
/// WHEN YOU ADD A FEATURE TO THE SLOT: the width is not yours to choose
/// from in here. The arbiter in `IslandModel.updateTrailingSlot` decides
/// who wins, calls `model.requestTrailingWing(w)` — which clamps against
/// our own status item — and calls `model.setStripSlotSection(...)` so
/// that clicking the strip opens the panel on the matching tab. Lay out
/// to what `IslandMetrics.trailingLayout` gives you and never to what was
/// requested: drawing wider than the published wing puts pixels outside
/// the hit rect, where clicks go to the menu bar instead of to you.
struct IslandTrailingWing: View {
    @ObservedObject var model: IslandModel
    /// What the wing is ACTUALLY this wide right now. Collapsed that is
    /// `model.trailingWingWidth`; open it is half of whatever is left of
    /// the 560 pt panel. Passed in rather than read here so there is one
    /// answer, the one `IslandView` also used to lay out the row.
    let availableWidth: CGFloat

    private var layout: IslandMetrics.TrailingLayout {
        // ONE `slotVisible`, TWO possible occupants. The test must be the
        // disjunction of every branch in the body below, or the layout
        // reserves no width for a slot that then tries to draw.
        //
        // Sound and tunnel were removed from both together — see the note
        // beside `IslandModel.updateTrailingSlot`, which is where the
        // reasoning lives.
        IslandMetrics.trailingLayout(wing: availableWidth,
                                     slotVisible: model.printer != nil
                                                  || model.calendarStrip != nil)
    }

    var body: some View {
        let l = layout
        HStack(spacing: 0) {
            // EVERY RIGID WIDTH IN THIS ROW COMES FROM `l`, INCLUDING THE
            // GAPS. This lead-in used to be an unconditional
            // `.frame(width: IslandMetrics.slotLeadingGap)` sitting ABOVE
            // the `slotWidth > 0` test, so with no print and the mic dot up
            // the row's rigid minimum was 7 + 23 = 30 pt inside a 26 pt
            // wing: the flexible Spacer below collapsed to nothing and the
            // privacy rail was pushed 4 pt off the plate. The rail has
            // since left the wing entirely, but the rule it taught stands:
            // `l.leadingGap` is 0 when there is no slot to lead in to, and
            // `IslandMetrics.trailingLayout` is the only place that decides
            // it — which is also what `--wing-probe` now checks.
            if l.leadingGap > 0 {
                Spacer(minLength: 0).frame(width: l.leadingGap)
            }

            // THE ORDER OF THESE BRANCHES IS THE ARBITER'S PRIORITY, and
            // it must stay in step with `IslandModel.updateTrailingSlot` —
            // that method picked which section the click navigates to, and
            // drawing a different one here would open the wrong tab.
            //
            // Print, then meeting. Sound and tunnel are deliberately absent
            // — both were measured to be permanently true on this machine,
            // which is a lamp rather than a signal; the reasoning is written
            // out once, beside the arbiter.
            if l.slotWidth > 0 {
                if let reading = model.printer {
                    PrintStripSlot(reading: reading, showsText: l.showsSlotText)
                        .frame(width: l.slotWidth, alignment: .leading)
                } else if let countdown = model.calendarStrip,
                          let meeting = model.calendar.next {
                    MeetingStripSlot(event: meeting, countdown: countdown,
                                     showsText: l.showsSlotText)
                        .frame(width: l.slotWidth, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
