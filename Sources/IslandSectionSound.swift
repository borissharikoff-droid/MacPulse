import SwiftUI

// =====================================================================
// «Звук» — THE APP THAT HAS AUDIO OPEN. Its icon, its name, the transport
// keys, and one slow breath of light behind the icon.
//
// THE SUBJECT IS THE APP, NOT THE TRACK, and that is forced rather than
// chosen. MediaRemote's read path is sealed behind the restricted
// entitlement com.apple.mediaremote.allow since macOS 15.4: every symbol
// resolves, every callback fires, every answer is empty, and a probe
// self-signed with that entitlement is SIGKILLed at exec. `--sound-probe`
// prints it in one line — "now-playing READ : false". So there is no
// title, no artist, no artwork and no ▶/⏸ state, there is no field for
// any of them in this file, and an always-"—" title row would be a worse
// answer than no row at all. See FeatureSound.swift for the measurements.
//
// ---------------------------------------------------------------------
// THE MOTION IS A BREATH, NOT A BEAT, AND THAT IS AN HONESTY DECISION.
//
// An animation that tracks PLAYBACK needs a signal that goes quiet when
// playback stops. There is none available to an unentitled process:
//
//   * kAudioProcessPropertyIsRunningOutput means "has an output stream
//     open", not "is playing". Measured again while rebuilding this
//     section: Zen, with nothing playing in any tab, reads true —
//     continuously, across probes minutes apart. And after a pause Music
//     and QuickTime hold it another 5-10 s.
//   * The public HAL has no meter. The process object has exactly six
//     properties (ppid, pbid, pdv#, pir?, piri, piro) and not one of them
//     is a level; AudioHardware.h's 'volm'/'vold'/'vdb#' are volume
//     CONTROLS, not signal.
//   * The only path to a real level is AudioHardwareCreateProcessTap —
//     Obj-C-only, macOS 14.2+, needs the system-audio-RECORDING consent
//     and a live IO proc. A recording permission and continuous DSP to
//     drive a decoration is not a trade this app makes.
//
// So equaliser bars are out: they would bounce merrily while Zen sits
// silent, which is a lie in motion and worse than stillness. What IS
// measured is "this device is in use", and that is a state, not an event
// — so the motion is a 5.6 s breath, roughly six times slower than any
// musical pulse, with no attack and no rhythm to mistake for one.
//
// COST WHILE THE PANEL IS SHUT: NONE, AND STRUCTURALLY SO. `IslandView`
// puts `IslandRouter` in the tree only under `if isOpen`, and the chip
// that selects this body only exists while `hasState` is true. "No audio"
// and "panel closed" both mean there is no view to animate.
// Cost while it is OPEN is 0.022% of a core, and getting there took the
// whole of `BreathingHalo`'s doc comment — the obvious SwiftUI spelling
// of this animation measured 100.2% of ONE CORE.
//
// ---------------------------------------------------------------------
// TWO THINGS THAT MUST NOT COME BACK:
//
//   A ⏯ STATE GLYPH. There is no play-state signal, so a single toggle
//   button would be a claim this process cannot make. Play and Pause are
//   drawn as two separate, equally-weighted keys precisely so that
//   neither reads as a statement about what the player is doing now.
//   `togglePlayPause` exists in `SoundCommand` and is deliberately not
//   drawn.
//
//   THE COLLAPSED STRIP SLOT. Sound was removed from the trailing wing
//   because Zen kept it permanently lit; the argument is written beside
//   `IslandModel.updateTrailingSlot` and the measurement above is the
//   same one. Nothing found here changes it.
//
// WITH SEVERAL SOURCES, NOTHING IS NOMINATED. The app we name and the app
// a command reaches are resolved by two unrelated mechanisms and the API
// that would compare them is the dead one. One app => name it beside the
// keys; several => list them and say the target is the system's choice.
// =====================================================================

extension IslandSectionID {
    static let sound = IslandSectionID("sound")
}

// MARK: - The breath

/// Wraps an icon in a slow halo. See the file header for why it is slow
/// and why it is not bars.
private struct AmbientGlow<Content: View>: View {
    private let size: CGFloat
    private let spread: CGFloat
    private let content: Content

