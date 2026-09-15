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
// Design the trailing slot for what `IslandModel.trailingWingWidth`
// actually is after the request, never for what you asked for.
//
// ---------------------------------------------------------------------
// WHAT BOUNDS THE WING AGAINST *OTHER* APPS' MENU BAR EXTRAS — read this
// before raising any ceiling in here.
//
// Nothing in this process can see another app's menu bar extra. There is
// no unprivileged API for it: the only route is the Accessibility tree,
// which needs a grant this app does not ask for. So the wing is bounded
// by two things we CAN observe, and by nothing else:
//
//   1. OUR OWN status item's window position (`trailingWingLimit`), which
//      needs no permission because the window is ours; and
//
//   2. THE LEFTMOST POSITION OUR OWN ITEM HAS EVER HELD on this screen
//      configuration (`IslandController.observedStatusItemMinX`). Extras
//      are packed contiguously from the right edge of the menu bar, so
//      when one is added every item to its left — ours included — shifts
//      left, and when the user Command-drags OUR item rightwards the
//      others close the gap behind it. The low-water mark of our own
//      minX is therefore a decent estimate of where the extras region
//      begins, and it is the ONLY estimate available without a
//      permission prompt. It is conservative in the right direction: if
//      an extra is removed the region really shrinks to the right and we
//      simply keep the smaller, older bound.
//
// The ceiling below used to be 156 — "172.5 pt of measured clearance
// minus a margin", i.e. a one-off measurement of where a DIFFERENT app's
// extra happened to sit on this machine on one day. That is not a bound,
// it is an anecdote, and with our own item dragged to the right of the
// others the wing would happily grow to it and cover somebody else's
// icon, taking their clicks (an armed panel sets
// `ignoresMouseEvents = false` over everything it draws). The ceiling is
// now derived from what the CONTENTS can use, which is a real bound: the
// wing cannot be wider than the widest row it is able to draw, no matter
// what anyone measured.
// =====================================================================

enum IslandMetrics {

    // MARK: - Wings

    /// Both wings at rest. Wide enough for the pressure dot and its
    /// padding, and nothing else.
    static let restingWingWidth: CGFloat = 26

    /// Hard ceiling for the TRAILING wing: EXACTLY what the widest row the
    /// wing can draw needs, and not one point more —
    ///
    ///     7 lead-in + 14 ring + 4 gap + 25 text + 4 gap + 23 rail = 77
    ///
    /// It is defined as that sum rather than written as 77, so it cannot
    /// drift from the layout it bounds. This is a BOUND, in a way the old
    /// 156 was not: 156 was where a different app's menu bar extra was
    /// measured to sit on this machine on one particular day, and this
    /// process cannot see other apps' extras at all (see the header). A
    /// ceiling derived from our own contents is one we can actually
    /// justify — the wing is never wider than it has anything to put in.
    ///
    /// The runtime bound (`trailingWingLimit`) can only make this smaller,
    /// never larger.
    static let maxTrailingWingWidth: CGFloat =
        slotLeadingGap + ringDiameter + ringTextGap + slotTextWidth + slotGap + privacyRailWidth

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
    // privacy dots up while a print runs — is the case the numbers below
    // are tuned for, because it is the one where the feature has least room
    // and still has to be legible:
    //
    //     77 ceiling - 7 lead-in - 23 rail - 4 gap = 43 pt available
    //     14 ring + 4 gap + 25 text               = 43 pt needed
    //
    // Exactly, by construction: `maxTrailingWingWidth` IS that sum, so the
    // ceiling and the widest row cannot drift apart. (This machine's
    // runtime bound grants 79.5 pt, so the ceiling is what binds here and
    // the plate is 2.5 pt narrower than it could be — which is the right
    // way round: unused width is width that cannot cover anybody else's
    // menu bar extra.)
    //
    // The text width was measured rather than guessed: the widest string
    // `PrinterFeature.remaining` can produce is "1ч23"/"9ч59", which lays
    // out at 23.4 pt in 9 pt medium monospaced digits (that is also why the
    // formatter drops the minutes past ten hours — "23ч59" needs 29.3 pt
    // and would truncate here).
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
        /// Clearance between the camera housing and the first pixel of the
        /// slot. ZERO WHEN THERE IS NO SLOT — it is the slot's lead-in, not
        /// the wing's padding, and it is in this struct rather than read
        /// straight off `IslandMetrics` by the view for exactly that
        /// reason. `IslandStrip` used to draw a RIGID 7 pt box before the
        /// `slotWidth > 0` test, so in the commonest state of the whole
        /// feature — mic in use, printer off — the row's minimum was
        /// 7 + 0 + 23 = 30 pt inside a 26 pt wing, the flexible spacer
        /// collapsed, and the privacy dots were pushed 4 pt past the right
        /// edge of the plate. `--wing-probe` said "OK" throughout, because
        /// its own `spent` formula omitted the same 7 pt. Two copies of a
        /// layout rule is how the drawn thing and the checked thing drift
        /// apart; now there is one copy and both read it.
        let leadingGap: CGFloat
        /// 0 when the slot did not fit at all.
        let slotWidth: CGFloat
        /// False when only the ring fits.
        let showsSlotText: Bool
        /// Between the slot and the rail. 0 unless both are present.
        let slotRailGap: CGFloat
        /// 0 when no sensor is in use.
        let railWidth: CGFloat

