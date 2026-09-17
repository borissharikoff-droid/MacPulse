import SwiftUI

// =====================================================================
// The memory-pressure notifier's 45 pt at the bottom of «Память».
//
// IT WAS A TAB. It is not one any more, and the user is the reason:
// "смысл между давлением и памятью — это как будто одни и те же вкладки,
// нахуя их разъединять". He is right. «Давление» and «Память» were two
// chips in one rail about one subject — this machine's RAM — and a router
// that splits one subject in two is making the user navigate between two
// halves of the same answer. So the notifier folded into the section it
// was always about, and `IslandSectionRegistry` no longer knows it exists.
//
// THE NOTIFIER ITSELF IS UNTOUCHED. The 45 s dwell, the six-hours-at-
// level-2 hysteresis, the daily cap, the delivery accounting — all of it
// is in FeaturePressureAlert.swift and none of it moved. What went away is
// a TAB, not a feature: `PressureAlertBridge` still starts from
// `IslandModel.start()`, still watches while the panel is shut, and still
// posts before macOS starts killing apps.
//
// WHEN IT IS ON SCREEN, AND WHY IT COSTS NOTHING WHEN IT IS NOT.
// `MemorySectionView` draws this only while `!pressureAlert.isQuiet` —
// exactly the condition that used to decide the chip. Quiet means nothing
// posted in 24 h and the user has not switched it off, which is the normal
// state of this machine, and in that state «Память» is pixel-identical to
// what it was before this fold existed: five app rows, no strip, no words.
//
// When it IS on screen the app list goes from five rows to three, which is
// where the 45 pt comes from. That is a deliberate trade and not a
// compromise: an alert means the machine is under real pressure, and at
// that moment "what we told you, and the switch that stops it" is worth
// more than the fourth and fifth biggest app.
//
// WHAT THE COPY IS NOT ALLOWED TO CLAIM — this is not a style question,
// and all of it survived the fold:
//
//   * NOT "macOS is about to close your apps". The engine reads
//     kern.memorystatus.kill_on_sustained_pressure_count; it is 0 on this
//     machine and stayed 0 through every induced-pressure run, i.e. the OS
//     killer is DORMANT here. The `killerLine` this section used to print
//     is CUT — it was a sentence about a counter that has never moved —
//     and nothing here talks about jetsam at all.
//   * NOT "you will be warned in time". A 1 Hz poll plus a 45 s dwell
//     means the warning arrives about 45 s into a bad stretch. An
//     allocator that eats the machine in 1.2 s — measured — will never be
//     caught by this. The old section spelled that out in a footnote; the
//     footnote is CUT and the claim went with it. This fold says only what
//     happened and offers the switch. It does not promise anything, so it
//     does not need a disclaimer.
//   * NOT "warned" when the banner was swallowed. A row whose delivery was
//     `.silent` still says «без баннера»; a row that could not be posted
//     at all still says so. That one is load-bearing and stays.
//
// THERE IS NO QUIT BUTTON HERE. The one in the notification hands a
// re-validated pid to `IslandModel.requestQuit`, and the app rows directly
// above this fold already have a per-app «Завершить». A second one
// pointing at the same app would be a second place for that contract to
// rot.
//
// LAYOUT — 45 pt, and it adds up:
//    17  switch row   state + count + the switch (+ Настройки, if denied)
//     2  gap
//    26  two history rows, 13 pt each
//   ---
//    45
// =====================================================================

/// The bottom of «Память» when the notifier has something to say.
///
/// A plain view, not a section: nothing registers it, nothing routes to
/// it, and `IslandSectionRegistry` has never heard of it. `MemorySectionView`
/// owns whether it is on screen.
struct PressureFold: View {

    /// The whole fold, including the gap above it. `IslandSectionMemory`
    /// subtracts exactly this from its app-row budget, so the two cannot
    /// disagree about how much room the fold takes.
    static let height: CGFloat = 45

    let state: PressureAlertState

    /// At most this many alerts are shown. The engine keeps more (see
    /// `PressureAlertBridge.historyLimit`); two is what 26 pt holds, and
    /// the newest two are the ones anyone acts on.
    private static let visibleAlerts = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switchRow
            Spacer(minLength: 0).frame(height: 2)
            history
        }
        .frame(height: Self.height, alignment: .top)
    }

    // --- the switch row ---

    private var switchRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            // ONE line, and which one depends on what is actually wrong.
            // A denial outranks the live line: `.denied` is permanent
            // (UNErrorDomain Code=1 forever — see FeaturePressureAlert)
            // and the button beside it is the only recovery there is.
            Text(headline)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(white: state.isMuted ? 0.45 : 0.8))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text("\(state.deliveredToday)/\(state.dailyCap)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.42))
                .help(tr("Предупреждений за сутки, против дневного предела.",
                         "Warnings today, against the daily limit."))

            if state.authorization == .denied {
                // `.unavailable` deliberately gets NO button: System
                // Settings cannot fix an unregistered bundle and sending
                // the user there would waste their time.
                SmallButton(title: tr("Настройки", "Settings"),
                            tint: IslandPalette.warning,
                            onTap: { PressureAlertEngine.shared.openNotificationSettings() })
            }

            SmallButton(title: state.isMuted ? tr("Включить", "Turn on")
                                            : tr("Выключить", "Turn off"),
                        tint: state.isMuted ? IslandPalette.normal : Color(white: 0.85),
                        onTap: { PressureAlertBridge.shared.setMuted(!state.isMuted) })
        }
        .frame(height: 17)
    }

    private var headline: String {
        if state.isMuted { return tr("Предупреждения о памяти выключены", "Memory warnings are off") }
        // `isFinal` is `.denied` or `.unavailable` — the two states nothing
        // we do can change. Written as `isFinal` rather than compared
        // against the cases because `.unavailable` carries a reason string
        // and `== .unavailable` does not compile.
        if state.authorization.isFinal { return state.authorization.panelLine }
        return state.liveLine
    }

    private var tint: Color {
        if state.isMuted { return IslandPalette.unknown }
        switch state.authorization {
        case .authorized:         return IslandPalette.normal
        case .authorizedSilently: return IslandPalette.warning
        case .denied, .unavailable: return IslandPalette.critical
        default:                  return IslandPalette.unknown
        }
    }

    // --- what we actually told the user ---

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.history.prefix(Self.visibleAlerts)) { entry in
                PressureAlertRow(entry: entry)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26, alignment: .top)
    }
}

/// One alert, as it happened, in 13 pt.
///
/// THE DELIVERY CLAUSE IS LOAD-BEARING and is the one thing that did not
/// get shorter in the fold: an alert posted while banners are off was
/// never actually seen, and saying «показано» about it would be a claim we
/// cannot support.
private struct PressureAlertRow: View {
    let entry: PressureAlertEntry

    private var tint: Color {
        switch entry.delivery {
        case .blocked: return IslandPalette.critical
        case .silent:  return IslandPalette.warning
        case .shown:   return entry.severity == .critical ? IslandPalette.critical
                                                          : IslandPalette.warning
        }
    }

    private var deliveryLabel: String {
        switch entry.delivery {
        case .shown:            return tr("показано", "shown")
        case .silent:           return tr("без баннера", "no banner")
        case .blocked(let why): return tr("не отправлено: \(why)", "not sent: \(why)")
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(entry.time)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 32, alignment: .leading)

            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)

            Text(entry.appName)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.84))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(entry.footprint)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.66))

            Spacer(minLength: 8)

            Text(deliveryLabel)
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.44))
                .lineLimit(1)
        }
        .frame(height: 13)
    }
}
