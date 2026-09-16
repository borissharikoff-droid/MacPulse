import AppKit
import SwiftUI

// =====================================================================
// WHAT THE GREY BADGE OPENS.
//
// The ask was: "click the badge, list that app's windows, close them one
// by one, and give me a button that closes all but the main one — if I
// have ten browser windows, close nine."
//
// THE BADGE DOES NOT COUNT WINDOWS. It counts PROCESSES folded together
// by the kernel's responsibility table. Measured here: Cursor is ten
// processes and ONE window. So the literal reading of the request — a
// Quit button per badge member — would have shipped ten buttons that kill
// Electron helpers: a renderer holding an unsaved tab, the extension
// host, the GPU process. The app respawns them; the unsaved work does not
// come back.
//
// This popover therefore has TWO halves, and the split IS the answer:
//
//   A. WINDOWS — the feature. Real AX windows, one «Закрыть» each, plus a
//      two-step «Закрыть остальные (N)». This is the thing the request
//      was about.
//   B. PROCESSES — diagnostics. Footprint per member, so "which helper
//      got fat" is answerable, and NO terminate button, with the reason
//      on screen in one line.
//
// The header prints «окон: 1» next to a badge that said 10. That
// contradiction is deliberate and is the whole point: it says out loud
// what the badge means, instead of quietly redefining it.
//
// ---------------------------------------------------------------------
// WHY IT IS A SHEET OVER THE BODY AND NOT AN NSPopover
//
// IslandPanel is `.nonactivatingPanel` and `canBecomeKey` is false,
// FOREVER — see that file's header, the first requirement in it. An
// NSPopover is a new window that wants key status; attaching one here is
// how this app would start stealing focus from the editor the user is
// typing in. And the panel arms `ignoresMouseEvents = false` only over
// the island's own hit rect (IslandController), so anything drawn
// OUTSIDE the 560 x 304 plate is not clickable at all.
//
// So the popover is drawn INSIDE the section's own 532 x 186 canvas. It
// costs no window, no focus, no hit-test change and no new geometry. What
// it costs instead is height, which is why the layout below is budgeted
// to the point like every other section in this panel.
//
//    18  header    icon · name · окон: N · [Закрыть остальные (N)] · [x]
//     1  divider
//     5  gap
//   108  WINDOWS   six 18 pt rows, scrolls past that
//     1  divider
//     3  gap
//    11  the one line about why processes have no button
//     2  gap
//    33  PROCESSES three 11 pt rows, biggest footprint first
//     4  slack
//   ---
//   186
// =====================================================================

private enum PopoverMetrics {
    static let header: CGFloat = 18
    static let windowsArea: CGFloat = 108
    static let windowRow: CGFloat = 18
    static let processRow: CGFloat = 11
    /// How many member processes are listed. The question this half
    /// answers is "which helper got fat", and the rows are sorted by
    /// footprint, so the answer is always in the first one. The rest are
    /// a count, not a list — this is a 186 pt canvas and the user has
    /// twice asked for fewer words in it.
    static let processRows = 3
}

// MARK: - One window

private struct WindowRowView: View {
    let row: AppWindowRow
    let onClose: () -> Void
    @State private var hovering = false

    /// One word, or nothing. Minimised and fullscreen windows ARE listed
    /// and ARE closed by «Закрыть остальные» — skipping them silently
    /// would make the count a lie — so the state is named instead.
    private var tag: String? {
        if row.isMain { return "главное" }
        if row.isMinimized { return "свёрнуто" }
        if row.isFullScreen { return "во весь экран" }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            // nil title is a real "this window has no title", not "".
            Text(row.title ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: row.title == nil ? 0.45 : 0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            if let tag {
                Text(tag)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.horizontal, 3).padding(.vertical, 0.5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15)))
            }

            Spacer(minLength: 6)

            if row.canClose {
                SmallButton(title: "Закрыть", tint: Color(white: 0.8), onTap: onClose)
            } else {
                // No close button on the window itself — a sheet, a panel.
                // A dash, never a button that would do nothing.
                Text("—").font(.system(size: 10)).foregroundStyle(Color(white: 0.35))
            }
        }
        .frame(height: PopoverMetrics.windowRow)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color.white.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}

// MARK: - The sheet

struct WindowPopover: View {
    let state: WindowPopoverState
    @ObservedObject var model: IslandModel

