import AppKit
import SwiftUI

// =====================================================================
// «Память» — the default section, and the only one that is always live.
//
// This is the panel's old Dashboard, ported into the router's 560 x 186
// canvas. It lost 40 pt in the move (the body used to have ~226), which
// came out of the hero and the app-list header, not out of the app rows:
//
//   BEFORE                             AFTER
//   hero, 5 stacked lines       75     hero, 3 rows            39
//   gap                         10     gap                      6
//   divider                      1     divider                  1
//   gap                         10     gap                      6
//   "ВАШИ ПРИЛОЖЕНИЯ ..." +            coverage note only      11
//     coverage note, 2 lines    13     gap                      3
//   5 x 22 pt AppRow           118     5 x 22 pt AppRow       118
//   ------------------------------     -----------------------------
//                              227                            184
//
// The header line "ВАШИ ПРИЛОЖЕНИЯ — ПО PHYS_FOOTPRINT" is gone; the
// coverage note that sat beside it stays, because it is the honest part.
// The rows themselves are untouched at 22 pt — they are the content.
//
// NOTHING IN HERE READS A SNAPSHOT. It renders `model.memorySection`,
// which is already formatted and only republished when the rendered
// result would differ. See IslandModel.
// =====================================================================

// MARK: - Hero

private struct MemoryHero: View {
    let state: MemorySectionState

    private var tint: Color { IslandPalette.color(for: state.pressure) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                PressureDot(level: state.pressure, size: 9)
                Text(IslandPalette.label(for: state.pressure))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                Spacer(minLength: 12)
                Text(state.usedLine)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.62))
            }
            .frame(height: 17)

            // Bar HEIGHT only. This is a (wired + compressed) / total
            // heuristic, NOT Apple's formula — Apple documents the factors
            // and never the expression — so it is never labelled "как в
            // Мониторинге системы". The COLOUR comes from the kernel's own
            // pressure level.
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.18))
                        // nil is "not measurable" (total RAM unknown). Then
                        // the track is drawn with NO fill at all, rather
                        // than a fill of width 0 standing in for a measured
                        // zero.
                        if let f = state.barFraction {
                            Capsule().fill(tint)
                                .frame(width: geo.size.width * CGFloat(f))
                        }
                    }
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Text(tr("Давление памяти (ядро)", "Memory pressure (kernel)"))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.5))
                Spacer(minLength: 12)
                Text(state.swapLine)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.45))
            }
            .frame(height: 11)
        }
        .frame(height: 39, alignment: .top)
    }
}

// MARK: - Rows

private struct AppRow: View {
    let row: AppRowState
    let phase: QuitPhase
    let onQuit: () -> Void
    let onForce: () -> Void
    let onBadge: () -> Void

    @State private var hovering = false
    @State private var badgeHovering = false

    var body: some View {
        HStack(spacing: 7) {
            // The icon arrives already resolved. Looking it up here — which
            // is what this view used to do — cost 746 us per evaluation for
            // five rows. See AppIconCache.
            if let icon = row.icon {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.22))
                    .frame(width: 15, height: 15)
            }

            Text(row.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(white: 0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            // THE BADGE IS A BUTTON NOW, and the tooltip says what the
            // number is — because it is NOT a window count and reading it
            // as one is exactly the mistake this popover exists to fix.
            // See IslandWindowPopover.swift.
            if row.groupCount > 1 {
                Button(action: onBadge) {
                    Text("\(row.groupCount)")
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color(white: badgeHovering ? 0.85 : 0.5))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: badgeHovering ? 0.26 : 0.16)))
                }
                .buttonStyle(.plain)
                .onHover { badgeHovering = $0 }
                .help(tr("процессов: \(row.groupCount) — это не окна. Нажмите, чтобы увидеть окна", "\(row.groupCount) processes — not windows. Click to see windows"))
            } else if row.isApplication && hovering {
                // ONE PROCESS, AND POSSIBLY TWENTY WINDOWS. Finder, Preview
                // and TextEdit are single-process apps, so they never grow
                // a badge — and "close all but the front one" is exactly
                // what twenty open PDFs need. Gating the window list on the
                // badge would have hidden the feature from the apps that
                // want it most, which is the same confusion the badge
                // caused, only backwards.
                //
                // It appears ON HOVER and in the slot the badge would have
                // used, so a row at rest is pixel-identical to what it was.
                Button(action: onBadge) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color(white: badgeHovering ? 0.85 : 0.45))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: badgeHovering ? 0.26 : 0.14)))
                }
                .buttonStyle(.plain)
                .onHover { badgeHovering = $0 }
                .help(tr("окна приложения", "App windows"))
            }

            Spacer(minLength: 6)

            Text(row.cpu)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 42, alignment: .trailing)

            Text(row.footprint)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 62, alignment: .trailing)

            action
                .frame(width: 96, alignment: .trailing)
        }
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var action: some View {
        switch phase {
        case .idle:
            if row.isApplication {
                SmallButton(title: tr("Завершить", "Quit"), tint: Color(white: 0.85), onTap: onQuit)
            } else {
                // Not an NSRunningApplication: a daemon or helper we have no
                // safe, graceful way to stop. We show the footprint and stop
                // there — MacPulse never kills anything the user did not
                // individually click, and there is nothing to click here.
                Text(tr("фоновый процесс", "background process"))
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.38))
            }
        case .asked:
            Text(tr("закрывается…", "quitting…"))
                .font(.system(size: 9.5))
                .foregroundStyle(Color(white: 0.55))
        case .needsForce:
            // SECOND, EXPLICIT step, offered only because the graceful
            // quit demonstrably did not take. Never automatic.
            SmallButton(title: tr("Принудительно", "Force quit"), tint: IslandPalette.critical, onTap: onForce)
                .help(tr("Приложение не закрылось само — возможно, есть несохранённые изменения. Принудительное завершение их потеряет.", "The app did not quit on its own — it may have unsaved changes. Force quitting will lose them."))
        case .forced:
            Text(tr("завершается…", "force quitting…"))
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.critical.opacity(0.8))
        case .gone:
            Text(tr("закрыто ✓", "closed ✓"))
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.normal)
        case .failed(let why):
            Text(why)
                .font(.system(size: 9))
                .foregroundStyle(IslandPalette.warning)
        }
    }
}

