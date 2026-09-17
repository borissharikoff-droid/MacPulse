import Foundation
import SwiftUI

// =====================================================================
// «Туннель» — who is carrying this machine's traffic, and the collapsed
// strip's branch glyph.
//
// Registered through the router's documented extension point: an id, a
// section value, one line in IslandFeatures. Nothing in IslandRail.swift,
// IslandViews.swift or IslandRouter had to change to add it.
//
// THE CHIP IS ABSENT UNLESS THE ANSWER IS SURPRISING. `hasState` is
// `model.tunnel?.deservesStripSlot == true`, which the engine sets only
// when traffic leaves through a TUNNEL that is NOT the default route.
// That is the architecture spike's rule, and it is doing real work: a
// laptop with no VPN has no chip, and so does a laptop whose always-on
// full-tunnel VPN owns 0.0.0.0/0, because a permanently-lit VPN badge is
// noise. What earns the chip is the case on this machine — the default
// route says en0 while every packet leaves through utun6.
//
// FOUR WORDS THIS SECTION WILL NOT SAY. There is no "выкл", no "off", no
// "disconnected" and no "0". "Не установлен" and "установлен,
// простаивает" are different facts about different machines, and blurring
// them into one word is a lie about software that is not there. Where the
// engine could not measure, the section prints "—", never a zero.
//
// STATUS ONLY — the one verb is «Открыть». There is no connect, no
// disconnect and no toggle, and this is not an unfinished control panel:
// neither installed tool can be switched without sudo or a private
// socket, FlClashX is carrying 100% of this machine's traffic, and a
// failed toggle would drop the user offline with no reliable way back to
// their own profile. The honest offer is to open the app they already
// have. See the header of TunnelSampler.swift.
//
// ---------------------------------------------------------------------
// WHAT THIS SECTION SAYS, AFTER THE CUT
//
// Two facts, and the user asked for exactly these two:
//
//     WHO CARRIES THE TRAFFIC        FlClashX · несёт трафик · utun6
//     WHERE HE APPEARS TO BE         203.23.179.147 · DE · FRA
//
// Four sentences used to live on this panel and do not any more. Each of
// them was TRUE and each of them was a paragraph on a 560 pt strip the
// user reads in two seconds. They were cut on his instruction — "убери
// весь лишний текст, читается из таблицы маршрут — это ничего не надо" —
// said twice, about this section. The engineering behind every one of
// them is intact and is still written down, in the place an engineer
// actually looks:
//
//   THE DECOY LINE. «Маршрут по умолчанию — en0, и он обманка: трафик
//     уходит через utun6.» WHY the default route lies — Clash never
//     replaces 0.0.0.0/0, it installs eight more-specific splits that
//     together cover every routable address — is the single biggest trap
//     in this feature and is documented at length under "THE ONE IDEA" in
//     TunnelSampler.swift. It belongs to whoever maintains the query, not
//     to whoever glances at the panel. `defaultRouteInterface` is still
//     sampled and still decides `deservesStripSlot`; it is simply no
//     longer narrated.
//
//   THE NOT-AN-EXIT-ADDRESS DISCLAIMER. «адрес интерфейса 198.18.0.1 —
//     это не адрес выхода.» Cut by DELETING THE ADDRESS, which is the
//     better fix: 198.18.0.1 is an RFC 2544 benchmarking address that
//     nobody needed on screen, and the disclaimer only existed because it
//     was there. There is now exactly ONE IP on this panel and it is the
//     real one — see GeoLookup.swift. A caveat you can delete by deleting
//     what it warns about is a caveat that was never the answer.
//
//   THE STANDING NOTE. «Читается из таблицы маршрутов ядра, ни один пакет
//     никуда не отправляется…» An assurance about the implementation,
//     addressed to a reader who was not worried. Still true, still
//     enforced — by build.sh's PF_ROUTE guard, which is a check and not a
//     sentence.
//
//   THE IPv6 CAVEAT. «На машине есть глобальный IPv6, а замер идёт только
//     по IPv4…» A real limitation of the engine and a genuine reason a
//     v6-only tunnel could hide from it. It is an engineer's caveat, so it
//     went where engineers are: `TunnelMetrics.hasGlobalIPv6` still
//     carries it and `--tunnel-probe` still prints it.
//
//   AND THE CONFIDENCE ANNOTATION. «utun6 (по документации)» — the
//     difference between a signature observed here and one read out of a
//     vendor's PDF. `signatureConfidence` still records it and the probe
//     still prints it; a tool row is four columns wide and had no room to
//     argue with itself.
//
// WHAT SURVIVES IS NOT PROSE. The badges («НЕСЁТ ТРАФИК»,
// «РАСЩЕПЛЁННЫЙ МАРШРУТ») are states, two words each. The tool rows are a
// table. The launch caution is the one sentence left, and it appears only
// in the moment the user has clicked «Открыть» on a tool that could
// auto-connect — i.e. only when it is the thing he is doing.
// =====================================================================

