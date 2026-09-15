import SwiftUI

// =====================================================================
// «Звук» — which app has an audio output stream open, and the transport
// keys. Registered through the router's documented extension point: an
// id, a section value, one line in IslandFeatures.
//
// THIS IS NOT A NOW-PLAYING CARD, AND THE DIFFERENCE IS THE WHOLE POINT.
// MediaRemote's read path is entitlement-gated since macOS 15.4 and
// answers empty (measured on 26.6.2 with Music verifiably playing), so
// there is no track title, no artist, no artwork and no play state to
// draw. See FeatureSound.swift for the measurements. What this section
// therefore contains, and nothing else:
//
//   * WHO HAS AUDIO OPEN — icon, localized name, bundle id, pid, from
//     public CoreAudio with no permission of any kind;
//   * PLAY STATE: НЕИЗВЕСТНО, said in words, with the reason one hover
//     away;
//   * FOUR TRANSPORT BUTTONS that were each individually verified against
//     a real app, with the sentence that says what pressing them can and
//     cannot be known to do.
//
// THREE THINGS THIS SECTION MUST NEVER GROW, each of them a measured
// hazard rather than a matter of taste:
//
//   1. A ▶/⏸ STATE GLYPH. There is no play-state signal. Driving one from
//      `IsRunningOutput` would show "playing" for 5-10 s after the user
//      pressed pause — measured on both Music and QuickTime. The two
//      buttons here are ACTIONS, drawn side by side precisely so that
//      neither can be read as a statement about the current state; a
//      single ⏯ button would be exactly that statement, which is why the
//      command exists in `SoundCommand` and is deliberately not drawn.
//
//   2. A TRACK / ARTIST ROW. It would be empty forever. An always-"—"
//      field is a worse answer than an absent one.
//
//   3. A FAVOURITE AMONG SEVERAL AUDIO APPS. With two apps playing, three
//      consecutive commands hit Music every time and never QuickTime —
//      stable routing that nothing in the available data predicted. So
//      with several sources the section lists them all and says the
//      target is the system's choice. `apps.first` would be a lie half
//      the time.
//
// THE CHIP IS ABSENT MOST OF THE TIME, AND THAT IS THE FEATURE.
// `hasState` is "somebody has an output stream open" — not "the transport
// exists", which is always true and is therefore not state. On a silent
// machine the rail is one chip (Память) and the island is exactly what it
// was.
// =====================================================================

extension IslandSectionID {
    static let sound = IslandSectionID("sound")
}

// MARK: - Collapsed strip slot

/// The trailing wing's slot while audio is leaving the machine — and only
/// while it is. Per the arch spike this feature earns ambient pixels for
/// exactly as long as something is actually making sound, which is also
/// the only time the answer is interesting.
///
/// ONE 14 pt APP ICON AND NOTHING ELSE. There is no text: the widest
/// thing the wing can hold beside the privacy rail is 25 pt, which is
/// four monospaced digits — enough for "1ч23" and not for any app name
/// worth printing. The icon is the whole readout, and it reuses the print
/// ring's 14 pt box, so `IslandMetrics.trailingLayout` needs no new
/// number to lay this out.
///
/// WITH SEVERAL SOURCES IT DRAWS A SPEAKER, NOT SOMEBODY'S ICON. Picking
/// one of them for the strip would nominate a favourite, which is the one
/// thing this feature has measured grounds never to do.
struct SoundStripSlot: View {
    let state: SoundState

    /// The icon box IS the ring's box. Defined as that constant rather
    /// than as 14 so it cannot drift from the wing arithmetic that
    /// reserves it.
    static let iconSize: CGFloat = IslandMetrics.ringDiameter

    /// What `IslandModel.updateTrailingSlot` should ask the wing for when
    /// this slot wins it: the lead-in, the icon, the gap and the privacy
    /// rail that is pinned to its right. 7 + 14 + 4 + 23 = 48, against the
    /// print ring's 77 — this slot has no text, so it does not ask for the
    /// 29 pt the text would need.
    static let wingWidth: CGFloat =
        IslandMetrics.slotLeadingGap + iconSize + IslandMetrics.slotGap
        + IslandMetrics.privacyRailWidth

