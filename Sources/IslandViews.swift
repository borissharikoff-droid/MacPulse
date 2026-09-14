import AppKit
import SwiftUI

// =====================================================================
// The island's SwiftUI layer.
//
// TWO LAYOUT FACTS DRIVE EVERYTHING HERE:
//
// 1. The notch is a PHYSICAL camera housing. Anything drawn in the middle
//    `notchSize.width` points of the strip is invisible — it is behind
//    opaque glass. So the collapsed readout lives in the menu bar strip
//    immediately LEFT and RIGHT of the housing, and the centre column is
//    deliberately empty.
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

// MARK: - Sparkline

/// Compressor decompression rate over the last ~60 s at 2 s resolution.
/// This is the differentiator: sustained decompression is exactly when the
/// machine "feels slow", it never touches the disk, and no shipping
/// monitor displays it.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var lineWidth: CGFloat = 1.4

    /// Floor the vertical scale at 8 MB/s so an idle machine draws a flat
    /// line near the bottom instead of amplifying noise into a mountain
    /// range.
    private static let floorScale: Double = 8 * 1_048_576

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let peak = max(values.max() ?? 0, Self.floorScale)
            let dx = size.width / CGFloat(values.count - 1)
            let y: (Double) -> CGFloat = { v in
                size.height - CGFloat(min(v / peak, 1)) * (size.height - lineWidth) - lineWidth / 2
            }

            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(values[0])))
            for i in 1..<values.count {
                line.addLine(to: CGPoint(x: dx * CGFloat(i), y: y(values[i])))
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.45), tint.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            ctx.stroke(line, with: .color(tint), lineWidth: lineWidth)
        }
        // Deliberately NOT .drawingGroup(): for a two-path Canvas this size
        // the offscreen Metal render costs more than it saves, and it would
        // be paid once a second forever.
    }
}

// MARK: - Small building blocks

private struct Cell: View {
    let title: String
    let value: String
    var tint: Color = .white
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(white: 0.55))
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color(white: 0.45))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MiniStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Color(white: 0.48))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.86))
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PressureDot: View {
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

// MARK: - Collapsed strip content

/// LEFT of the camera housing: the kernel's own pressure verdict, and the
/// decompression sparkline. Nothing else — there is room for about two
/// glyphs and a number, and putting CPU% here instead is the single most
/// common design mistake in this category.
private struct LeadingStrip: View {
    let level: MemoryPressureLevel?
    let spark: [Double]
    let current: Double?

    var body: some View {
        HStack(spacing: 6) {
            PressureDot(level: level)
            Sparkline(values: spark, tint: IslandPalette.color(for: level))
                .frame(width: 54, height: 16)
        }
        .padding(.trailing, 8)
    }
}

/// RIGHT of the camera housing: the single largest app by phys_footprint.
/// Name plus size, nothing else.
private struct TrailingStrip: View {
    let app: AppUsage?

    var body: some View {
        HStack(spacing: 5) {
            Text(app?.name ?? "—")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color(white: 0.72))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(UIFmt.bytes(app?.footprintBytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.leading, 8)
    }
}

// MARK: - Expanded dashboard

private struct MemoryHero: View {
    let memory: MemoryMetrics?
    let spark: [Double]

    private var tint: Color { IslandPalette.color(for: memory?.pressureLevel) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PressureDot(level: memory?.pressureLevel, size: 9)
                    Text(IslandPalette.label(for: memory?.pressureLevel))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text("Давление памяти (ядро)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.5))

                // Bar height only. This is a (wired + compressed) / total
                // heuristic, NOT Apple's formula — Apple documents the
                // factors and never the expression — so it is never
                // labelled "как в Мониторинге системы". The COLOUR comes
                // from the kernel's own pressure level above.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.18))
                        Capsule().fill(tint)
                            .frame(width: geo.size.width * CGFloat(min(memory?.pressureHeuristic ?? 0, 1)))
                    }
                }
                .frame(height: 5)
                .padding(.top, 2)

                Text("\(UIFmt.bytes(memory?.usedBytes)) из \(UIFmt.bytes(memory?.totalBytes)) занято")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.55))
            }
            .frame(width: 190)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(UIFmt.mbps(memory?.rates?.decompressionBytesPerSec))
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("распаковка компрессора")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(white: 0.5))
                }
                Sparkline(values: spark, tint: tint, lineWidth: 1.6)
                    .frame(height: 38)
                Text("60 с, шаг 2 с · выше 50 МБ/с — это и есть «тормозит»")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color(white: 0.38))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MemoryRatesRow: View {
    let memory: MemoryMetrics?

    var body: some View {
        let r = memory?.rates
        HStack(alignment: .top, spacing: 10) {
            Cell(title: "СЖАТИЕ", value: UIFmt.mbps(r?.compressionBytesPerSec),
                 detail: UIFmt.pages(r?.compressionsPerSec))
            Cell(title: "РАСПАКОВКА", value: UIFmt.mbps(r?.decompressionBytesPerSec),
                 detail: UIFmt.pages(r?.decompressionsPerSec))
            Cell(title: "ПОДКАЧКА", value: UIFmt.mbps(r?.pageInBytesPerSec),
                 detail: UIFmt.pages(r?.pageInsPerSec))
            // Rate, not size — and on this machine it is normally 0 while
            // the compressor above is doing 50+ MB/s. Showing them side by
            // side is how the user learns swap is not the problem.
            Cell(title: "СВОП ЗАП / ЧТ",
                 value: "\(UIFmt.count(r?.swapOutsPerSec)) / \(UIFmt.count(r?.swapInsPerSec))",
                 detail: "стр/с")
            Cell(title: "СВОП ЗАНЯТО", value: UIFmt.bytes(memory?.swapUsedBytes),
                 detail: "из \(UIFmt.bytes(memory?.swapTotalBytes))")
            Cell(title: "СЖАТО", value: UIFmt.bytes(memory?.compressedBytes),
                 detail: memory?.compressionRatio.map { String(format: "×%.1f сжатие", $0) } ?? "—")
        }
    }
}