extension IslandSectionID {
    static let tunnel = IslandSectionID("tunnel")
}

// MARK: - Palette and words

/// The section's own accent. NOT in `IslandPalette`: that enum is shared
/// chrome and this is one feature's colour, the same way the printer takes
/// its tint from the loaded filament rather than adding a constant.
///
/// Violet on purpose — it is neither `normal` green nor `critical` red,
/// because a tunnel carrying traffic is not a health verdict at all. It is
/// a fact about where the packets go.
private enum TunnelPalette {
    static let carrying = Color(red: 0.64, green: 0.56, blue: 1.00)
    /// A tunnel is carrying, but we cannot name it. Not an error — an
    /// incomplete answer, and amber is what the panel already uses for
    /// that.
    static let unnamed = IslandPalette.warning
    /// Installed and idle. Present, quiet.
    static let idle = Color(white: 0.55)
    /// Not installed. Dimmer than idle ON PURPOSE: the row is there to say
    /// "there is nothing here", and it should read as the quietest line on
    /// the panel.
    static let absent = Color(white: 0.30)
}

/// The Russian. The engine is language-neutral by design — exactly like
/// `MemoryPressureLevel` — so every word the user reads is chosen here.
private enum TunnelWords {

    static func state(_ state: TunnelToolState) -> String {
        switch state {
        // NOT "выключен". The application is not on this machine.
        case .notInstalled:    return "не установлен"
        case .installedIdle:   return "установлен, простаивает"
        case .carryingTraffic: return "несёт трафик"
        case .upNotCarrying:   return "поднят, не несёт"
        case .cannotDetermine: return "не удалось определить"
        }
    }

    static func tint(_ state: TunnelToolState) -> Color {
        switch state {
        case .notInstalled:    return TunnelPalette.absent
        case .installedIdle:   return TunnelPalette.idle
        case .carryingTraffic: return TunnelPalette.carrying
        case .upNotCarrying:   return IslandPalette.warning
        case .cannotDetermine: return IslandPalette.unknown
        }
    }

    /// The headline: who is carrying traffic, in three words or fewer.
    static func headline(_ m: TunnelMetrics) -> String {
        guard let carrier = m.carrier else { return "—" }
        if let tool = m.carryingTool { return tool.displayName }
        if carrier.isTunnel { return "Неизвестный туннель" }
        return "Без туннеля"
    }

    static func headlineTint(_ m: TunnelMetrics) -> Color {
        guard let carrier = m.carrier else { return IslandPalette.unknown }
        if m.carryingTool != nil { return TunnelPalette.carrying }
        if carrier.isTunnel { return TunnelPalette.unnamed }
        return Color(white: 0.72)
    }

    /// The badge beside the headline.
    static func headlineBadge(_ m: TunnelMetrics) -> String {
        guard let carrier = m.carrier else { return "НЕТ ЗАМЕРА" }
        return carrier.isTunnel ? "НЕСЁТ ТРАФИК" : "ПРЯМОЕ СОЕДИНЕНИЕ"
    }

    /// The carrier's interface, and its MTU because it is a number and not
    /// a sentence.
    ///
    /// THE INTERFACE'S OWN IPv4 IS DELIBERATELY NOT HERE. On a Clash
    /// fake-ip tunnel it is 198.18.0.1 — an RFC 2544 benchmarking address
    /// that is not a peer and not an exit node — and the old line printed
    /// it followed by a clause explaining that it was not an exit node.
    /// Deleting the address deletes the need for the clause, and leaves
    /// this panel with exactly one IP on it: the one the world actually
    /// sees. `TunnelCarrier.ipv4` is still sampled, still in the tooltip's
    /// `reason`, and still printed by `--tunnel-probe`.
    static func carrierDetail(_ m: TunnelMetrics) -> String {
        guard let c = m.carrier else { return "—" }
        guard let mtu = c.mtu else { return c.interface }
        return "\(c.interface) · MTU \(mtu)"
    }