        /// Exactly what the HStack in `IslandStrip` lays out, in order.
        /// This is what must never exceed the wing.
        var spent: CGFloat { leadingGap + slotWidth + slotRailGap + railWidth }
    }

    static func trailingLayout(wing: CGFloat,
                               privacyVisible: Bool,
                               slotVisible: Bool) -> TrailingLayout {
        let rail = privacyVisible ? min(privacyRailWidth, wing) : 0
        func railOnly() -> TrailingLayout {
            TrailingLayout(leadingGap: 0, slotWidth: 0, showsSlotText: false,
                           slotRailGap: 0, railWidth: rail)
        }
        guard slotVisible else { return railOnly() }

        let gap = rail > 0 ? slotGap : 0
        let spare = wing - slotLeadingGap - rail - gap
        guard spare >= ringDiameter else { return railOnly() }

        let withText = ringDiameter + ringTextGap + slotTextWidth
        let slot = spare >= withText ? withText : ringDiameter
        return TrailingLayout(leadingGap: slotLeadingGap,
                              slotWidth: slot,
                              showsSlotText: spare >= withText,
                              slotRailGap: gap,
                              railWidth: rail)
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
    /// which needs no permission of any kind — it is our own window. The
    /// caller passes the LEFTMOST position it has seen that window hold on
    /// this screen configuration, not merely the current one; see the
    /// header for why the low-water mark is the better bound.
    ///
    /// It is nil before the status item has a window, and on any screen
    /// configuration where the item is not on this screen. IT THEN REFUSES
    /// TO GROW — the wing stays at rest. It used to fall back to the
    /// static ceiling, which meant "we have no idea where our own icon is,
    /// so draw 156 pt of island into the menu bar and hope". The absence
    /// of a measurement is not a licence to expand.
    ///
    /// Pure, so it can be checked with synthetic inputs (`--wing-probe`).
    static func trailingWingLimit(statusItemMinX: CGFloat?,
                                  screenMidX: CGFloat,
                                  notchWidth: CGFloat) -> CGFloat {
        guard let statusItemMinX else { return restingWingWidth }
        // Right edge of the drawn plate at wing width w:
        //     screenMidX + notchWidth/2 + w + collapsedFillet
        // and that must stay `statusItemClearance` short of the item.
        let room = statusItemMinX - statusItemClearance
            - screenMidX - notchWidth / 2 - collapsedFillet
        return min(maxTrailingWingWidth, max(restingWingWidth, room))
    }
}
