import CoreGraphics

// =====================================================================
// THE ONE PLACE THE ISLAND'S SIZE IS DECIDED.
//
// Read this before changing any number in it.
//
// The island is drawn by SwiftUI (IslandView) and hit-tested by AppKit
// (IslandController) from two completely different coordinate systems.
// Before this file existed the controller re-derived the collapsed width
// from a static constant — `IslandView.collapsedSideWidth * 2 + 6 * 2` —
// which was correct only for as long as both wings were that constant.
// The moment a wing became dynamic the hit rect stopped following the
// drawn shape, and a hit rect that has drifted off the shape means the
// island either refuses to open (rect narrower than the plate) or arms
// over dead menu bar (rect wider). That class of bug cannot happen if
// there is exactly one function and both callers use it, which is what
// `collapsedPlate` / `openedPlate` are for.
//
// MEASURED ON THIS MACHINE (MacBook Air 13" M2, 1470x956 pt):
//   notch            183 pt wide, x 643.5 ... 826.5, height 32
//   screen midX      735 pt  — the notch is centred on it
//   frontmost menus  end at x=612 (zen), 592 (Cursor), 452 (Terminal)
//   collapsed plate  x 611.5 ... 858.5 at 26/26 wings
//   leftmost extra   x=1031 (CmdTabSwitcher)
//   MacPulse's OWN   x=952  (statusItem.button.window.frame.minX)
//
// So the LEFT wing has 611.5 - 612 = 0.5 pt of clearance against the
// frontmost app's own menus and CAN NEVER GROW. It is frozen at 26 pt,
// pressure dot only. The RIGHT wing is the only surface on the collapsed
// island that can ever hold anything.
//
// HOW MUCH RIGHT WING THERE ACTUALLY IS — and this is smaller than the
// obvious answer. Measuring to the leftmost OTHER app's menu bar extra
// (CmdTabSwitcher, x=1031) suggests 172.5 pt. But MacPulse's own status
// item sits at x=952, well to the left of that, and growing the wing
// under our own icon is the silliest version of this bug. Measured
// live on this machine, the runtime bound therefore grants
//
//     952 - 40 clearance - 735 midX - 91.5 half-notch - 6 fillet = 79.5 pt
//
// so a feature that asks for the full 156 gets 79.5 here. Design the
// trailing slot for what `IslandModel.trailingWingWidth` actually is
// after the request, never for what you asked for — and never for 156.
// =====================================================================

enum IslandMetrics {

    // MARK: - Wings

    /// Both wings at rest. Wide enough for the pressure dot and its
    /// padding, and nothing else.
    static let restingWingWidth: CGFloat = 26

    /// Hard ceiling for the TRAILING wing. 172.5 pt of measured clearance
    /// minus a margin, rounded down. The runtime bound
    /// (`trailingWingLimit`) can only make this smaller, never larger.
    static let maxTrailingWingWidth: CGFloat = 156

    /// The LEADING wing is not a variable. 0.5 pt of measured clearance.
    /// If you are here to widen it: measure where the frontmost app's
    /// menus end first, and remember that the app with the longest menu
    /// bar wins, not the one that happens to be frontmost now.
    static let leadingWingWidth: CGFloat = restingWingWidth

    /// How much bare menu bar must remain between the island's right edge
    /// and MacPulse's own status item. Below this the two read as one
    /// smeared blob and the status item stops being clickable-looking.
    static let statusItemClearance: CGFloat = 40

