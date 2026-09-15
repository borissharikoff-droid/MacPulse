import SwiftUI

// =====================================================================
// «Давление» — the memory-pressure notifier's section.
//
// THIS FEATURE IS MOSTLY NOT A SECTION. Its job happens while nothing is
// on screen: it watches the pressure level the app already samples and
// posts ONE notification when a bad stretch has genuinely lasted. See
// FeaturePressureAlert.swift for the policy and the measurements behind
// every threshold in it.
//
// SO THE CHIP IS ABSENT ALMOST ALWAYS, AND THAT IS THE FEATURE. `hasState`
// is `!model.pressureAlert.isQuiet`, which is false whenever nothing has
// been posted in the last 24 h and the user has not switched the
// notifier off. On this machine — which sits at kernel pressure level 2
// for long stretches of ordinary work — that is the normal condition, and
// the rail stays one chip wide. A chip that said "alerts are configured"
// would be exactly the thing IslandSection.swift's second rule forbids.
//
// THE SECTION EXISTS FOR TWO THINGS AND NOTHING ELSE:
//   1. what we actually told you, and whether you actually saw it;
//   2. the switch that makes it stop.
// The switch is reachable precisely when there is something to switch
// off, and «выключено» is itself state, so the chip survives a mute and
// is the way back.
//
// WHAT THE COPY IS NOT ALLOWED TO CLAIM — this is not a style question:
//
//   * NOT "macOS is about to close your apps". The engine reads
//     kern.memorystatus.kill_on_sustained_pressure_count; it is 0 on this
//     machine and stayed 0 through every induced-pressure run, i.e. the
//     OS killer is DORMANT here. `killerLine` renders whatever those oids
//     actually say, including "we cannot read them", and nothing else in
//     this file talks about jetsam at all.
//   * NOT "you will be warned in time". A 1 Hz poll plus a 45 s dwell
//     means the warning arrives about 45 s into a bad stretch. An
//     allocator that eats the machine in 1.2 s — measured — will never be
//     caught by this. The footnote at the bottom says so in the panel,
//     because the user is entitled to know what the promise is.
//   * NOT "warned" when the banner was swallowed. A row whose delivery is
//     `.silent` says «без баннера»; a row that could not be posted at all
//     says so and offers System Settings.
//
// THERE IS NO QUIT BUTTON HERE. The one in the notification hands a
// re-validated pid to IslandModel.requestQuit; the panel already has a
// per-app Quit on every row of «Память», and a second one here pointing
// at the same app would be a second place for that contract to rot.
// =====================================================================

extension IslandSectionID {
    static let pressure = IslandSectionID("pressure")
}

// MARK: - The 560 x 186 body

private struct PressureSectionView: View {
    @ObservedObject var model: IslandModel