private struct AppRow: View {
    let app: AppUsage
    let phase: QuitPhase
    let onQuit: () -> Void
    let onForce: () -> Void

    @State private var hovering = false

    private var icon: NSImage? {
        NSRunningApplication(processIdentifier: app.pid)?.icon
    }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.22))
                    .frame(width: 15, height: 15)
            }

            Text(app.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(white: 0.9))
                .lineLimit(1)
                .truncationMode(.middle)

            if app.memberPIDs.count > 1 {
                Text("\(app.memberPIDs.count)")
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.16)))
                    .help("процессов в группе: \(app.memberPIDs.count)")
            }

            Spacer(minLength: 6)

            Text(UIFmt.pct(app.cpuPercent.map { $0 / 100 }))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 42, alignment: .trailing)

            Text(UIFmt.bytes(app.footprintBytes))
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
            if app.isApplication {
                SmallButton(title: "Завершить", tint: Color(white: 0.85), onTap: onQuit)
            } else {
                // Not an NSRunningApplication: a daemon or helper we have no
                // safe, graceful way to stop. We show the footprint and stop
                // there — MacPulse never kills anything the user did not
                // individually click, and there is nothing to click here.
                Text("фоновый процесс")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.38))
            }
        case .asked:
            Text("закрывается…")
                .font(.system(size: 9.5))
                .foregroundStyle(Color(white: 0.55))
        case .needsForce:
            // SECOND, EXPLICIT step, offered only because the graceful
            // quit demonstrably did not take. Never automatic.
            SmallButton(title: "Принудительно", tint: IslandPalette.critical, onTap: onForce)
                .help("Приложение не закрылось само — возможно, есть несохранённые изменения. Принудительное завершение их потеряет.")
        case .forced:
            Text("завершается…")
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.critical.opacity(0.8))
        case .gone:
            Text("закрыто ✓")
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.normal)
        case .failed(let why):
            Text(why)
                .font(.system(size: 9))
                .foregroundStyle(IslandPalette.warning)
        }
    }
}

private struct SmallButton: View {
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

private struct SystemStrip: View {
    let snapshot: MetricsSnapshot?