    init(size: CGFloat, spread: CGFloat = 1.8, @ViewBuilder content: () -> Content) {
        self.size = size
        self.spread = spread
        self.content = content()
    }

    var body: some View {
        content.background {
            BreathingHalo(diameter: size * spread)
                .frame(width: size * spread, height: size * spread)
                .allowsHitTesting(false)
        }
    }
}

/// THE GLOW, AND WHY IT IS A CALayer AND NOT A SwiftUI ANIMATION.
///
/// It was a SwiftUI `withAnimation(.repeatForever)` driving `scaleEffect`
/// and `opacity` on a `Circle().fill(RadialGradient(...))` first, which
/// is the obvious way to write it. MEASURED with the section on screen
/// and nothing else running, 90 s windows, `IdleCost.taskThreadTimes`:
///
///     SwiftUI repeatForever ......... 100.2% of one core
///     the same section, no animation ... 0.038% of one core
///
/// A whole core. SwiftUI re-rasterises a gradient-filled shape on every
/// frame of a transform animation and re-evaluates the body around it, so
/// "one implicit animation" turns into 60 redraws a second on the main
/// thread. A system monitor that costs a core to look at is not a system
/// monitor.
///
/// So the halo is a `CAGradientLayer` with ONE keyframe animation on
/// `opacity`, attached once and never touched again. The layer's content
/// is rasterised a single time and cached; after that this process does
/// nothing at all — 0.022% of a core, which is the noise floor.
///
/// Opacity ONLY — no scale. A transform animation on a gradient layer
/// pushes the re-rasterisation into the compositor instead of removing
/// it, and the breath does not need it: the gradient's soft edge already
/// makes a fade read as a swell.
///
/// AND IT IS STEPPED, NOT CONTINUOUS. Moving the animation off the main
/// thread does not make it free — it makes it WindowServer's, which
/// recomposites the whole panel once per changed value. So the curve is
/// sampled instead of interpolated: `.discrete` keyframes hold each value
/// for 116 ms. MEASURED by reading `presentation().opacity` off the layer
/// the render server is drawing:
///
///     .linear   (interpolated) .... 103.5 distinct values per second
///     .discrete (what ships) ......   8.5 distinct values per second
///
/// — a twelfth of the compositor wake-ups for the same 5.6 s breath. What
/// that saves in WindowServer CPU is NOT measured and is not claimed:
/// this machine's screen was locked while the work was done, and with
/// nothing of ours on screen at all WindowServer swung between 0.3% and
/// 22% of a core as the display dimmed, which is far wider than the
/// effect being looked for. The wake-up count is the honest number, and
/// fewer is the conservative choice.
///
/// On a raised cosine sampled 48 times the biggest step is 4% of the
/// halo's own opacity — about 1% of an alpha that never exceeds 0.30 — so
/// nothing about it reads as stepping.
private struct BreathingHalo: NSViewRepresentable {
    let diameter: CGFloat

    /// HALF a cycle, so the full breath is 5.6 s — about six times slower
    /// than a musical pulse, which is the point. See the file header.
    static let half: CFTimeInterval = 2.8
    /// Samples per FULL cycle. Trades compositor wake-ups against
    /// smoothness; see the paragraph above for where 48 came from.
    static let steps = 48
    static let tint = NSColor(calibratedRed: 0.84, green: 0.89, blue: 1.0, alpha: 1)

