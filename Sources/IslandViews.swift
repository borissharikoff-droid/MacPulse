import AppKit
import SwiftUI

// =====================================================================
// The island's SwiftUI shell: palette, Russian-unit formatting, and the
// root view. Everything else lives beside it —
//
//   IslandStrip.swift          the two collapsed wings
//   IslandRail.swift           the expanded panel's router
//   IslandSectionMemory.swift  the «Память» section
//   IslandSection.swift        how to add another one
//
// It was one 522-line file holding palette + formatting + strip + hero +
// rows + buttons + root. Splitting it was not tidiness: the panel is a
// router now, and the next feature to land would otherwise have piled its
// section onto the same file as the pressure dot.
//
// TWO LAYOUT FACTS DRIVE EVERYTHING HERE:
//
// 1. The notch is a PHYSICAL camera housing. Anything drawn in the middle
//    `notchSize.width` points of the strip is invisible — it is behind
//    opaque glass. So the collapsed readout lives in the wings either
//    side of the housing, and the centre column is deliberately empty.
//
// 2. MPNotchShape's concave top fillets live OUTSIDE the visual body, so
//    the shape's total width is `contentWidth + 2 * topCornerRadius` and
//    the content has to be padded horizontally by `topCornerRadius` or
//    the fillets clip it.
//
// The window frame never changes (see IslandController). Only these views
// animate. Resizing an NSWindow per animation frame is a synchronous
// round-trip to the window server and is the #1 cause of jank and of
// tearing against the menu bar.
// =====================================================================

// MARK: - Palette and formatting

enum IslandPalette {
    static let normal = Color(red: 0.30, green: 0.83, blue: 0.42)
    static let warning = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let critical = Color(red: 1.00, green: 0.36, blue: 0.32)
    /// Used for "could not measure". Never for a measured zero.
    static let unknown = Color(white: 0.45)

    // NO micInUse / cameraInUse HERE ANY MORE. They existed for the two
    // dots in the collapsed trailing wing, and they were the system's own
    // orange and green precisely because they were restating the system's
    // own indicator. That was the argument for deleting the dots; see
    // IslandPrivacyLine.swift. The footer clause that replaced them is
    // plain text at the footer's own colour and borrows nothing.

    /// The print ring when the panel could not tell us a filament colour.
    static let printing = Color(red: 0.36, green: 0.72, blue: 1.00)

    /// "#RRGGBB" from the printer's AMS, already validated by
    /// `PrinterFeature.parse`. Anything else falls back rather than
    /// trapping — this string came off the network into another process
    /// before it reached us.
    static func hex(_ string: String?, fallback: Color) -> Color {
        guard let string, string.count == 7, string.hasPrefix("#"),
              let value = UInt32(string.dropFirst(), radix: 16) else { return fallback }
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    static func color(for level: MemoryPressureLevel?) -> Color {
        switch level {
        case .normal: return normal
        case .warning: return warning
        case .critical: return critical
        case nil: return unknown
        }
    }

    static func label(for level: MemoryPressureLevel?) -> String {
        switch level {
        case .normal: return "Норма"
        case .warning: return "Предупреждение"
        case .critical: return "Критично"
        case nil: return "—"
        }
    }
}

/// Russian-unit formatting for the island. `Fmt` stays as it is because
/// the diagnostic probe shares it; this is the UI-facing twin.
///
/// Every function takes an Optional and returns "—" for nil. A `nil` is
/// "could not measure"; a present 0.0 is a real, measured zero (the ANE
/// genuinely idles at exactly 0 W) and prints as 0.
enum UIFmt {
    static func bytes(_ v: UInt64?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        return bytes(Double(v), digits)
    }

    static func bytes(_ v: Double?, _ digits: Int = 1) -> String {
        guard let v else { return "—" }
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var x = abs(v), i = 0
        while x >= 1024, i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: "%.\(i <= 1 ? 0 : digits)f %@", v < 0 ? -x : x, units[i])
    }

    static func rate(_ v: Double?) -> String {
        guard let v else { return "—" }
        return bytes(v, 1) + "/с"
    }

    /// Compressor traffic is always talked about in MB/s in the research,
    /// so it gets its own fixed-unit formatter — a number that jumps
    /// between "900 КБ/с" and "1.2 ГБ/с" is unreadable as a trend.
    static func mbps(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f МБ/с", v / 1_048_576)
    }

    static func pct(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f%%", v * 100)
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f Вт", v)
    }

