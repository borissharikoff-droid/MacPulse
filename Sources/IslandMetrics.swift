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
    ///     7 lead-in + 14 ring + 4 gap + 25 text = 50
    ///
    /// It is defined as that sum rather than written as 50, so it cannot
    /// drift from the layout it bounds. This is a BOUND, in a way the old
    /// 156 was not: 156 was where a different app's menu bar extra was
    /// measured to sit on this machine on one particular day, and this
    /// process cannot see other apps' extras at all (see the header). A
    /// ceiling derived from our own contents is one we can actually
    /// justify — the wing is never wider than it has anything to put in.
    ///
    /// IT WAS 77 UNTIL THE PRIVACY RAIL LEFT THE WING. The rail cost 4 pt
    /// of gap plus 23 pt of dots; deleting it shrank the widest row this
    /// wing can draw, and because the ceiling IS that row, the ceiling
    /// shrank with it. Nothing was tuned — the sum simply lost two terms.
    ///
    /// The runtime bound (`trailingWingLimit`) can only make this smaller,
    /// never larger.
    static let maxTrailingWingWidth: CGFloat =
        slotLeadingGap + ringDiameter + ringTextGap + slotTextWidth

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
    // ONE THING. The live slot the arbiter picked — print progress, or the
    // meeting countdown — and nothing else.
    //
    // THE PRIVACY RAIL USED TO SHARE IT, pinned at the far right, 23 pt
    // wide, and it is GONE. Not for clutter: for DUPLICATION. macOS ships
    // its own orange microphone indicator in the menu bar and it is on
    // screen a few points to the right of ours, so our dot said a second
    // time what the system had already said. That is the argument written
    // beside `IslandModel.updateTrailingSlot` for keeping the pressure
    // notifier out of the wing, and it is applied here for the same
    // reason: saying the same thing twice is worse than saying it once.
    //
    // WHAT SURVIVED IS THE PART macOS DOES NOT PROVIDE — WHICH app holds
    // the microphone. `PrivacyWatcher` still runs and still publishes, and
    // the answer is a clause in the panel footer, in words. See
    // IslandPrivacyLine.swift.
    //
    // So the worst case is now simply the widest row:
    //
    //     50 ceiling - 7 lead-in  = 43 pt available
    //     14 ring + 4 gap + 25 text = 43 pt needed
    //
    // Exactly, by construction: `maxTrailingWingWidth` IS that sum, so the
    // ceiling and the widest row cannot drift apart. (This machine's
    // runtime bound grants 79.5 pt, so the ceiling is what binds here and
    // the plate is 29.5 pt narrower than it could be — which is the right
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
    // below the ring the slot disappears entirely and the wing is empty.

    /// Clearance between the camera housing and the first pixel of the
    /// slot. The housing is glass; drawing right up to it looks like a
    /// rendering fault.
    static let slotLeadingGap: CGFloat = 7
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
        /// 0 when the slot did not fit at all, which is also the empty
        /// wing: with the privacy rail gone there is nothing else in here.
        let slotWidth: CGFloat
        /// False when only the ring fits.
        let showsSlotText: Bool

        /// Exactly what the HStack in `IslandStrip` lays out, in order.
        /// This is what must never exceed the wing.
        var spent: CGFloat { leadingGap + slotWidth }
    }

    /// `privacyVisible` USED TO BE A PARAMETER HERE and is deliberately not
    /// one any more. When the rail left the wing it had exactly one caller
    /// left and that caller would have passed a constant `false` for ever —
    /// a parameter nobody varies is a branch nobody tests, and it would have
    /// kept `railWidth` and `slotRailGap` alive in the struct as fields that
    /// are always 0. The whole rail is out of the arithmetic instead.
    static func trailingLayout(wing: CGFloat, slotVisible: Bool) -> TrailingLayout {
        let empty = TrailingLayout(leadingGap: 0, slotWidth: 0, showsSlotText: false)
        guard slotVisible else { return empty }

        let spare = wing - slotLeadingGap
        guard spare >= ringDiameter else { return empty }

        let withText = ringDiameter + ringTextGap + slotTextWidth
        let slot = spare >= withText ? withText : ringDiameter
        return TrailingLayout(leadingGap: slotLeadingGap,
                              slotWidth: slot,
                              showsSlotText: spare >= withText)
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
    // 560 x 304.
    //
    //    32  notch strip   (click = pin)
    //     6  gap
    //    24  rail          one chip per section that HAS STATE RIGHT NOW
    //     6  gap
    //   186  body          exactly one section, 560 x 186
    //     4  gap
    //    28  shelf         the last 5 clipboard entries, draggable, ALWAYS
    //     4  gap
    //    14  footer        one line summarising the other live sections
    //   ---
    //   304
    //
    // ---------------------------------------------------------------------
    // IT WAS 280, AND IT GREW BY 24. Read this before adding a row.
    //
    // The user has twice asked for LESS in this panel, so a taller window
    // needs an argument and not a shrug. Here it is, in full:
    //
    //   WHAT THE PANEL LOST. Two whole tabs. «Давление» folded into
    //   «Память» — they were always the same subject, and the user said so
    //   — and «Буфер» stopped being a destination at all. The panel used to
    //   offer seven 560 x 186 bodies to navigate between; it now offers
    //   five. That is 372 pt of content the user no longer has to route to.
    //
    //   WHAT IT GAINED. 28 pt of shelf: the last five clipboard entries,
    //   on screen whichever section is selected, each one a thing you can
    //   DRAG into another app. It is the only surface on this panel the
    //   user asked for by name, and the only one he can act on with a
    //   gesture rather than a click.
    //
    //   WHAT IT PAID FOR ITSELF WITH. 8 of the 32 pt came out of the
    //   panel's own chrome, not out of any feature: the rail went 28 -> 24
    //   (its chips are 20 pt tall and 2 pt of band either side is enough)
    //   and the footer 18 -> 14 (its line is 9.5 pt). Net +24.
    //
    //   WHY NOT OUT OF THE BODY, which is what you would try first. The
    //   body is 186 and the six section bodies are laid out to exactly it:
    //   «Звук» documents 184 of 186, «Туннель» 180, «Память» 184. The
    //   largest cut the body can absorb without something being silently
    //   CLIPPED — `IslandRouter` frames the section and calls `.clipped()`
    //   — is 2 pt. Taking 28 out of the body would have quietly truncated
    //   four sections whose bodies cannot be seen on this machine right now
    //   (no print, no meeting, nothing playing), i.e. broken them in a way
    //   no screenshot here could catch. So the body did not move.
    //
    // The next person who wants a row: the body is still the place to look,
    // and the price is re-fitting six sections, honestly, one at a time.
    // ---------------------------------------------------------------------
    //
    // The strip is the notch's own height (32 here) and comes out of the
    // same measurement, so the arithmetic below is asserted at runtime by
    // `panelLayoutIsConsistent` rather than trusted.

    static let panelWidth: CGFloat = 560
    static let panelHeight: CGFloat = 304

    static let railGap: CGFloat = 6
    static let railHeight: CGFloat = 24
    static let bodyGap: CGFloat = 6
    static let bodyHeight: CGFloat = 186
    static let shelfGap: CGFloat = 4
    static let shelfHeight: CGFloat = 28
    static let footerGap: CGFloat = 4
    static let footerHeight: CGFloat = 14

    /// Everything below the notch strip. 272 pt against a 32 pt strip.
    static let panelContentHeight: CGFloat =
        railGap + railHeight + bodyGap + bodyHeight
        + shelfGap + shelfHeight + footerGap + footerHeight

    // MARK: - The clipboard shelf
    //
    // WHY FIVE CHIPS, and not the six the old «Буфер» list showed or the
    // eight the user guessed at. It is a width answer, not a taste one.
    //
    // The shelf gets the same 532 pt content box as the rail and the
    // footer (560 minus two 14 pt gutters), and the chips are one row with
    // `shelfChipGap` between them, so each chip is
    //
    //     (532 - (n - 1) * 6) / n
    //
    // and a chip spends 28 pt of that on chrome — 5 pad + 13 glyph +
    // 5 gap + 5 pad — before a single character of preview:
    //
    //     n = 4   121.0 pt   ->  93 pt of preview   ~17 characters
    //     n = 5    101.6 pt  ->  73.6 pt            ~13 characters
    //     n = 6     83.7 pt  ->  55.7 pt            ~10 characters
    //     n = 8     60.8 pt  ->  32.8 pt            ~6 characters
    //
    // at ~5.5 pt per character for SF at 10.5 pt. Ten characters is not a
    // preview, it is a hash: "Screenshot 2026-09-15.png" and
    // "Screenshot 2026-09-14.png" are the same chip at n = 6 and different
    // chips at n = 5. Recognisable is the whole job of a shelf you drag
    // from — pick the wrong chip and you have dropped the wrong file into
    // somebody's chat — so the count is the largest one that still shows
    // enough to tell two entries apart. That is five.
    static let shelfSlots = 5
    static let shelfChipGap: CGFloat = 6
    /// Chip height. 24 of the shelf's 28, leaving 2 pt above and below.
    static let shelfChipHeight: CGFloat = 24

    /// One chip's width, for a given content box. Pure, so `--shelf-probe`
    /// can check the preview budget against the same number the view lays
    /// out to — same rule as `trailingLayout`.
    static func shelfChipWidth(content: CGFloat, slots: Int = shelfSlots) -> CGFloat {
        guard slots > 0 else { return 0 }
        return (content - CGFloat(slots - 1) * shelfChipGap) / CGFloat(slots)
    }

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