    /// The address the world currently sees. A dash when we could not ask,
    /// and a dash is the whole message — see GeoLookup.swift.
    static func outsideAddress(_ g: GeoReading?) -> String {
        g?.ip ?? "—"
    }

    /// Where that address appears to be: ISO country and the Cloudflare
    /// edge that answered. Never invented, never geocoded further than the
    /// endpoint itself went.
    static func outsideWhere(_ g: GeoReading?) -> String {
        guard let g else { return "—" }
        let parts = [g.country, g.colo].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// The trailing column of a tool row: which interface, if we can pin
    /// one. Just the name — the verified/documented distinction is real
    /// but it is an engineer's distinction, and it is still on
    /// `signatureConfidence` and still printed by `--tunnel-probe`.
    static func interfaceDetail(_ status: TunnelToolStatus) -> String {
        status.attributedInterface ?? "—"
    }

    /// The footer clause, shown only while some OTHER section is selected.
    /// nil whenever the chip is not live, so the two can never disagree.
    static func footerClause(_ m: TunnelMetrics?) -> String? {
        guard let m, m.deservesStripSlot == true else { return nil }
        guard let tool = m.carryingTool else { return "Туннель: неизвестный" }
        return "Туннель: \(tool.displayName)"
    }
}

// MARK: - Collapsed strip slot

// MARK: - The 560 x 186 body
//
//   22  headline          who carries it   |  right: interface · MTU
//    6  gap
//   26  СНАРУЖИ           the public IP    |  right: country · colo
//    8  gap
//    1  divider
//    7  gap
//   88  four tool rows    22 each, one per tool this engine can name
//    6  gap
//   18  note zone         EMPTY, unless a launch is waiting for a yes
//  ---
//  182, inside the 186 the router hands over.
//
// Two lines above the divider where there used to be three, and the two
// that are left are both answers rather than commentary. The note zone
// holds its 18 pt whether or not anything is in it, so arming a launch
// does not make the tool rows jump.

private struct TunnelSectionView: View {
    @ObservedObject var model: IslandModel

    /// The public address, asked for lazily and only while this section is
    /// on screen. A second ObservableObject rather than a field on
    /// IslandModel: nothing outside this body reads it, and IslandModel is
    /// a shared file. See the class comment in GeoLookup.swift.
    @ObservedObject private var geo = GeoLookup.shared

    /// The tool whose «Открыть» was clicked and whose `launchCaution` is
    /// still waiting for a yes. Nothing is launched while this is set.
    ///
    /// View state rather than model state on purpose: an unconfirmed
    /// intention is not a fact about the machine, and it must not survive
    /// the panel closing. Reopening the panel starts from "nothing armed",
    /// which is the safe end.
    @State private var armed: TunnelTool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let m = model.tunnel {
                content(m)
            } else {
                // Reachable only in the frame or two before the first
                // sample lands, or after the watcher has stopped.
                Text("Туннели ещё не измерены")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
            }
            Spacer(minLength: 0)
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
        // THE ONLY TRIGGER FOR THE ONE NETWORK CALL. SwiftUI runs this
        // when this body enters the tree, which IslandRouter builds only
        // while the panel is open and only for the SELECTED section — so
        // "the user opened Туннель" and nothing else. Never at launch,
        // never on the 1 Hz tick.
        .onAppear { geo.sectionAppeared() }
        .onDisappear { geo.sectionDisappeared() }
        // A tunnel flipped while the user was watching. The public address
        // is precisely the thing that just changed, so throw the cached
        // answer away and ask again — that IS the feature.
        .onChange(of: model.tunnel?.carrier?.interface) { _ in
            geo.carrierChanged()
        }
    }

    @ViewBuilder private func content(_ m: TunnelMetrics) -> some View {
        // --- headline: who is carrying traffic ---
        HStack(spacing: 8) {
            Text(TunnelWords.headline(m))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TunnelWords.headlineTint(m))
                .lineLimit(1)
            Text(TunnelWords.headlineBadge(m))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(TunnelWords.headlineTint(m))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(TunnelWords.headlineTint(m).opacity(0.14)))
            if m.routeIsSplit {
                Text("РАСЩЕПЛЁННЫЙ МАРШРУТ")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(IslandPalette.warning)
            }
            Spacer(minLength: 8)