struct SmallButton: View {
    let title: String
    let tint: Color
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? Color.black : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? tint : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - The section body

private struct MemorySectionView: View {
    @ObservedObject var model: IslandModel

    // THE VERTICAL BUDGET, spelled out so the next change to it has to
    // face the arithmetic. 186 either way; what moves is the app rows.
    //
    //   QUIET — which is almost always        WITH THE PRESSURE FOLD
    //    39  hero                              39  hero
    //     6  gap                                6  gap
    //     1  divider                            1  divider
    //     6  gap                                6  gap
    //    11  coverage note                     11  coverage note
    //     3  gap                                3  gap
    //   118  FIVE app rows (5x22 + 4x2)        70  THREE app rows (3x22 + 2x2)
    //     2  slack                              5  gap
    //                                          45  PressureFold
    //   ---                                   ---
    //   186                                   186
    //
    // The fold is on screen only while `!pressureAlert.isQuiet`, which is
    // the exact condition that used to decide whether «Давление» had a
    // chip in the rail. On a quiet machine this section is pixel-identical
    // to what it was before the fold existed. See IslandPressureFold.swift
    // for why the fourth and fifth app row are the right thing to spend.
    private static let foldGap: CGFloat = 5

    /// How many app rows there is room for. Derived rather than written
    /// down twice: the model publishes up to five and this decides how
    /// many of them are drawn.
    private static func appRows(withFold: Bool) -> Int { withFold ? 3 : 5 }

    var body: some View {
        let state = model.memorySection
        // ONE read, used twice — for whether to draw the fold and for how
        // many app rows there is room for. Reading it twice in two places
        // is how those go out of step and the section silently overflows
        // its 186 pt, which `IslandRouter` would then clip.
        let showsFold = !model.pressureAlert.isQuiet
        let rows = Array(state.rows.prefix(Self.appRows(withFold: showsFold)))

        VStack(alignment: .leading, spacing: 0) {
            MemoryHero(state: state)

            Spacer(minLength: 0).frame(height: 6)
            Divider().overlay(Color(white: 0.16))
            Spacer(minLength: 0).frame(height: 6)

            Text(state.coverageLine)
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.38))
                .lineLimit(1)
                .frame(height: 11)
                .padding(.horizontal, 6)

            Spacer(minLength: 0).frame(height: 3)

            if rows.isEmpty {
                Text("—").font(.system(size: 11)).foregroundStyle(Color(white: 0.4))
                    .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    AppRow(row: row,
                           phase: model.quitPhase(for: row.pid),
                           onQuit: { model.requestQuit(pid: row.pid) },
                           onForce: { model.forceQuit(pid: row.pid) },
                           onBadge: { model.toggleWindowPopover(pid: row.pid) })
                }
            }

            Spacer(minLength: 0)

            // «Давление» USED TO BE ITS OWN TAB and is now the bottom of
            // this one, because the two were always the same subject.
            // Drawn only while the notifier has something to say.
            if showsFold {
                Spacer(minLength: 0).frame(height: Self.foldGap)
                PressureFold(state: model.pressureAlert)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        // The window list, over this section's own canvas. NOT an
        // NSPopover: IslandPanel must never become key, and nothing drawn
        // outside the plate is clickable. See IslandWindowPopover.swift.
        .overlay {
            if let popover = model.windowPopover {
                WindowPopover(state: popover, model: model)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, IslandRouter.gutter)
    }
}

// MARK: - Registration

extension IslandSection {
    /// Память. Registered by `IslandSectionRegistry` itself rather than by
    /// `IslandFeatures`, because it is the fallback the router returns to
    /// whenever the selected section goes quiet — the rail is never empty
    /// and this is why.
    static let memory = IslandSection(
        id: .memory,
        chipTitle: tr("Память", "Memory"),
        chipSymbol: "memorychip",
        // Always. A memory monitor with no memory section is not a thing.
        hasState: { _ in true },
        footerSummary: { model in
            guard let level = model.memorySection.pressure else { return nil }
            return tr("Память: ", "Memory: ") + IslandPalette.label(for: level).lowercased()
        },
        makeBody: { model in AnyView(MemorySectionView(model: model)) }
    )
}