    // MARK: - What is inside the trailing wing
    //
    // Two things share it, and they are not equals.
    //
    // THE PRIVACY RAIL is pinned at the far right and NOTHING may preempt
    // it. It is sized to fit inside the RESTING wing — 6 + 4 + 6 + 7 = 23
    // against 26 — which is the whole point: the one safety signal on the
    // island never has to ask for width, so it can never lose a width
    // negotiation to a progress ring. If you widen the dots, check this
    // sum again.
    //
    // THE LIVE SLOT is whatever the arbiter picked (print progress, this
    // phase) and gets what is left after the rail. THE WORST CASE — both
    // privacy dots up while a print runs, on this machine's real 79.5 pt
    // grant — is the case the numbers below are tuned for, because it is
    // the one where the feature has least room and still has to be legible:
    //
    //     79.5 granted - 7 lead-in - 23 rail - 4 gap = 45.5 pt available
    //     14 ring + 4 gap + 25 text                  = 43   pt needed
    //
    // 2.5 pt of margin, and it was measured rather than guessed: the widest
    // string `PrinterFeature.remaining` can produce is "1ч23"/"9ч59", which
    // lays out at 23.4 pt in 9 pt medium monospaced digits (that is also
    // why the formatter drops the minutes past ten hours — "23ч59" needs
    // 29.3 pt and would truncate here).
    //
    // Below the text width the text is dropped and the ring stands alone;
    // below the ring the slot disappears entirely and only the rail
    // remains. The rail is never the thing that gives way.

    static let privacyDotSize: CGFloat = 6
    static let privacyDotGap: CGFloat = 4
    /// Between the last dot and the right edge of the drawn plate.
    static let privacyRailPadding: CGFloat = 7
    /// Two dots plus the gap plus the padding. MUST be <= restingWingWidth.
    static let privacyRailWidth: CGFloat =
        privacyDotSize * 2 + privacyDotGap + privacyRailPadding

    /// Clearance between the camera housing and the first pixel of the
    /// slot. The housing is glass; drawing right up to it looks like a
    /// rendering fault.
    static let slotLeadingGap: CGFloat = 7
    /// Between the live slot and the privacy rail.
    static let slotGap: CGFloat = 4
    static let ringDiameter: CGFloat = 14
    /// Room for the widest remaining-time form, "1ч23"/"9ч59", MEASURED at
    /// 23.4 pt in 9 pt medium monospaced digits. Reserved whether or not
    /// the current value is that wide, so the strip does not resize as the
    /// estimate crosses an hour.
    static let slotTextWidth: CGFloat = 25
    static let ringTextGap: CGFloat = 4

    /// How the trailing wing's width is actually spent.
    ///
    /// The ONE place this arithmetic exists — same rule as `collapsedPlate`
    /// and for the same reason. Pure, so `--wing-probe` can check it at
    /// every width the model will grant.
    struct TrailingLayout: Equatable {
        /// 0 when the slot did not fit at all.
        let slotWidth: CGFloat
        /// False when only the ring fits.
        let showsSlotText: Bool
        /// 0 when no sensor is in use.
        let railWidth: CGFloat
    }

    static func trailingLayout(wing: CGFloat,
                               privacyVisible: Bool,
                               slotVisible: Bool) -> TrailingLayout {
        let rail = privacyVisible ? min(privacyRailWidth, wing) : 0
        guard slotVisible else {
            return TrailingLayout(slotWidth: 0, showsSlotText: false, railWidth: rail)
        }
        let spare = wing - slotLeadingGap - rail - (rail > 0 ? slotGap : 0)
        guard spare >= ringDiameter else {
            return TrailingLayout(slotWidth: 0, showsSlotText: false, railWidth: rail)
        }
        let withText = ringDiameter + ringTextGap + slotTextWidth
        if spare >= withText {
            return TrailingLayout(slotWidth: withText, showsSlotText: true, railWidth: rail)
        }
        return TrailingLayout(slotWidth: ringDiameter, showsSlotText: false, railWidth: rail)
    }

    // MARK: - Plate

    /// MPNotchShape's concave top fillets live OUTSIDE the visual body, so
    /// the drawn plate is always `content + 2 * fillet` wide and the
    /// content has to be inset by the fillet or the corners clip it.
    static let collapsedFillet: CGFloat = 6
    static let openedFillet: CGFloat = 19
    /// Extra height while the pointer is dwelling over the strip.
    static let poppingLift: CGFloat = 3