    private var windows: [AppWindowRow] { state.scan.windows ?? [] }
    private var others: Int { state.scan.closableOthers.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color(white: 0.18))
            Spacer(minLength: 0).frame(height: 5)
            windowsHalf.frame(height: PopoverMetrics.windowsArea, alignment: .top)
            Divider().overlay(Color(white: 0.16))
            Spacer(minLength: 0).frame(height: 3)
            processCaption
            Spacer(minLength: 0).frame(height: 2)
            processHalf
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: 0.07))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(white: 0.20), lineWidth: 1))
        )
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            if let icon = state.icon {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            }
            Text(state.appName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            // THE LINE THAT MAKES THE DISTINCTION VISIBLE. The badge said
            // ten; this says how many windows there actually are.
            Text(windowCountLine)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))

            Spacer(minLength: 8)

            bulkButton

            SmallButton(title: "✕", tint: Color(white: 0.6)) { model.closeWindowPopover() }
        }
        .frame(height: PopoverMetrics.header)
    }

    private var windowCountLine: String {
        guard let count = state.scan.count else { return "окна не прочитаны" }
        return "окон: \(count)"
    }

    /// TWO STEPS, the same shape as the row's own Quit -> force-quit flow.
    /// The first click only ARMS and reprints the count; the second one
    /// closes. One stray click can never close nine windows.
    @ViewBuilder private var bulkButton: some View {
        if let promised = state.armedOthers {
            SmallButton(title: "Точно? Закрыть \(promised)",
                        tint: IslandPalette.critical) { model.closeOtherWindows() }
                .help(keepsHint)
        } else if others > 0 {
            SmallButton(title: "Закрыть остальные (\(others))",
                        tint: Color(white: 0.85)) { model.armCloseOtherWindows() }
                .help(keepsHint)
        }
    }

    /// The count is a promise; this names what the promise spares. In the
    /// tooltip and not on the plate, because the plate has room for a
    /// number and the user has asked twice for fewer words in this panel.
    private var keepsHint: String {
        let main = windows.first(where: { $0.isMain })?.title
        return "Останется одно окно: " + (main ?? "—")
    }

    // MARK: A. Windows

    @ViewBuilder private var windowsHalf: some View {
        switch state.scan.failure {
        case .notTrusted:
            // DEGRADE, DO NOT BLOCK. The popover is open, the process half
            // below is drawn, and this half says the one true thing and
            // offers the one useful button. It never asks again by itself
            // — see AppWindowList.requestTrustOnce.
            VStack(alignment: .leading, spacing: 6) {
                Text("Список окон закрыт без «Универсального доступа»")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 0.62))
                SmallButton(title: "Открыть настройки", tint: Color(white: 0.85)) {
                    AppWindowList.openAccessibilitySettings()
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        case .notResponding:
            popoverNote("Приложение не отвечает")
        case .noSuchProcess:
            popoverNote("Процесс закрыт")
        case .unresolved:
            // Counted, but not readable — see WindowScanFailure.unresolved.
            // NO EXPLANATION ON THE PLATE, on purpose: the cause measured
            // here was a locked screen, which is not a state anybody can
            // be looking at this popover in, so any sentence naming a
            // cause would be a guess printed as a fact. It says what is
            // true and offers the one button that could help.
            VStack(alignment: .leading, spacing: 6) {
                Text("Окна не читаются")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 0.62))
                SmallButton(title: "Открыть настройки", tint: Color(white: 0.85)) {
                    AppWindowList.openAccessibilitySettings()
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        case nil:
            if windows.isEmpty {
                // A MEASURED ZERO, and the most interesting answer this
                // popover gives: a ten-process app with no windows at all.
                popoverNote("Окон нет")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(windows) { row in
                            WindowRowView(row: row) { model.closeWindow(id: row.id) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func popoverNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color(white: 0.45))
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }

    // MARK: B. Processes

    /// The one line. It is here instead of a per-process button because a
    /// button would be the footgun; see this file's header.
    private var processCaption: some View {
        HStack(spacing: 4) {
            Text("Процессы \(state.processes.count)")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.55))
            Text("— помощники, не окна: завершишь — потеряешь несохранённое, и они вернутся")
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.36))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 11)
        .padding(.horizontal, 6)
    }

    private var processHalf: some View {
        // Biggest first: the question is "which helper got fat", so the
        // answer is always in the first row.
        let sorted = state.processes.sorted { ($0.footprintBytes ?? 0) > ($1.footprintBytes ?? 0) }
        // NO "and N more" LINE. The caption above already prints the total
        // and the rows are the top of a sorted list, so a fourth line
        // would repeat a number that is already on screen — and it would
        // overflow the block's 33 pt, which is how the first render of
        // this section lost its last row to IslandRouter's `.clipped()`.
        let shown = sorted.prefix(PopoverMetrics.processRows)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown)) { proc in
                HStack(spacing: 6) {
                    Text(proc.name)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(white: 0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(UIFmt.bytes(proc.footprintBytes))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(Color(white: 0.55))
                }
                .frame(height: PopoverMetrics.processRow)
            }
        }
        .padding(.horizontal, 6)
    }
}