    var body: some View {
        let cpu = snapshot?.cpu
        let p = snapshot?.power
        let t = snapshot?.thermal
        HStack(alignment: .top, spacing: 8) {
            MiniStat(title: "CPU P/E",
                     value: "\(UIFmt.pct(cpu?.performance?.load.busy))/\(UIFmt.pct(cpu?.efficiency?.load.busy))")
            MiniStat(title: "GPU", value: UIFmt.pct(snapshot?.gpu?.utilization))
            MiniStat(title: "ВТ CPU/GPU",
                     value: "\(UIFmt.shortWatts(p?.cpuWatts))/\(UIFmt.shortWatts(p?.gpuWatts))")
            MiniStat(title: "СИСТЕМА", value: UIFmt.watts(p?.systemWatts))
            // cpuPeakCelsius is a HOT-SPOT sensor: this M2 carries three
            // sensors per P-core and the third runs 10-25 C above its
            // siblings, so it reads ~100 C on a machine that is fine.
            // Labelling it "температура CPU" would be a lie.
            MiniStat(title: "ГОР. ТОЧКА",
                     value: UIFmt.celsius(t?.cpuPeakCelsius))
            MiniStat(title: "P/E °C",
                     value: "\(UIFmt.celsius(t?.cpuPerformanceCelsius))/\(UIFmt.celsius(t?.cpuEfficiencyCelsius))")
            MiniStat(title: "ТЕРМО",
                     value: (t?.state.label).map(ruThermal) ?? "—")
            MiniStat(title: "БАТАРЕЯ",
                     value: UIFmt.pct(snapshot?.battery?.charge))
            MiniStat(title: "ДИСК ЗАП", value: UIFmt.rate(snapshot?.disk?.writeBytesPerSec))
            MiniStat(title: "СЕТЬ ↓/↑",
                     value: UIFmt.pairRate(snapshot?.network?.bytesInPerSec,
                                           snapshot?.network?.bytesOutPerSec))
                .frame(minWidth: 84)
        }
    }

    private func ruThermal(_ s: String) -> String {
        switch s {
        case "Nominal": return "норма"
        case "Fair": return "умерен."
        case "Serious": return "высокий"
        case "Critical": return "критич."
        default: return s
        }
    }
}

private struct Dashboard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryHero(memory: model.snapshot?.memory, spark: model.spark)

            Divider().overlay(Color(white: 0.16))

            MemoryRatesRow(memory: model.snapshot?.memory)

            Divider().overlay(Color(white: 0.16))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("ВАШИ ПРИЛОЖЕНИЯ — ПО PHYS_FOOTPRINT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(white: 0.55))
                    Spacer()
                    if let pm = model.snapshot?.processes {
                        // Honest coverage note: unprivileged we can only
                        // introspect our OWN uid, so this is never "все
                        // процессы". top sees everything only because it is
                        // setuid root.
                        Text("видно \(pm.introspectedCount) из \(pm.pidCount) процессов (только ваш пользователь)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color(white: 0.38))
                    }
                }
                .padding(.horizontal, 6)

                if model.topApps.isEmpty {
                    Text("—").font(.system(size: 11)).foregroundStyle(Color(white: 0.4))
                        .padding(.horizontal, 6)
                }
                ForEach(model.topApps) { app in
                    AppRow(app: app,
                           phase: model.quitPhase(for: app.pid),
                           onQuit: { model.requestQuit(app) },
                           onForce: { model.forceQuit(app) })
                }
            }

            Spacer(minLength: 0)

            Divider().overlay(Color(white: 0.16))

            SystemStrip(snapshot: model.snapshot)
        }
    }
}

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: IslandModel

    /// Fixed expanded geometry. The WINDOW never changes size; only this
    /// content does.
    static let expandedContentWidth: CGFloat = 700
    static let expandedHeight: CGFloat = 402
    /// How much readout sits either side of the camera housing when
    /// collapsed.
    static let collapsedSideWidth: CGFloat = 104

    private var isOpen: Bool { model.status == .opened }

    private var topCornerRadius: CGFloat { isOpen ? 19 : 6 }
    private var bottomCornerRadius: CGFloat {
        switch model.status {
        case .opened: return 24
        case .popping: return 11
        case .closed: return 14
        }
    }

    private var contentWidth: CGFloat {
        isOpen
            ? Self.expandedContentWidth
            : model.notchSize.width + Self.collapsedSideWidth * 2
    }

    private var bodyHeight: CGFloat {
        switch model.status {
        case .opened: return Self.expandedHeight
        case .popping: return model.notchSize.height + 3
        case .closed: return model.notchSize.height
        }
    }

    private var sideWidth: CGFloat {
        max(0, (contentWidth - model.notchSize.width) / 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var island: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- the strip that straddles the camera housing ---
            HStack(spacing: 0) {
                LeadingStrip(level: model.pressureLevel,
                             spark: model.spark,
                             current: model.snapshot?.memory?.rates?.decompressionBytesPerSec)
                    .frame(width: sideWidth, height: model.notchSize.height, alignment: .trailing)

                // The camera housing. NEVER draw here: it is opaque glass.
                Color.clear
                    .frame(width: model.notchSize.width, height: model.notchSize.height)

                TrailingStrip(app: model.topApp)
                    .frame(width: sideWidth, height: model.notchSize.height, alignment: .leading)
            }

            // --- the dashboard, only in the tree while it is out ---
            if isOpen {
                Dashboard(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .frame(width: contentWidth, alignment: .leading)
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
