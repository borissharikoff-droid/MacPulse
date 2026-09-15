import SwiftUI

// =====================================================================
// The expanded panel's router.
//
//    32  notch strip   (click = pin; drawn by IslandView, not here)
//     6  gap
//    24  RAIL          one chip per section that HAS STATE RIGHT NOW
//     6  gap
//   186  BODY          exactly ONE section, 560 x 186
//     4  gap
//    28  SHELF         the last clipboard entries, draggable, ALWAYS
//     4  gap
//    14  FOOTER        one line for the other live sections
//   ---
//   304
//
// WHY A ROUTER AND NOT A DASHBOARD. Every feature that lands wants a
// strip of the panel, and a panel that grows a strip per feature is the
// wall of numbers the user has already rejected twice. A router costs one
// rail once, and then every feature after the first is free. It also
// degrades correctly: with one live section the rail is a single chip and
// the panel is what it has always been.
//
// THE SHELF IS THE ONE THING IN HERE THAT IS NOT ROUTED TO, and that is
// the point of it: the user asked to see his last few clipboard entries
// along the bottom and drag them out, and a tab is a place you navigate
// to, which is one gesture too many for a thing you reach for. So it sits
// below the body, on screen whichever section is selected, and «Буфер» is
// no longer a section at all. It is the ONLY exception to the rule below
// — see IslandShelf.swift for why it earned one, and IslandMetrics for
// where its 28 pt came from.
//
// Otherwise this file contains NO knowledge of any particular section. It
// asks the registry what is live and renders it. Adding a section means
// touching IslandFeatures.swift and your own file — never this one.
// =====================================================================

// MARK: - Rail

private struct RailChip: View {
    let section: IslandSection
    let isSelected: Bool
    /// From `IslandRail.chipPadding(chips:)` — NOT a constant here. See
    /// that method for why the rail, and not the chip, decides it.
    let horizontalPadding: CGFloat
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if !section.chipSymbol.isEmpty {
                    Image(systemName: section.chipSymbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(section.chipTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.white : Color(white: hovering ? 0.72 : 0.55))
            .padding(.horizontal, horizontalPadding)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.13 : (hovering ? 0.06 : 0)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The tab strip. One chip per LIVE section, in registration order.
///
/// A single chip is not a tab bar, it is a title — so it renders without
/// the selected-chip plate. That is what keeps a quiet machine's panel
/// looking like the panel it was before the router existed.
struct IslandRail: View {
    @ObservedObject var model: IslandModel

    private var live: [IslandSection] {
        model.visibleSections.compactMap { IslandSectionRegistry.section($0) }
    }

    /// Horizontal padding inside each chip, as a function of how many
    /// chips the rail is holding.
    ///
    /// THE RAIL HAS NO WRAP AND NO SCROLL, and it cannot grow: the content
    /// box is 532 pt and the panel is 560 and staying 560. A chip that
    /// does not fit is not clipped politely — it is pushed off the plate,
    /// where the tab exists, is listed, and cannot be clicked.
    ///
    /// With one section that could never happen and this was a constant 9.
    /// With seven it could: measured by `--rail-probe` at the selected
    /// chip's semibold weight, all seven titles plus their symbols came to
    /// 545.4 pt at 9 pt padding — 13.4 pt over. At 6 pt they came to 503.4
    /// and fit with 28.6 to spare.
    ///
    /// THERE ARE FIVE SECTIONS NOW, not seven: «Давление» folded into
    /// «Память» and «Буфер» became the shelf. So the six-chip case is
    /// unreachable until somebody registers two more, and the tightening
    /// below is dead code that is deliberately kept — it is the thing that
    /// stops the sixth section from being the one that discovers this.
    /// `--rail-probe` recomputes it against the live registry on every
    /// run, so a section added later that does not fit says so in a number
    /// rather than on screen.
    static func chipPadding(chips: Int) -> CGFloat { chips >= 6 ? 6 : 9 }

    var body: some View {
        let padding = Self.chipPadding(chips: live.count)
        HStack(spacing: 4) {
            if live.count <= 1 {
                if let only = live.first {
                    Text(only.chipTitle.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color(white: 0.55))
                        .tracking(0.6)
                        .padding(.horizontal, 3)
                }
            } else {
                ForEach(live) { section in
                    RailChip(section: section,
                             isSelected: section.id == model.selectedSection,
                             horizontalPadding: padding,
                             onTap: { model.select(section.id) })
                }
            }
            Spacer(minLength: 0)
        }
        // The gutter is INSIDE the 560, so the content box is 532 and the
        // padding brings it back to 560. Framing to 560 and then padding
        // would make the row 588 and push the rail off the plate.
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.railHeight,
               alignment: .leading)
        .padding(.horizontal, IslandRouter.gutter)
    }
}

// MARK: - Footer

/// One line for the live sections that are NOT on screen, plus whichever
/// app is holding the microphone. Empty on a quiet machine, and it keeps
/// its 14 pt anyway so that a section appearing or disappearing never
/// moves the body or the shelf.
struct IslandFooter: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            Text(model.footerLine)
                .font(.system(size: 9.5))
                .foregroundStyle(Color(white: 0.42))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.footerHeight,
               alignment: .leading)
        .padding(.horizontal, IslandRouter.gutter)
    }
}

// MARK: - Router

struct IslandRouter: View {
    @ObservedObject var model: IslandModel

    /// Horizontal inset shared by the rail, every section body and the
    /// footer, so the columns line up down the panel. The section gets a
    /// 560 pt canvas and applies this itself — see IslandSectionMemory.
    static let gutter: CGFloat = 14

    private var section: IslandSection? {
        IslandSectionRegistry.section(model.selectedSection)
            ?? IslandSectionRegistry.section(.memory)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0).frame(height: IslandMetrics.railGap)

            IslandRail(model: model)

            Spacer(minLength: 0).frame(height: IslandMetrics.bodyGap)

            // Exactly one section, on a canvas it does not get to exceed.
            Group {
                if let section {
                    section.makeBody(model)
                } else {
                    Color.clear
                }
            }
            .frame(width: IslandMetrics.panelWidth,
                   height: IslandMetrics.bodyHeight,
                   alignment: .top)
            .clipped()

            Spacer(minLength: 0).frame(height: IslandMetrics.shelfGap)

            // NOT a section, and not selected: it is below the router, not
            // inside it. See IslandShelf.swift.
            ClipboardShelf(model: model)

            Spacer(minLength: 0).frame(height: IslandMetrics.footerGap)

            IslandFooter(model: model)
        }
        .frame(width: IslandMetrics.panelWidth,
               height: IslandMetrics.panelContentHeight,
               alignment: .top)
    }
}