            // The interface, on the same line as the tool that owns it.
            Text(TunnelWords.carrierDetail(m))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.50))
                .lineLimit(1)
        }
        .frame(height: 22)

        Spacer(minLength: 0).frame(height: 6)

        // --- СНАРУЖИ: the address the world currently sees ---
        //
        // One word of label, because after deleting the interface address
        // this is the only IP on the panel and it must be unmistakable
        // which side of the tunnel it is on. Everything else this line
        // could have said is in GeoLookup.swift.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("СНАРУЖИ")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(white: 0.38))

            Text(TunnelWords.outsideAddress(geo.reading))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(geo.reading?.ip == nil
                                 ? Color(white: 0.40) : Color(white: 0.93))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(TunnelWords.outsideWhere(geo.reading))
                .font(.system(size: 12, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(geo.reading == nil
                                 ? Color(white: 0.40) : TunnelPalette.carrying)
                .lineLimit(1)
        }
        .frame(height: 26)

        Spacer(minLength: 0).frame(height: 8)

        Rectangle()
            .fill(Color(white: 0.16))
            .frame(height: 1)

        Spacer(minLength: 0).frame(height: 7)

        // --- one row per tool this engine can name ---
        VStack(spacing: 0) {
            ForEach(TunnelTool.allCases, id: \.self) { tool in
                if let status = m.status(of: tool) {
                    TunnelToolRow(status: status,
                                  detail: TunnelWords.interfaceDetail(status),
                                  isArmed: armed == tool,
                                  onOpen: { open(status) })
                }
            }
        }
        .frame(height: 88, alignment: .top)

        Spacer(minLength: 0).frame(height: 6)

        noteZone(m)
    }

    // MARK: The note zone

    /// EMPTY ALMOST ALWAYS, and that is the point. This used to hold a
    /// standing note on every single frame — an assurance about the
    /// implementation, addressed to a reader who was not worried. The 18 pt
    /// are still reserved so that arming a launch does not shove the tool
    /// rows upward, but nothing is drawn in them unless the user has just
    /// clicked «Открыть» on a tool that could auto-connect.
    @ViewBuilder private func noteZone(_ m: TunnelMetrics) -> some View {
        if let tool = armed, let caution = tool.launchCaution {
            // THE CONFIRMATION. It is here and not in a sheet because the
            // panel is 280 pt tall and lives in the notch; a modal over it
            // would cover the thing it is asking about.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(IslandPalette.warning)
                Text("\(tool.displayName): \(caution)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(IslandPalette.warning)
                    .lineLimit(1)
                Spacer(minLength: 8)
                NoteButton(title: "Всё равно открыть", tint: IslandPalette.warning) {
                    if let status = m.status(of: tool) {
                        armed = nil
                        TunnelActions.open(status)
                    }
                }
                NoteButton(title: "Отмена", tint: Color(white: 0.55)) { armed = nil }
            }
            .frame(height: 18)
        } else {
            Color.clear.frame(height: 18)
        }
    }

    // MARK: Actions

    private func open(_ status: TunnelToolStatus) {
        // A caution is a stop, not a warning label. Nothing is launched on
        // the first click for a tool that might auto-connect.
        if status.tool.launchCaution != nil {
            armed = (armed == status.tool) ? nil : status.tool
            return
        }
        armed = nil
        TunnelActions.open(status)
    }
}

// MARK: - Rows

private struct TunnelToolRow: View {
    let status: TunnelToolStatus
    let detail: String
    let isArmed: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(TunnelWords.tint(status.state))
                .frame(width: 6, height: 6)
                .padding(.trailing, 8)