    func makeNSView(context: Context) -> NSView { HaloView(diameter: diameter) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class HaloView: NSView {
        private let halo = CAGradientLayer()

        init(diameter: CGFloat) {
            super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
            wantsLayer = true
            halo.type = .radial
            halo.colors = [
                BreathingHalo.tint.withAlphaComponent(0.34).cgColor,
                BreathingHalo.tint.withAlphaComponent(0.14).cgColor,
                BreathingHalo.tint.withAlphaComponent(0.0).cgColor,
            ]
            halo.locations = [0.0, 0.46, 1.0]
            halo.startPoint = CGPoint(x: 0.5, y: 0.5)
            halo.endPoint = CGPoint(x: 1.0, y: 1.0)
            halo.frame = bounds
            // The value the layer RESTS at, so a system with animations
            // switched off in Accessibility still gets a halo rather than
            // a blank — it simply does not breathe.
            halo.opacity = 0.7
            // The raised cosine IS the ease-in-out — sampling it is what
            // lets the animation be discrete without looking mechanical.
            let low = 0.40, high = 1.0
            let values = (0...BreathingHalo.steps).map { i -> NSNumber in
                let t = Double(i) / Double(BreathingHalo.steps)
                return NSNumber(value: low + (high - low) * (0.5 - 0.5 * cos(2 * .pi * t)))
            }
            let breath = CAKeyframeAnimation(keyPath: "opacity")
            breath.values = values
            breath.calculationMode = .discrete
            breath.duration = BreathingHalo.half * 2
            breath.repeatCount = .greatestFiniteMagnitude
            halo.add(breath, forKey: "breath")
            layer?.addSublayer(halo)
        }

        required init?(coder: NSCoder) { nil }

        /// Decoration. The keys are 200 pt away and must stay clickable.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            // The animation is on opacity, so resizing the layer never
            // interrupts it — but the frame still has to follow SwiftUI's
            // layout, and an implicit animation on `frame` would be a
            // second, unasked-for motion.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - The 560 x 186 body

private struct SoundSectionView: View {
    @ObservedObject var model: IslandModel

    /// ONE ROW ACROSS THE WHOLE 560, vertically centred: subject on the
    /// left, keys on the right, the way every media control anyone has
    /// used is laid out. The canvas is 560 x 186 — wide and short — so a
    /// left-hand column with three quarters of the plate empty beside it
    /// reads as a mistake rather than as restraint.
    ///
    /// The subject column is a FIXED 320 pt wide so the keys sit in the
    /// same place whether there is one audio app or four. Buttons that
    /// move when the machine's state changes are buttons you have to look
    /// for.
    private static let subjectWidth: CGFloat = 320
    private static let content = IslandMetrics.panelWidth - IslandRouter.gutter * 2

    var body: some View {
        HStack(spacing: 0) {
            apps(model.sound)
                .frame(width: Self.subjectWidth, alignment: .leading)
            Spacer(minLength: 12)
            transport
        }
        .frame(width: Self.content, height: IslandMetrics.bodyHeight)
        .padding(.horizontal, IslandRouter.gutter)
    }

    @ViewBuilder private func apps(_ state: SoundState) -> some View {
        if let list = state.apps, list.count == 1, let one = list.first {
            hero(one)
        } else if let list = state.apps, !list.isEmpty {
            many(list)
        } else if state.apps != nil {
            // Reachable only for the frame or two between the last stream
            // closing and the router dropping the chip.
            Color.clear
        } else {
            // nil is "could not measure" and renders as a dash. It is NOT
            // «тишина»: the process-object API is macOS 14.4+ and an older
            // system, or a failed read, must not be reported as a quiet
            // machine.
            Text("—")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .help(tr("Аудиосервер не ответил. Это «не измерено», а не «тихо».", "The audio server did not answer. That is “not measured”, not “silent”."))
        }
    }

    /// ONE app: the only case where the app we name and the app a command
    /// reaches coincided in every measurement, so the only case allowed to
    /// put a name beside the keys.
    private func hero(_ app: SoundApp) -> some View {
        HStack(spacing: 16) {
            AmbientGlow(size: 80, spread: 1.6) { icon(app, size: 80) }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(tr("аудиопоток открыт", "audio stream open"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 0.44))
                    .help(SoundFeature.outputStreamCaveat)
            }
            Spacer(minLength: 0)
        }
        .help(identity(app))
    }

    /// SEVERAL apps: four rows fit the column, and the overflow count goes
    /// INTO the caution line rather than onto a line of its own.
    private func many(_ list: [SoundApp]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(list.prefix(4)) { app in
                HStack(spacing: 11) {
                    AmbientGlow(size: 24, spread: 1.75) { icon(app, size: 24) }
                    Text(app.name)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color(white: 0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(identity(app))
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
            }
            Text((list.count > 4 ? tr("и ещё \(list.count - 4) · ", "and \(list.count - 4) more · ") : "")
                 + tr("команда уйдёт одному из них", "the command goes to one of them"))
                .font(.system(size: 9.5))
                .foregroundStyle(IslandPalette.warning.opacity(0.8))
                .lineLimit(1)
                .help(SoundFeature.ambiguousTargetCaveat)
                // Indented to the NAMES, not to the icons: it is a note
                // about the list, and hanging it off the left edge reads
                // as a fifth row.
                .padding(.leading, 35)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func icon(_ app: SoundApp, size: CGFloat) -> some View {
        if let image = app.icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22).fill(Color(white: 0.16))
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color(white: 0.5))
            }
            .frame(width: size, height: size)
        }
    }

    /// Bundle id and pid. They are what makes «Музыка» checkable rather
    /// than merely plausible, and they are a HOVER rather than a line
    /// because the panel is read at a glance and they are not. The name
    /// leads it so that a middle-truncated row is still recoverable.
    private func identity(_ app: SoundApp) -> String {
        let bundle = app.bundleIdentifier ?? tr("без bundle id", "no bundle id")
        return app.name + " · " + (app.pid.map { "\(bundle) · pid \($0)" } ?? bundle)
    }

    // MARK: transport

    /// Keys come ONLY from `SoundControl.availability.commands`, which is
    /// empty the day Apple removes the private symbol. Then this draws the
    /// reason instead — a dead key is worse than an absent one.
    @ViewBuilder private var transport: some View {
        let available = SoundControl.availability
        HStack(spacing: 8) {
            if available.isAvailable {
                ForEach(Self.keys.filter { available.commands.contains($0) },
                        id: \.rawValue) { SoundKey(command: $0) }
            } else {
                Text(tr("Транспорт недоступен", "Transport unavailable"))
                    .font(.system(size: 11))
                    .foregroundStyle(IslandPalette.warning)
                    .lineLimit(1)
                    .help(available.unavailableReason ?? tr("MediaRemote не отвечает", "MediaRemote is not responding"))
            }
        }
        .frame(height: 40)
    }

    /// Left to right. `togglePlayPause` is absent deliberately — see the
    /// file header.
    private static let keys: [SoundCommand] = [.previousTrack, .play, .pause, .nextTrack]
}

/// A transport key. Glyph only: the words that used to sit beside it were
/// there to stop a single ⏯ being read as state, and four equal keys with
/// nothing highlighted make that claim impossible on their own. What the
/// words said is on the hover, where it does not cost a glance.
private struct SoundKey: View {
    let command: SoundCommand

