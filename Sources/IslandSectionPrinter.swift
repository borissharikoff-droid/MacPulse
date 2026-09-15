import SwiftUI

// =====================================================================
// «Печать» — the Bambu P1S section, and the collapsed strip's ring.
//
// Registered through the router's documented extension point: an id, a
// section value, one line in IslandFeatures. Nothing in IslandRail.swift,
// IslandViews.swift or IslandRouter had to change to add it.
//
// THE CHIP IS ABSENT MOST OF THE TIME, AND THAT IS THE FEATURE. This
// printer is powered off far more often than it is printing. `hasState`
// is `model.printer != nil`, and `PrinterFeature.parse` returns nil for
// an idle printer, an unreachable printer AND an unreachable panel — so
// on a quiet machine the rail is one chip (Память) and the island is
// exactly what it was. An unreachable panel is not an error worth a red
// chip in the notch.
//
// NO THUMBNAIL, AND THAT IS NOT AN OVERSIGHT. The brief asked for the
// print's thumbnail. The local panel exposes no route that serves one: it
// can parse a thumbnail out of a .gcode file, but only via POST
// /api/gcode with the whole file as the body, which MacPulse cannot and
// must not do (PultLink has no POST path at all — that is what makes
// "never command the printer" structural). So the 96 pt tile holds a
// large progress ring tinted with the loaded filament's own colour
// instead, which is a real fact the panel does report.
//
// READ-ONLY. There are no buttons in this section. The panel it reads
// from exposes pause/resume/stop and this deliberately does not surface
// them: a mis-click that ruins a nine-hour print is not a risk worth
// carrying for a control nobody asked for.
// =====================================================================

extension IslandSectionID {
    static let printer = IslandSectionID("printer")
}

// MARK: - Collapsed strip slot

/// The ring in the trailing wing. On screen ONLY while there is a print,
/// because print progress is the one feature with an unrecoverable
/// deadline and therefore the only thing that has earned ambient pixels.
///
/// The ring IS the percentage, so it costs no digits; the number beside
/// it is the REMAINING TIME, because the question a glance actually asks
/// is "how long until I have to get up", not "how far along is it".
struct PrintStripSlot: View {
    let reading: PrinterReading
    let showsText: Bool

    private var tint: Color {
        if !reading.errorCodes.isEmpty || reading.stage == "FAILED" {
            return IslandPalette.critical
        }
        if reading.stage == "PAUSE" { return IslandPalette.warning }
        if reading.stage == "FINISH" { return IslandPalette.normal }
        return IslandPalette.hex(reading.trayColor, fallback: IslandPalette.printing)
    }

