import SwiftUI

// =====================================================================
// «Встреча» — the next-meeting section, and the collapsed strip's
// countdown ring.
//
// Registered through the router's documented extension point: an id, a
// section value, one line in IslandFeatures. Nothing in IslandRail.swift,
// IslandViews.swift or IslandRouter had to change to add it.
//
// THE CHIP IS ABSENT MOST OF THE TIME, AND ON THIS MACHINE IT IS ABSENT
// ALWAYS. `hasState` is `model.calendar.hasState`, i.e. `next != nil`,
// and `next` is the first TIMED event in the next 24 hours. This machine
// has five readable calendars and three events in the next 45 days, all
// of them all-day US Holidays entries — so the engine's honest answer is
// `next == nil`, the rail keeps its one chip (Память) and the island is
// exactly what it was. "The calendar is connected" is not state; "there
// is a meeting coming" is. A holiday 130 hours away is not a meeting.
//
// THE TITLE IS DRAWN HERE AND NOWHERE ELSE. `CalendarEvent.title` is the
// user's private calendar; it lives in memory, and the one place it is
// ever put on screen is the 420 pt line in the body below — a panel the
// user opened on purpose. It is NOT in `footerSummary` (18 pt of shared
// space, visible while another tab is selected), NOT in the collapsed
// strip (560 pt of always-on menu bar), NOT in the strip's tooltip, and
// NOT in any log line: the engine's `description` is redacted precisely
// so that a `print(event)` three files away cannot leak it, and this file
// must not undo that. If you add a diagnostic here, print
// `event.redactedDescription`.
//
// READ-ONLY, like the printer section. There is no "join", no "snooze"
// and no "open in Calendar" — MacPulse reads the store and never writes
// it, which is what makes `NSCalendarsFullAccessUsageDescription` an
// honest string.
//
// WHAT THIS SECTION DOES NOT PROMISE. The engine's verification could not
// exercise declined invitations or cancelled events (this machine has
// neither), and never saw `.EKEventStoreChanged` fire. So nothing here
// says "live" or "синхронизировано": the footnote states the horizon and
// the time of the last query and lets the user judge the staleness
// themselves. Worst case that number is 60 s old — the backstop's
// interval — and saying so is cheaper than pretending otherwise.
// =====================================================================

extension IslandSectionID {
    static let calendar = IslandSectionID("calendar")
}

// MARK: - View-side facts

/// The arithmetic and the Russian the VIEW needs, kept out of
/// `CalendarFmt` — that one is the engine's formatter and deliberately
/// takes no title and no counts. Same split as `PrinterFeature` against
/// the printer's views.
enum MeetingFeature {

    /// How far the meeting has come through its imminent window, 0...1.
    ///
    /// nil OUTSIDE THE WINDOW, and that is the point. There is no
    /// "percentage of the way to a meeting" — the clock does not start
    /// anywhere — so for the 23 hours 45 minutes before the window opens
    /// the ring draws its track and no fill, exactly as the print ring
    /// does during PREPARE. A zero-length arc would read as "0% of the
    /// way there", which is a different and false claim. When the meeting
    /// does enter the window the ring starts filling, and the ring
    /// becoming live IS the imminent signal.
    static func approach(_ event: CalendarEvent?, asOf now: Date = Date()) -> Double? {
        guard let event, event.imminentWindow > 0,
              let remaining = event.secondsUntilStart(asOf: now),
              remaining <= event.imminentWindow
        else { return nil }
        return min(max(1 - remaining / event.imminentWindow, 0), 1)
    }

    /// "14:30 – 15:30", or just "14:30" when EventKit gave no end date.
    /// An all-day event has no meaningful interval and says so.
    static func interval(_ event: CalendarEvent) -> String {
        if event.isAllDay { return tr("весь день", "all day") }
        guard let end = event.endDate else { return CalendarFmt.clock(event.startDate) }
        return CalendarFmt.clock(event.startDate) + " – " + CalendarFmt.clock(end)
    }

    /// Russian plural for a count, or "—" for "was never measured".
    /// `nil` is not zero: 0 calendars is a real answer (an account with
    /// none), `nil` means no query has completed yet.
    static func plural(_ count: Int?, _ one: String, _ few: String, _ many: String) -> String {
        guard let count else { return "—" }
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if mod100 >= 11 && mod100 <= 14 { word = many }
        else if mod10 == 1 { word = one }
        else if mod10 >= 2 && mod10 <= 4 { word = few }
        else { word = many }
        return "\(count) \(word)"
    }