    @State private var hovering = false

    var body: some View {
        Button { SoundControl.send(command) } label: {
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : Color(white: 0.78))
                .frame(width: 44, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.20 : 0.075))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Self.tooltip(command))
    }

    private static func tooltip(_ command: SoundCommand) -> String {
        switch command {
        case .nextTrack, .previousTrack:
            return tr("\(command.title). Двигает курсор очереди; на краю очереди молча "
                 + "ничего не делает, и подтвердить результат нечем.",
                      "\(command.title). Moves the queue cursor; at the end of the "
                 + "queue it silently does nothing, and the result cannot be confirmed.")
        default:
            return tr("\(command.title). Уходит системному плееру; «принято» значит только, "
                 + "что сообщение поставлено в очередь.",
                      "\(command.title). Goes to the system player; “accepted” only "
                 + "means the message was queued.")
        }
    }
}

// MARK: - Registration

extension IslandSection {
    static let sound = IslandSection(
        id: .sound,
        chipTitle: tr("Звук", "Sound"),
        chipSymbol: "speaker.wave.2",
        // Cheap and pure: one Bool off a @Published struct the watcher
        // already wrote. FALSE when nobody has audio open, and false when
        // the sweep could not measure — which is also what keeps the
        // breath from ever running over silence.
        hasState: { $0.sound.hasOutput },
        footerSummary: { model in
            guard let apps = model.sound.apps, !apps.isEmpty else { return nil }
            if apps.count == 1 { return tr("Звук: \(apps[0].name)", "Sound: \(apps[0].name)") }
            return tr("Звук: ", "Sound: ") + SoundFeature.sources(apps.count)
        },
        makeBody: { model in AnyView(SoundSectionView(model: model)) }
    )
}