    var body: some View {
        Group {
            if let icon = state.single?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Self.iconSize, height: Self.iconSize)
            } else {
                // No icon, or more than one source. A speaker claims
                // nothing about WHO.
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(white: 0.82))
                    .frame(width: Self.iconSize, height: Self.iconSize)
            }
        }
        .help(Self.tooltip(state))
    }

    static func tooltip(_ state: SoundState) -> String {
        guard let apps = state.apps, !apps.isEmpty else {
            return "Аудиопоток открыт"
        }
        let who = apps.count == 1
            ? apps[0].name
            : SoundFeature.sources(apps.count) + ": " + apps.map(\.name).joined(separator: ", ")
        return "Аудиопоток открыт — \(who). " + SoundFeature.outputStreamCaveat
    }
}

// MARK: - The 560 x 186 body

private struct SoundSectionView: View {
    @ObservedObject var model: IslandModel

    /// The vertical budget, spelled out so the next change to it has to
    /// face the arithmetic:
    ///
    ///    16  header
    ///     8  gap
    ///    94  who has audio open        (FIXED — so the buttons never move
    ///     8  gap                        between the one-app and the
    ///    30  transport                  several-apps layouts)
    ///     6  gap
    ///    22  the two honest lines
    ///   ---
    ///   184  against the 186 the router grants
    private static let appBlockHeight: CGFloat = 94

    var body: some View {
        let state = model.sound
        VStack(alignment: .leading, spacing: 0) {
            header

            Spacer(minLength: 0).frame(height: 8)

            appBlock(state)
                .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
                       height: Self.appBlockHeight,
                       alignment: .topLeading)

            Spacer(minLength: 0).frame(height: 8)

            transport

            Spacer(minLength: 0).frame(height: 6)

            notes
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }

    // MARK: header

    /// Takes no state on purpose: the only thing that could vary here is
    /// the play-state badge, and it never varies — there is nothing to
    /// measure it with.
    private var header: some View {
        HStack(spacing: 8) {
            Text("У КОГО ОТКРЫТ АУДИОПОТОК")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(white: 0.5))
            Spacer(minLength: 8)
            // WHERE A PLAYER WOULD PUT ▶/⏸. It says unknown, because that
            // is what was measured, and the hover says why.
            Text("ВОСПРОИЗВЕДЕНИЕ — НЕИЗВЕСТНО")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(IslandPalette.unknown)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(IslandPalette.unknown.opacity(0.14)))
                .help(SoundFeature.playStateUnknownReason)
        }
        .frame(height: 16)
    }

    // MARK: who has audio open

    @ViewBuilder private func appBlock(_ state: SoundState) -> some View {
        if let apps = state.apps {
            if let one = apps.first, apps.count == 1 {
                hero(one)
            } else if apps.isEmpty {
                // Only reachable for the frame or two between the last app
                // closing its stream and the router dropping the chip.
                Text("Сейчас ничего не звучит")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.45))
            } else {
                many(apps)
            }
        } else {
            // nil is "could not measure", and it renders as a dash. It is
            // NOT "тишина" — the process-object API is macOS 14.4+ and an
            // older system, or a failed read, must not be reported as a
            // quiet machine.
            VStack(alignment: .leading, spacing: 4) {
                Text("—")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                Text("аудиосервер не ответил — это не «тихо», это «не измерено»")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(white: 0.42))
            }
        }
    }

    /// ONE app: the case where the app we name and the app a command
    /// reaches coincided in every measurement, so it is the only case
    /// allowed to put a name right beside the buttons.
    @ViewBuilder private func hero(_ app: SoundApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(app, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(identityLine(app))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle()
                        .fill(IslandPalette.normal)
                        .frame(width: 7, height: 7)
                    Text("аудиопоток открыт")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 0.72))
                }
                .help(SoundFeature.outputStreamCaveat)
            }
            Spacer(minLength: 0)
        }
    }

    /// SEVERAL apps: list them, and say in words that the transport's
    /// target is not ours to know.
    ///
    /// Three rows is the cap the 94 pt block can hold — 3 x 22 + spacing +
    /// the caution line = 84 — and the overflow count goes INTO the
    /// caution line rather than onto a line of its own, because a fourth
    /// line would push the transport row down and the buttons must not
    /// move between the one-app and the several-apps layouts.
    @ViewBuilder private func many(_ apps: [SoundApp]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(apps.prefix(3)) { app in
                HStack(spacing: 8) {
                    icon(app, size: 16)
                    Text(app.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(white: 0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(identityLine(app))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Color(white: 0.38))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(height: 22)
            }
            Text((apps.count > 3 ? "И ещё \(apps.count - 3) · " : "")
                 + "команда уйдёт одному из них — какому, решает система")
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.warning.opacity(0.85))
                .lineLimit(1)
                .frame(height: 12)
                .help(SoundFeature.ambiguousTargetCaveat)
        }
    }

    @ViewBuilder private func icon(_ app: SoundApp, size: CGFloat) -> some View {
        if let image = app.icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(white: 0.16))
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
            }
            .frame(width: size, height: size)
        }
    }

    /// Bundle id and pid. Both are measured facts about the row, and they
    /// are what makes "Музыка" checkable rather than merely plausible —
    /// the same reason the Память section prints its coverage line.
    private func identityLine(_ app: SoundApp) -> String {
        let bundle = app.bundleIdentifier ?? "без bundle id"
        return app.pid.map { "\(bundle) · pid \($0)" } ?? bundle
    }

    // MARK: transport

    /// Buttons come ONLY from `SoundControl.availability.commands`, which
    /// is empty the day Apple removes the private symbol. Then this draws
    /// the reason instead — a dead button is worse than an absent one.
    ///
    /// Play and Pause are separate on purpose (see the file header), and
    /// `togglePlayPause` is filtered out even though it is available and
    /// verified.
    @ViewBuilder private var transport: some View {
        let available = SoundControl.availability
        HStack(spacing: 8) {
            if available.isAvailable {
                ForEach(Self.drawnCommands.filter { available.commands.contains($0) },
                        id: \.rawValue) { command in
                    SoundTransportButton(command: command) { SoundControl.send(command) }
                }
                Spacer(minLength: 8)
                Text("команды уходят системному плееру")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.34))
                    .lineLimit(1)
            } else {
                Text("Управление недоступно: "
                     + (available.unavailableReason ?? "MediaRemote не отвечает"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(IslandPalette.warning)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 30)
    }

    /// Order, left to right. `togglePlayPause` is absent deliberately.
    private static let drawnCommands: [SoundCommand] =
        [.previousTrack, .play, .pause, .nextTrack]

    // MARK: the honest lines

    private var notes: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Видно только, у кого открыт аудиопоток. Трек, обложку и play/pause система не отдаёт.")
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.34))
                .lineLimit(1)
            Text("Подтвердить, что команда сработала, нечем; «Далее»/«Назад» в конце очереди молчат.")
                .font(.system(size: 8.5))
                .foregroundStyle(Color(white: 0.34))
                .lineLimit(1)
        }
        .frame(height: 22, alignment: .top)
    }
}

