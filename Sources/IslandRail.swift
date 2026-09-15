import SwiftUI

// =====================================================================
// The expanded panel's router.
//
//    32  notch strip   (click = pin; drawn by IslandView, not here)
//     6  gap
//    28  RAIL          one chip per section that HAS STATE RIGHT NOW
//     6  gap
//   186  BODY          exactly ONE section, 560 x 186
//     4  gap
//    18  FOOTER        one line for the other live sections
//   ---
//   280, and it stays 280.
//
// WHY A ROUTER AND NOT A DASHBOARD. Every feature that lands wants a
// strip of the panel, and a panel that grows a strip per feature is the
// wall of numbers the user has already rejected twice. A router costs one
// 28 pt rail once, and then every feature after the first is free. It
// also degrades correctly: with one live section the rail is a single
// chip and the panel is what it has always been.
//
// This file contains NO knowledge of any particular section. It asks the
// registry what is live and renders it. Adding a section means touching
// IslandFeatures.swift and your own file — never this one.
// =====================================================================

// MARK: - Rail

private struct RailChip: View {
    let section: IslandSection
    let isSelected: Bool
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
            .padding(.horizontal, 9)
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

    var body: some View {
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

/// One line for the live sections that are NOT on screen. Empty on a
/// quiet machine, and it keeps its 18 pt anyway so that a section
/// appearing or disappearing never moves the body.
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

            Spacer(minLength: 0).frame(height: IslandMetrics.footerGap)

            IslandFooter(model: model)
        }
        .frame(width: IslandMetrics.panelWidth,
               height: IslandMetrics.panelContentHeight,
               alignment: .top)
    }
}