    // MARK: - Expanded panel
    //
    // 560 x 280 EXACTLY, and it does not grow. The user has twice asked
    // for LESS in this panel; the answer to "more features" is the router
    // below — one section on screen at a time — not a taller window.
    //
    //    32  notch strip   (click = pin)
    //     6  gap
    //    28  rail          one chip per section that HAS STATE RIGHT NOW
    //     6  gap
    //   186  body          exactly one section, 560 x 186
    //     4  gap
    //    18  footer        one line summarising the other live sections
    //   ---
    //   280
    //
    // The strip is the notch's own height (32 here) and comes out of the
    // same measurement, so the arithmetic below is asserted at runtime by
    // `panelLayoutIsConsistent` rather than trusted.

    static let panelWidth: CGFloat = 560
    static let panelHeight: CGFloat = 280

    static let railGap: CGFloat = 6
    static let railHeight: CGFloat = 28
    static let bodyGap: CGFloat = 6
    static let bodyHeight: CGFloat = 186
    static let footerGap: CGFloat = 4
    static let footerHeight: CGFloat = 18

    /// Everything below the notch strip. 248 pt against a 32 pt strip.
    static let panelContentHeight: CGFloat =
        railGap + railHeight + bodyGap + bodyHeight + footerGap + footerHeight

    /// True when the fixed rows still add up against this screen's notch
    /// height. False means the panel would clip or leave a gap and the
    /// numbers above need revisiting — not that the panel should grow.
    static func panelLayoutIsConsistent(stripHeight: CGFloat) -> Bool {
        abs(stripHeight + panelContentHeight - panelHeight) < 0.5
    }

    // MARK: - Derived plate geometry

    /// A drawn plate: its total size including the fillets, and how far
    /// its CENTRE sits from the centre of the camera housing.
    ///
    /// The housing is physical glass at a fixed place on the screen, so it
    /// is the anchor; the plate slides around it as the wings change. With
    /// equal wings the offset is 0 and this is the symmetric island that
    /// shipped before.
    struct Plate: Equatable {
        let size: CGSize
        let centerOffsetX: CGFloat
        let fillet: CGFloat
    }

    /// The collapsed (or popping) plate for a given pair of wing widths.
    ///
    /// Both `IslandView` (to draw) and `IslandController` (to hit-test)
    /// call this. Do not re-derive either one by hand.
    static func collapsedPlate(notch: CGSize,
                               leading: CGFloat,
                               trailing: CGFloat,
                               popping: Bool = false) -> Plate {
        let content = leading + notch.width + trailing
        return Plate(
            size: CGSize(width: content + collapsedFillet * 2,
                         height: notch.height + (popping ? poppingLift : 0)),
            // plateCentre - notchCentre. Derivation:
            //   plate centre from its left edge = (content + 2f) / 2
            //   notch centre from the same edge = f + leading + notch.w/2
            //   difference                      = (trailing - leading) / 2
            centerOffsetX: (trailing - leading) / 2,
            fillet: collapsedFillet
        )
    }

    /// The opened plate. Always centred on the housing: the panel is much
    /// wider than either wing, so there is nothing to be asymmetric about
    /// and an off-centre panel would just look broken.
    static func openedPlate() -> Plate {
        Plate(size: CGSize(width: panelWidth + openedFillet * 2, height: panelHeight),
              centerOffsetX: 0,
              fillet: openedFillet)
    }

    /// The widest the trailing wing may grow before it would sit under
    /// MacPulse's own menu bar item.
    ///
    /// `statusItemMinX` comes from `statusItem.button?.window?.frame.minX`,
    /// which needs no permission of any kind — it is our own window. It is
    /// nil before the status item has a window, and on any screen
    /// configuration where the item is not on this screen; then only the
    /// static ceiling applies.
    ///
    /// Pure, so it can be checked with synthetic inputs (`--wing-probe`).
    static func trailingWingLimit(statusItemMinX: CGFloat?,
                                  screenMidX: CGFloat,
                                  notchWidth: CGFloat) -> CGFloat {
        guard let statusItemMinX else { return maxTrailingWingWidth }
        // Right edge of the drawn plate at wing width w:
        //     screenMidX + notchWidth/2 + w + collapsedFillet
        // and that must stay `statusItemClearance` short of the item.
        let room = statusItemMinX - statusItemClearance
            - screenMidX - notchWidth / 2 - collapsedFillet
        return min(maxTrailingWingWidth, max(restingWingWidth, room))
    }
}