/// A transport key. Symbol AND word, always both: the word is what keeps
/// the symbol from being read as a statement about the current state.
private struct SoundTransportButton: View {
    let command: SoundCommand
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: command.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(command.title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.black : Color(white: 0.88))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color(white: 0.88) : Color.white.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Self.tooltip(command))
    }

    private static func tooltip(_ command: SoundCommand) -> String {
        switch command {
        case .nextTrack, .previousTrack:
            return "\(command.title). Двигает курсор очереди; на краю очереди молча не делает ничего, "
                 + "и MacPulse этого не видит — подтвердить результат команды нечем."
        default:
            return "\(command.title). Подтвердить, что команда сработала, нечем: "
                 + "ответ «принято» означает только, что сообщение поставлено в очередь."
        }
    }
}

// MARK: - Registration

extension IslandSection {
    static let sound = IslandSection(
        id: .sound,
        chipTitle: "Звук",
        chipSymbol: "speaker.wave.2",
        // Cheap and pure: one Bool off a @Published struct the watcher
        // already wrote. No syscall, no HAL read — see IslandSection.swift.
        //
        // FALSE WHEN NOBODY HAS AUDIO OPEN, and false when the sweep could
        // not measure. "The transport works" is not state — it is true on
        // every machine at every moment — so it never earns a chip on its
        // own.
        hasState: { $0.sound.hasOutput },
        footerSummary: { model in
            guard let apps = model.sound.apps, !apps.isEmpty else { return nil }
            if apps.count == 1 { return "Звук: \(apps[0].name)" }
            return "Звук: " + SoundFeature.sources(apps.count)
        },
        makeBody: { model in AnyView(SoundSectionView(model: model)) }
    )
}