    /// The 12 pt line at the bottom of the body: what was looked at, how
    /// far ahead, and when. Every clause is a measured fact off the
    /// snapshot; none of them is the title.
    static func footnote(_ snapshot: CalendarSnapshot) -> String {
        var parts = [plural(snapshot.calendarCount, tr("календарь", "calendar"), tr("календаря", "calendars"), tr("календарей", "calendars"))]
        let hours = Int((snapshot.horizon / 3600).rounded())
        if hours > 0 { parts.append(tr("горизонт \(hours) ч", "horizon \(hours) h")) }
        parts.append(tr("обновлено ", "updated ") + CalendarFmt.clock(snapshot.lastQueryAt))
        // candidateCount counts the next meeting too, so only a SECOND
        // one is worth mentioning.
        if let n = snapshot.candidateCount, n > 1 {
            parts.append(tr("дальше ", "then ") + plural(n - 1, tr("встреча", "meeting"), tr("встречи", "meetings"), tr("встреч", "meetings")))
        }
        return parts.joined(separator: " · ")
    }

    /// The colour of the calendar the meeting lives on, as the user set
    /// it in Calendar.app. Grey — never black, never a guess — when the
    /// calendar has no colour or it would not convert to sRGB.
    static func tint(_ event: CalendarEvent?) -> Color {
        guard let nsColor = event?.calendarTint?.nsColor else { return IslandPalette.unknown }
        return Color(nsColor: nsColor)
    }
}

// MARK: - Collapsed strip slot

/// The countdown in the trailing wing. On screen ONLY in the 15 minutes
/// before a meeting starts (`CalendarSnapshot.isImminent`), which is the
/// budget the architecture spike set: outside that window the meeting is
/// something you go and look at, not something that earns ambient pixels
/// in the menu bar for 23 hours a day.
///
/// It borrows the print slot's geometry exactly — 14 pt ring, 4 pt gap,
/// 25 pt text — so `IslandMetrics.trailingLayout` needs no new arithmetic
/// and the wing has one worst case, not two. The ring FILLS as the
/// meeting approaches (full = now), the same direction the print ring
/// runs, and the digits are the minutes left, because the question a
/// glance asks is "do I have to leave".
///
/// `countdown` is passed IN rather than computed here: the collapsed
/// island publishes almost nothing, so a string formatted inside this
/// body would freeze at whatever minute it was first drawn. `IslandModel`
/// re-derives it on the 1 Hz tick and republishes only when the minute
/// actually changes — see `refreshCalendarStrip()`.
struct MeetingStripSlot: View {
    let event: CalendarEvent
    let countdown: String
    let showsText: Bool

    var body: some View {
        HStack(spacing: IslandMetrics.ringTextGap) {
            ProgressRing(fraction: MeetingFeature.approach(event),
                         tint: MeetingFeature.tint(event),
                         diameter: IslandMetrics.ringDiameter, lineWidth: 2.4)
            if showsText {
                Text(countdown)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(white: 0.82))
                    .lineLimit(1)
                    // Fixed width, like the print slot: "14′" and "1:05"
                    // must occupy the same box or the wing twitches as
                    // the estimate crosses an hour.
                    .frame(width: IslandMetrics.slotTextWidth, alignment: .leading)
            }
        }
        .help(tooltip)
    }

    /// NO TITLE IN THE TOOLTIP. A tooltip is drawn over other apps'
    /// windows and survives a screen recording; the calendar name and the
    /// clock say everything a glance needs without naming what the
    /// meeting is.
    ///
    /// BUILT HERE, WITH INTERPOLATION, AND NOT INLINE WITH `+`. It used to
    /// be a chain of four `+` with an `Optional.map` in the middle, sitting
    /// inside `body`. `+` is one of the most heavily overloaded operators in
    /// the language, and the solver explores those overloads combinatorially
    /// across a chain: measured with
    /// `-warn-long-expression-type-checking`, that one expression cost
    /// 872 ms and dragged the whole `body` getter to 2213 ms — against a
    /// 400 ms budget, and it was the only place in ~61 files over the line.
    ///
    /// On this toolchain it merely made the build slow. On the Swift in
    /// Xcode 15.4 the solver gave up entirely: "the compiler is unable to
    /// type-check this expression in reasonable time", which is a HARD
    /// ERROR. So this compiled here and nowhere else — anyone cloning the
    /// repo with an older toolchain could not build MacPulse at all, and
    /// only CI on a different compiler found it.
    ///
    /// Interpolation is not overloaded the same way; each `+=` is its own
    /// small problem. Same string, and now it type-checks in nothing.
    private var tooltip: String {
        var line = tr("Встреча через \(CalendarFmt.countdown(event))", "Meeting in \(CalendarFmt.countdown(event))")
        line += tr(" · начало в \(CalendarFmt.clock(event.startDate))", " · starts at \(CalendarFmt.clock(event.startDate))")
        if let calendar = event.calendarTitle { line += " · \(calendar)" }
        return line
    }
}