    var body: some View {
        HStack(spacing: IslandMetrics.ringTextGap) {
            ProgressRing(fraction: reading.fraction, tint: tint,
                         diameter: IslandMetrics.ringDiameter, lineWidth: 2.4)
            if showsText {
                Text(PrinterFeature.remaining(reading.remainMin))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.82))
                    .lineLimit(1)
                    // Fixed width so the strip does not resize when the
                    // estimate crosses an hour — "47м" and "1ч23" must
                    // occupy the same box.
                    .frame(width: IslandMetrics.slotTextWidth, alignment: .leading)
            }
        }
        .help(Self.tooltip(reading))
    }

    static func tooltip(_ r: PrinterReading) -> String {
        var parts: [String] = []
        parts.append(r.job ?? "Печать")
        if let p = r.percent { parts.append("\(p)%") }
        if let l = r.layer, let t = r.layersTotal, t > 0 { parts.append("слой \(l)/\(t)") }
        if r.remainMin != nil { parts.append("осталось " + PrinterFeature.remaining(r.remainMin)) }
        if !r.errorCodes.isEmpty { parts.append("ошибка " + r.errorCodes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A trimmed circle. `fraction == nil` draws the track and NO fill — the
/// printer genuinely has no percentage during PREPARE and SLICING, and an
/// empty ring is the honest rendering of that. A zero-length arc would
/// read as "0% done", which is a different and false claim.
struct ProgressRing: View {
    let fraction: Double?
    let tint: Color
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(white: 0.24), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - The 560 x 186 body

private struct PrinterSectionView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reading = model.printer {
                content(reading)
            } else {
                // Only reachable for the frame or two between a print
                // ending and the router dropping the chip.
                Text("Печать завершена")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
            }
            Spacer(minLength: 0)
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }

    private var tint: Color {
        guard let r = model.printer else { return IslandPalette.printing }
        if !r.errorCodes.isEmpty || r.stage == "FAILED" { return IslandPalette.critical }
        if r.stage == "PAUSE" { return IslandPalette.warning }
        if r.stage == "FINISH" { return IslandPalette.normal }
        return IslandPalette.hex(r.trayColor, fallback: IslandPalette.printing)
    }

    @ViewBuilder private func content(_ r: PrinterReading) -> some View {
        // --- header: job name + stage ---
        HStack(spacing: 8) {
            Text(r.job ?? "Без названия")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text((r.stageRu ?? r.stage ?? "—").uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
        }
        .frame(height: 18)

        Spacer(minLength: 0).frame(height: 10)

        HStack(alignment: .top, spacing: 16) {
            // --- the tile that would have been a thumbnail ---
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.08))
                ProgressRing(fraction: r.fraction, tint: tint, diameter: 74, lineWidth: 6)
                VStack(spacing: 0) {
                    Text(r.percent.map { "\($0)" } ?? "—")
                        .font(.system(size: 21, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 0) {
                // --- layers ---
                HStack(spacing: 6) {
                    Text("Слой")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(white: 0.5))
                    Text(layerLine(r))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color(white: 0.9))
                    Spacer(minLength: 8)
                    if let color = r.trayColor {
                        // The loaded filament, as the printer reports it.
                        HStack(spacing: 5) {
                            Circle()
                                .fill(IslandPalette.hex(color, fallback: IslandPalette.unknown))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 0.5))
                            Text("катушка")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(white: 0.42))
                        }
                    }
                }
                .frame(height: 16)

                Spacer(minLength: 0).frame(height: 7)

                // Layer progress, separate from the percent ring: they are
                // different numbers and the printer reports them
                // independently.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.16))
                        if let f = layerFraction(r) {
                            Capsule().fill(tint.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(f))
                        }
                    }
                }
                .frame(height: 5)

                Spacer(minLength: 0).frame(height: 12)

                // --- remaining + wall-clock ETA ---
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PrinterFeature.remaining(r.remainMin))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    if let eta = PrinterFeature.eta(r.remainMin) {
                        Text("готово ≈ \(eta)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Color(white: 0.55))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 24)

                Spacer(minLength: 0).frame(height: 10)

                // --- temperatures ---
                HStack(spacing: 14) {
                    TempReadout(label: "Сопло",
                                value: PrinterFeature.temperature(r.nozzle, target: r.nozzleTarget))
                    TempReadout(label: "Стол",
                                value: PrinterFeature.temperature(r.bed, target: r.bedTarget))
                    TempReadout(label: "Камера",
                                value: r.chamber.map { "\($0)°" } ?? "—")
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
            }
            .frame(height: 96, alignment: .top)
        }

        Spacer(minLength: 0).frame(height: 10)

        // --- errors, or the honest note about what this section is ---
        if !r.errorCodes.isEmpty {
            Text("Ошибка принтера: " + r.errorCodes.joined(separator: ", ")
                 + " — подробности на e.bambulab.com")
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.critical)
                .lineLimit(1)
                .frame(height: 12)
        } else {
            Text("Читается с локальной панели 127.0.0.1 раз в 8 с. Только просмотр — "
                 + "MacPulse не отправляет принтеру команд.")
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.34))
                .lineLimit(1)
                .frame(height: 12)
        }
    }

    private func layerLine(_ r: PrinterReading) -> String {
        switch (r.layer, r.layersTotal) {
        case let (l?, t?) where t > 0: return "\(l) / \(t)"
        case let (l?, _): return "\(l)"
        default: return "—"
        }
    }

    private func layerFraction(_ r: PrinterReading) -> Double? {
        guard let l = r.layer, let t = r.layersTotal, t > 0 else { return nil }
        return min(max(Double(l) / Double(t), 0), 1)
    }
}

private struct TempReadout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.42))
            Text(value)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.88))
        }
    }
}

// MARK: - Registration

extension IslandSection {
    static let printer = IslandSection(
        id: .printer,
        chipTitle: "Печать",
        chipSymbol: "printer",
        // Cheap and pure: one Optional read off a @Published property the
        // poller already wrote. No syscall, no I/O — see IslandSection.swift.
        hasState: { $0.printer != nil },
        footerSummary: { model in
            guard let r = model.printer else { return nil }
            if !r.errorCodes.isEmpty { return "Печать: ошибка" }
            if r.stage == "PAUSE" { return "Печать на паузе" }
            if r.stage == "FINISH" { return "Печать готова" }
            guard let p = r.percent else { return "Печать идёт" }
            return "Печать \(p)%"
        },
        makeBody: { model in AnyView(PrinterSectionView(model: model)) }
    )
}