    private var state: PressureAlertState { model.pressureAlert }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0).frame(height: 8)
            status
            Spacer(minLength: 0).frame(height: 8)
            live
            Spacer(minLength: 0).frame(height: 6)
            Divider().overlay(Color(white: 0.16))
            Spacer(minLength: 0).frame(height: 6)
            historyHeader
            Spacer(minLength: 0).frame(height: 3)
            history
            Spacer(minLength: 0)
            footnote
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }

    // --- header: what this is, and the switch ---

    private var header: some View {
        HStack(spacing: 8) {
            Text("Предупреждения о памяти")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text("\(state.deliveredToday) из \(state.dailyCap) за сутки")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.42))
            SmallButton(title: state.isMuted ? "Включить" : "Выключить",
                        tint: state.isMuted ? IslandPalette.normal : Color(white: 0.85),
                        onTap: { PressureAlertBridge.shared.setMuted(!state.isMuted) })
                .help(state.isMuted
                      ? "Снова предупреждать, когда память под давлением"
                      : "Больше не присылать уведомления о давлении памяти")
        }
        .frame(height: 18)
    }

    // --- status: the OS's answer, and the OS's own kill counter ---

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(authTint)
                .frame(width: 6, height: 6)
            Text(state.authorization.panelLine)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.62))
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.authorization == .denied {
                // The ONLY recovery from a denial, and the reason this
                // button exists at all: macOS returns UNErrorDomain Code=1
                // forever once the user has said no (or let the macOS 26
                // banner time out), so there is nothing this app can ask
                // again — see FeaturePressureAlert.swift. `.unavailable`
                // deliberately gets NO button: System Settings cannot fix
                // an unregistered bundle and sending the user there would
                // waste their time.
                SmallButton(title: "Открыть Настройки",
                            tint: IslandPalette.warning,
                            onTap: { PressureAlertEngine.shared.openNotificationSettings() })
            }
        }
        .frame(height: 12)

        Spacer(minLength: 0).frame(height: 3)

        Text(state.killerLine)
            .font(.system(size: 9))
            .foregroundStyle(Color(white: 0.40))
            .lineLimit(1)
            .frame(height: 12)
    }

    private var authTint: Color {
        switch state.authorization {
        case .authorized:         return IslandPalette.normal
        case .authorizedSilently: return IslandPalette.warning
        case .denied, .unavailable: return IslandPalette.critical
        default:                  return IslandPalette.unknown
        }
    }

    // --- live: why you are not being bothered right now ---

    private var live: some View {
        Text(state.liveLine)
            .font(.system(size: 11.5))
            .foregroundStyle(state.isMuted ? Color(white: 0.45) : Color(white: 0.82))
            .lineLimit(1)
            .frame(height: 14, alignment: .leading)
    }

    // --- history ---

    private var historyHeader: some View {
        Text(state.history.isEmpty ? "ПРЕДУПРЕЖДЕНИЙ НЕ БЫЛО" : "ПОСЛЕДНИЕ ПРЕДУПРЕЖДЕНИЯ")
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color(white: 0.34))
            .frame(height: 11)
    }

    @ViewBuilder private var history: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.history) { entry in
                PressureHistoryRow(entry: entry)
            }
        }
    }

    // --- the honest footnote about what this can and cannot promise ---

    private var footnote: some View {
        Text("45 с подряд под давлением — тогда предупреждаем, не чаще "
             + "\(state.dailyCap) раз в сутки. Скачок за пару секунд поймать не успеем.")
            .font(.system(size: 8.5))
            .foregroundStyle(Color(white: 0.32))
            .lineLimit(1)
            .frame(height: 11)
    }
}

/// One alert, as it happened. The delivery clause is load-bearing: an
/// alert that was posted while banners are off was never actually seen,
/// and saying "предупредили" about it would be a claim we cannot support.
private struct PressureHistoryRow: View {
    let entry: PressureAlertEntry

    private var tint: Color {
        switch entry.delivery {
        case .blocked: return IslandPalette.critical
        case .silent:  return IslandPalette.warning
        case .shown:   return entry.severity == .critical ? IslandPalette.critical
                                                          : IslandPalette.warning
        }
    }

    private var severityLabel: String {
        entry.severity == .critical ? "критично" : "предупреждение"
    }

    private var deliveryLabel: String {
        switch entry.delivery {
        case .shown:              return "показано"
        case .silent:             return "без баннера"
        case .blocked(let why):   return "не отправлено: \(why)"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(entry.time)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 34, alignment: .leading)

            Text(severityLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
                .frame(width: 104, alignment: .leading)

            Text(entry.appName)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.88))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(entry.footprint)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.7))
                .frame(width: 66, alignment: .trailing)

            Text(deliveryLabel)
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.44))
                .lineLimit(1)
                .frame(width: 150, alignment: .trailing)
        }
        .frame(height: 19)
        .padding(.horizontal, 6)
    }
}

// MARK: - Registration

extension IslandSection {
    static let pressure = IslandSection(
        id: .pressure,
        chipTitle: "Давление",
        chipSymbol: "exclamationmark.triangle",
        // Cheap and pure: two reads off a @Published struct the bridge
        // already wrote. No syscall, no I/O — see IslandSection.swift.
        // False on a quiet machine, which is almost always.
        hasState: { !$0.pressureAlert.isQuiet },
        footerSummary: { model in
            let s = model.pressureAlert
            if s.isMuted { return "Предупреждения выкл" }
            guard let newest = s.history.first else { return nil }
            if case .blocked = newest.delivery { return "Предупреждение не доставлено" }
            return "Предупреждений: \(s.deliveredToday)"
        },
        makeBody: { model in AnyView(PressureSectionView(model: model)) }
    )
}