// MARK: - The 560 x 186 body

private struct CalendarSectionView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = model.calendar.next {
                content(event)
            } else {
                // THE STATE THIS MACHINE IS ACTUALLY IN. Also the frame or
                // two between a meeting starting and the router dropping
                // the chip — the rail never offers this tab otherwise.
                empty
            }
            Spacer(minLength: 0)
            footnote
        }
        .frame(width: IslandMetrics.panelWidth - IslandRouter.gutter * 2,
               height: IslandMetrics.bodyHeight,
               alignment: .top)
        .padding(.horizontal, IslandRouter.gutter)
    }

    private var tint: Color { MeetingFeature.tint(model.calendar.next) }

    // ---- there is a meeting ----

    @ViewBuilder private func content(_ event: CalendarEvent) -> some View {
        // --- header: which calendar, and whether it is close ---
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color(white: 0.3), lineWidth: 0.5))
            Text((event.calendarTitle ?? tr("без календаря", "no calendar")).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color(white: 0.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let badge = badgeText(event) {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
            }
        }
        .frame(height: 18)

        Spacer(minLength: 0).frame(height: 10)

        HStack(alignment: .top, spacing: 16) {
            // --- when it starts, in absolute time ---
            //
            // The clock and the countdown are different questions and the
            // panel answers both: "14:30" is what you tell someone else,
            // "через 12 мин" is what you do something about. The ring
            // around the clock is the imminent window filling up.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.08))
                ProgressRing(fraction: MeetingFeature.approach(event),
                             tint: tint, diameter: 74, lineWidth: 6)
                VStack(spacing: 0) {
                    Text(CalendarFmt.clock(event.startDate))
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(tr("начало", "start"))
                        .font(.system(size: 9))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 0) {
                // --- THE ONE PLACE THE TITLE IS EVER DRAWN ---
                Text(titleLine(event))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 18, alignment: .leading)

                Spacer(minLength: 0).frame(height: 6)

                // --- the countdown, which is the whole feature ---
                //
                // Recomputed from `Date()` every time this body is
                // evaluated, and the panel is re-evaluated at 1 Hz off
                // MetricsEngine while it is open, so it ticks without the
                // engine publishing anything.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(tr("через", "in"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.5))
                    Text(CalendarFmt.countdown(event))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)

                Spacer(minLength: 0).frame(height: 10)

                HStack(spacing: 8) {
                    Text(MeetingFeature.interval(event))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color(white: 0.7))
                    Spacer(minLength: 8)
                    Text(windowNote(event))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(white: 0.42))
                        .lineLimit(1)
                }
                .frame(height: 16)

                Spacer(minLength: 0).frame(height: 7)

                // The last 15 minutes, drawn. Empty track until the
                // meeting enters the window — the same nil-is-not-zero
                // rule the ring above follows, on the same number.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.16))
                        if let f = MeetingFeature.approach(event) {
                            Capsule().fill(tint.opacity(0.85))
                                .frame(width: geo.size.width * CGFloat(f))
                        }
                    }
                }
                .frame(height: 5)
            }
            .frame(height: 96, alignment: .top)
        }
    }

    /// nil when there is nothing worth a badge. `isAllDay` can only
    /// appear here if `skipsAllDayEvents` was turned off in the engine's
    /// configuration — the shipping default never surfaces one — but the
    /// flag travels in the value, so the view tells the truth about it
    /// rather than counting down to midnight.
    private func badgeText(_ event: CalendarEvent) -> String? {
        if event.isAllDay { return tr("ВЕСЬ ДЕНЬ", "ALL DAY") }
        if event.isImminent { return tr("СКОРО", "SOON") }
        return nil
    }

    /// An event with no title is not an error and gets no "—": it is a
    /// real thing people put in calendars, and it still has a time.
    private func titleLine(_ event: CalendarEvent) -> String {
        guard let title = event.title, !title.isEmpty else { return tr("Без названия", "No title") }
        return title
    }

    private func windowNote(_ event: CalendarEvent) -> String {
        guard let remaining = event.secondsUntilStart() else { return tr("началась", "started") }
        let window = event.imminentWindow
        guard window > 0 else { return "" }
        if remaining <= window { return tr("в окне \(Int((window / 60).rounded())) мин", "in \(Int((window / 60).rounded())) min window") }
        let untilWindow = Int(((remaining - window) / 60).rounded(.up))
        return tr("окно через \(untilWindow) мин", "window in \(untilWindow) min")
    }

    // ---- there is no meeting: the normal state on this machine ----

    @ViewBuilder private var empty: some View {
        let words = emptyWords(model.calendar.status)

        Text(tr("БЛИЖАЙШАЯ ВСТРЕЧА", "NEXT MEETING"))
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color(white: 0.4))
            .frame(height: 18, alignment: .leading)

        Spacer(minLength: 0).frame(height: 14)

        Text(words.headline)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(white: 0.75))
            .frame(height: 20, alignment: .leading)

        Spacer(minLength: 0).frame(height: 7)

        VStack(alignment: .leading, spacing: 4) {
            // Indexed, not `id: \.self` — a branch below can legitimately
            // produce two empty strings, and two identical ForEach ids is
            // a SwiftUI runtime complaint about a line nobody can see.
            // Empties are dropped rather than drawn as blank rows.
            let lines = words.lines.filter { !$0.isEmpty }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(1)
            }
        }
    }

    /// Every branch is a state the engine can genuinely publish. The
    /// rail will not offer this tab in any of them — `hasState` is false
    /// whenever `next` is nil — so this is what the body says if it is
    /// ever asked anyway, and it must not say anything untrue in order
    /// to fill the space.
    private func emptyWords(_ status: CalendarStatus) -> (headline: String, lines: [String]) {
        switch status {
        case .ready:
            let hours = Int((model.calendar.horizon / 3600).rounded())
            return (tr("Ничего не запланировано", "Nothing scheduled"),
                    [tr("В ближайшие \(hours) ч событий со временем начала нет.", "No timed events in the next \(hours) h."),
                     tr("События на весь день — праздники и дни рождения — встречами не считаются.", "All-day events — holidays and birthdays — are not meetings.")])
        case .off:
            return (tr("Календарь выключен", "Calendar is off"),
                    [tr("Включите «Показывать следующую встречу» в меню MacPulse.", "Turn on “Show next meeting” in the MacPulse menu."),
                     tr("Пока он выключен, приложение не обращается к Календарю вообще.", "While it is off, the app never touches Calendar.")])
        case .requesting:
            return (tr("Ждём разрешения", "Waiting for permission"),
                    [tr("macOS спрашивает про доступ к Календарю.", "macOS is asking for Calendar access."), ""])
        case .unavailable(let reason):
            // `unavailableHint` returns nil for the two cases that are a
            // BUILD error rather than a user problem (a missing Info.plist
            // key, a failed request). There is nothing to tell the user
            // about those, so the second line stays empty instead of
            // inventing advice they cannot act on.
            return (tr("Доступ к Календарю недоступен", "Calendar access unavailable"),
                    [CalendarFmt.unavailableHint(.unavailable(reason)) ?? "", ""])
        }
    }

    // ---- the line at the bottom, in every state ----

    private var footnote: some View {
        Text(MeetingFeature.footnote(model.calendar))
            .font(.system(size: 8.5))
            .foregroundStyle(Color(white: 0.34))
            .lineLimit(1)
            .frame(height: 12, alignment: .leading)
    }
}

// MARK: - Registration

extension IslandSection {
    static let calendar = IslandSection(
        id: .calendar,
        chipTitle: tr("Встреча", "Meeting"),
        chipSymbol: "calendar",
        // Cheap and pure: one Optional read off a @Published property the
        // engine's observer already wrote. No syscall, no EventKit, no
        // I/O — see IslandSection.swift. False whenever there is no timed
        // meeting in the horizon, which on this machine is always.
        hasState: { $0.calendar.hasState },
        // One short clause, and never the title. "Встреча через 12 мин".
        footerSummary: { CalendarFmt.footer($0.calendar) },
        makeBody: { model in AnyView(CalendarSectionView(model: model)) }
    )
}