            Text(status.tool.displayName)
                .font(.system(size: 12, weight: status.state == .carryingTraffic ? .semibold : .regular))
                .foregroundStyle(status.state == .notInstalled ? TunnelPalette.absent : Color(white: 0.88))
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)

            Text(TunnelWords.state(status.state))
                .font(.system(size: 10.5))
                .foregroundStyle(TunnelWords.tint(status.state))
                .lineLimit(1)
                .frame(width: 142, alignment: .leading)

            Text(detail)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.42))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Spacer(minLength: 0)

            // No button at all when there is nothing to open. A disabled
            // control on an uninstalled tool reads as "this is switched
            // off", which is the exact misstatement this section exists to
            // avoid.
            if TunnelActions.openTarget(status) != nil {
                RowButton(title: isArmed ? "Подтвердите ниже" : "Открыть",
                          tint: isArmed ? IslandPalette.warning : Color(white: 0.62),
                          action: onOpen)
            }
        }
        .frame(height: 22)
        // The tooltip carries the sentence that explains the verdict — the
        // whole value of this feature is that the obvious answer is wrong,
        // and `reason` is where the engine says why.
        .help(tooltip)
    }

    private var tooltip: String {
        var parts = [status.reason]
        // DISPLAY ONLY, and only here. AmneziaVPN's root helper has run for
        // days on a machine where Amnezia is idle, so "app is running" must
        // never sit next to the verdict where it could be read as evidence.
        if let running = status.isAppRunning {
            parts.append(running ? "Приложение запущено." : "Приложение не запущено.")
        }
        if let caution = status.tool.launchCaution {
            parts.append("Запуск: \(caution)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Buttons

/// The row's one verb.
private struct RowButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(hovering ? Color.white : tint)
                .padding(.horizontal, 8)
                .frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The confirmation pair in the note zone. Same shape as `RowButton` at
/// one point smaller, because the note zone is 18 pt and the row is 22.
private struct NoteButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(hovering ? Color.white : tint)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Registration

extension IslandSection {
    static let tunnel = IslandSection(
        id: .tunnel,
        chipTitle: "Туннель",
        chipSymbol: "arrow.triangle.branch",
        // Cheap and pure: one Optional Bool read off a @Published property
        // the watcher already wrote. No syscall, no I/O — see
        // IslandSection.swift.
        //
        // `== true` and not `!= false`: nil means the routing query failed,
        // and a failed measurement must never light the chip.
        hasState: { $0.tunnel?.deservesStripSlot == true },
        footerSummary: { model in TunnelWords.footerClause(model.tunnel) },
        makeBody: { model in AnyView(TunnelSectionView(model: model)) }
    )
}

// =====================================================================
// MARK: - Hidden diagnostic
//
// `--tunnel-probe`, in the style of `--printer-probe` and
// `--privacy-probe`: never reachable from the UI, and doing nothing
// unless the flag is on the command line.
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --tunnel-probe
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --tunnel-probe --cost 200
//
// IT LIVES HERE, NOT IN FeatureProbes.swift, FOR ONE REASON: what it
// prints is the SECTION's rendering, and the section's words are private
// to this file. A probe that reimplemented `TunnelWords` in another file
// would be checking a copy of the thing that ships, which proves nothing
// — the rule the existing probes' header states.
//
// IT EXERCISES THE SHIPPING CODE. The install sweep is the real
// `TunnelInstallIndex.refresh()`, the sample is the real `TunnelSampler`
// on a real serial queue, and every line below is produced by the same
// `TunnelWords` function the view calls. It calls NO action: nothing is
// launched, nothing is toggled, and there is no code path here that
// could.
// =====================================================================

enum TunnelProbe {

    /// `String(format: "%-18@")` does NOT pad on macOS — it prints the
    /// NSString and ignores the width — so the columns are padded by hand.
    /// Counted in Characters, because every label here is Cyrillic and
    /// `utf8.count` would over-count every one of them by a factor of two.
    private static func pad(_ text: String, _ width: Int) -> String {
        let short = width - text.count
        return short > 0 ? text + String(repeating: " ", count: short) : text
    }

    static func run(arguments: [String]) -> Never {
        print("=== MacPulse --tunnel-probe ===")
        print("")

        // COLD PATH, main thread, exactly as IslandModel drives it.
        let installs = TunnelInstallIndex.shared.refresh()
        print("--- COLD PATH: LaunchServices bundle lookup + stat ------------------")
        for tool in TunnelTool.allCases {
            let install = installs[tool]
            let where_ = install?.bundleURL?.path ?? "НЕ УСТАНОВЛЕН"
            print("  " + pad(tool.displayName, 18) + pad(where_, 34)
                  + (install?.isAppRunning == true ? "[приложение запущено]" : ""))
        }
        print("")

        // HOT PATH, on a serial queue — never on main, same as the watcher.
        let queue = DispatchQueue(label: "com.local.macpulse.tunnel.probe", qos: .utility)
        let sampler = TunnelSampler()
        var reading: TunnelMetrics?
        var offMain = false
        let done = DispatchSemaphore(value: 0)
        queue.async {
            offMain = !Thread.isMainThread
            reading = sampler.sample(installed: installs)
            done.signal()
        }
        done.wait()

        guard let m = reading else {
            print("sample() -> nil: getifaddrs failed. The island renders no chip and")
            print("no glyph, which is the honest outcome of knowing nothing.")
            exit(2)
        }
        print("sampled off the main thread: \(offMain ? "yes" : "NO — BUG")")
        print("")

        print("--- WHAT THE 560 x 186 SECTION DRAWS, LINE FOR LINE -----------------")
        print("")
        print("  \(TunnelWords.headline(m))   [\(TunnelWords.headlineBadge(m))]"
              + (m.routeIsSplit ? "   [РАСЩЕПЛЁННЫЙ МАРШРУТ]" : ""))
        print("  \(TunnelWords.carrierDetail(m))")
        // The decoy explanation and the standing notes used to be printed
        // here because they were on the panel. They are not on the panel
        // any more — a panel is not documentation — so there is nothing
        // to echo. WHY the default route is a decoy is still written
        // down, in the comments of TunnelSampler where it belongs.
        print("  \(TunnelWords.outsideAddress(GeoLookup.shared.reading))"
              + "   \(TunnelWords.outsideWhere(GeoLookup.shared.reading))")
        print("  " + String(repeating: "-", count: 68))
        for tool in TunnelTool.allCases {
            guard let s = m.status(of: tool) else { continue }
            print("  " + pad(tool.displayName, 18) + pad(TunnelWords.state(s.state), 26)
                  + pad(TunnelWords.interfaceDetail(s), 22)
                  + (TunnelActions.openTarget(s) != nil ? "[Открыть]" : ""))
            print("        подсказка: \(s.reason)")
        }
        print("")

        print("--- RAIL, FOOTER AND STRIP -----------------------------------------")
        let live = m.deservesStripSlot == true
        print("  deservesStripSlot : " + (m.deservesStripSlot.map { $0 ? "true" : "false" } ?? "— (не измерено)"))
        print("  чип в рейке       : " + (live ? "ДА, «Туннель»" : "нет"))
        print("  строка футера     : " + (TunnelWords.footerClause(m) ?? "— (nil)"))
        // The tunnel no longer claims the collapsed strip's slot at all, so
        // there is nothing to report here — this line used to describe a
        // glyph that is never drawn. `deservesStripSlot` is kept because it
        // is still the honest "is this worth mentioning" predicate that the
        // rail chip and the footer both read. The reasoning for dropping the
        // slot is beside IslandModel.updateTrailingSlot.
        print("  слот в полоске    : не претендует (всегда пусто)")
        print("")

        print("--- TUNNEL INTERFACES UP RIGHT NOW ---------------------------------")
        for t in m.tunnels {
            let signature = t.signature.map { "\($0.displayName) [\(t.signatureConfidence?.rawValue ?? "?")]" } ?? "—"
            let v4 = pad(t.ipv4 ?? "—", 14)
            let mtu = pad(t.mtu.map { "\($0)" } ?? "—", 6)
            print("  \(pad(t.name, 8))v4: \(v4)mtu: \(mtu)signature: \(signature)")
        }
        print("  (\(m.tunnels.count) поднято, \(m.addressedTunnels.count) с адресом IPv4)")
        print("")

        // COST. The number the idle budget is argued from.
        var iterations = 0
        if let i = arguments.firstIndex(of: "--cost"), i + 1 < arguments.count {
            iterations = Int(arguments[i + 1]) ?? 0
        }
        if iterations > 0 {
            var samples: [Double] = []
            samples.reserveCapacity(iterations)
            let costDone = DispatchSemaphore(value: 0)
            queue.async {
                for _ in 0..<iterations {
                    let started = Mono.now()
                    _ = sampler.sample(installed: installs)
                    samples.append(Mono.seconds(since: started) * 1_000_000)
                }
                costDone.signal()
            }
            costDone.wait()
            samples.sort()
            let mean = samples.reduce(0, +) / Double(samples.count)
            print("--- COST, \(iterations) samples on the watcher's own queue ------------------")
            print(String(format: "  mean %.1f us   p50 %.1f us   p99 %.1f us   max %.1f us",
                         mean, samples[samples.count / 2],
                         samples[min(samples.count - 1, Int(Double(samples.count) * 0.99))],
                         samples[samples.count - 1]))
            print(String(format: "  at the watcher's 10 s idle cadence: %.5f%% of one core",
                         mean / 1_000_000 / 10 * 100))
            print("")
        }

        print("NOTHING WAS TOGGLED. This probe calls TunnelActions on no path;")
        print("the only verb that exists is «Открыть», and the UI is what calls it.")
        exit(0)
    }
}