    /// Unit-less twin for side-by-side pairs, so "7.37/0.28 Вт" fits where
    /// "7.37 Вт / 0.28 Вт" would wrap.
    static func shortWatts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f", v)
    }

    static func celsius(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f°C", v)
    }

    static func perSec(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f/с", v)
    }

    static func pages(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f стр/с", v)
    }

    static func count(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f", v)
    }

    /// Two rates sharing ONE unit, picked from the larger of the pair:
    /// "0.9/0.9 КБ/с". Formatting them independently produces
    /// "940 Б/с / 940 Б/с", which does not fit a mini stat and truncates.
    static func pairRate(_ a: Double?, _ b: Double?) -> String {
        guard let a, let b else { return "—" }
        let units = ["Б", "КБ", "МБ", "ГБ"]
        var i = 0
        var scale = 1.0
        while max(a, b) / scale >= 1024, i < units.count - 1 { scale *= 1024; i += 1 }
        let digits = i == 0 ? 0 : 1
        return String(format: "%.\(digits)f/%.\(digits)f %@/с", a / scale, b / scale, units[i])
    }
}

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: IslandModel

    private var isOpen: Bool { model.status == .opened }

    /// The plate this state draws, straight out of IslandMetrics. The
    /// CONTROLLER hit-tests the very same values — that is the point of
    /// there being one function. Never open-code the arithmetic here.
    private var plate: IslandMetrics.Plate {
        switch model.status {
        case .opened:
            return IslandMetrics.openedPlate()
        case .popping:
            return IslandMetrics.collapsedPlate(notch: model.notchSize,
                                                leading: model.leadingWingWidth,
                                                trailing: model.trailingWingWidth,
                                                popping: true)
        case .closed:
            return IslandMetrics.collapsedPlate(notch: model.notchSize,
                                                leading: model.leadingWingWidth,
                                                trailing: model.trailingWingWidth)
        }
    }

    private var topCornerRadius: CGFloat { plate.fillet }

    private var bottomCornerRadius: CGFloat {
        switch model.status {
        case .opened: return 24
        case .popping: return 11
        case .closed: return 14
        }
    }

    /// Plate minus the fillets: what the content actually gets.
    private var contentWidth: CGFloat { plate.size.width - plate.fillet * 2 }
    private var bodyHeight: CGFloat { plate.size.height }

    /// Wing widths for THIS state. Collapsed they are the model's two
    /// (asymmetric) values; open the panel is symmetric about the housing
    /// and both sides are whatever is left of 560.
    private var leadingStripWidth: CGFloat {
        isOpen ? max(0, (contentWidth - model.notchSize.width) / 2) : model.leadingWingWidth
    }
    private var trailingStripWidth: CGFloat {
        isOpen ? max(0, (contentWidth - model.notchSize.width) / 2) : model.trailingWingWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            island
                // The panel spans the whole screen width and centres its
                // content, so an asymmetric island has to slide to keep the
                // camera housing — which is physical and does not move —
                // under the middle column. Same number the controller
                // offsets its hit rect by.
                .offset(x: plate.centerOffsetX)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- the strip that straddles the camera housing ---
            HStack(spacing: 0) {
                IslandLeadingWing(pressure: model.strip.pressure)
                    .frame(width: leadingStripWidth,
                           height: model.notchSize.height, alignment: .trailing)

                // The camera housing. NEVER draw here: it is opaque glass.
                Color.clear
                    .frame(width: model.notchSize.width, height: model.notchSize.height)

                IslandTrailingWing(model: model, availableWidth: trailingStripWidth)
                    .frame(width: trailingStripWidth,
                           height: model.notchSize.height, alignment: .leading)
            }

            // --- the panel, only in the tree while it is out ---
            if isOpen {
                IslandRouter(model: model)
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    )
            }
        }
        .frame(width: contentWidth, height: bodyHeight, alignment: .top)
        // SwiftUI still hit-tests zero-frame subtrees; gate it explicitly.
        .allowsHitTesting(isOpen)
        .padding(.horizontal, topCornerRadius)   // the fillets live OUTSIDE the body
        .background {
            // Inflated black plate: a bouncy spring OVERSHOOTS the frame,
            // and without the -50 the overshoot exposes transparent pixels
            // at the edges mid-animation.
            Rectangle().fill(Color.black).padding(-50)
        }
        .mask { maskShape }
        .overlay(alignment: .top) {
            // Hairline patch: covers the 1px gap between the top of the
            // drawn shape and the physical notch glass. Pointless (and
            // wrong) on a free-floating pill.
            if model.hasPhysicalNotch {
                Rectangle().fill(Color.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
        }
        .shadow(color: .black.opacity(isOpen || !model.hasPhysicalNotch ? 0.65 : 0), radius: 14, y: 6)
        .fixedSize()
    }

    /// On a notched display the body melts into the menu bar with concave
    /// top fillets. On a notchless one (external display, clamshell, a Mac
    /// with no camera housing) those fillets have nothing to melt into and
    /// read as a rendering bug, so the fallback is an ordinary floating
    /// pill that the controller positions BELOW the menu bar.
    @ViewBuilder private var maskShape: some View {
        if model.hasPhysicalNotch {
            MPNotchShape(topCornerRadius: topCornerRadius,
                         bottomCornerRadius: bottomCornerRadius)
                // Kills the sub-pixel light seam at the notch sides on 2x.
                .padding(.horizontal, 0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            RoundedRectangle(cornerRadius: isOpen ? 22 : 16, style: .continuous)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
