import AppKit
import ApplicationServices

// =====================================================================
// «Окна» — does the badge count what the user thinks it counts, and does
// the close path actually close windows?
//
//   /Applications/MacPulse.app/Contents/MacOS/MacPulse --windows-probe
//   ...                       --windows-probe list <pid>
//   ...                       --windows-probe close <pid> <index> --yes
//   ...                       --windows-probe others <pid> --yes
//
// THREE THINGS IT CHECKS, and only the first is about permissions.
//
//   A. THE BADGE IS NOT A WINDOW COUNT. One table, built from the
//      SHIPPING ProcessSampler on one side and the SHIPPING
//      AppWindowList.scan on the other: processes in the group next to
//      windows on screen. The whole feature exists because those two
//      numbers are different, and this is where that is a measurement
//      rather than an assertion.
//
//   B. THE CLOSE PATH, END TO END, WITHOUT ANY PERMISSION. MacPulse
//      creates four real NSWindows of its own, then drives the real
//      `scan` / `close` / close-others over them and checks the result
//      against `NSApp.windows`, which knows nothing about accessibility.
//      A process needs no grant to read its own AX tree, so this half
//      runs on a machine where MacPulse has never been given anything —
//      and it exercises enumeration, titles, main detection, the close
//      button press and "all but the main one" against real AppKit
//      windows.
//
//      It runs OFF the main thread, and has to: the main thread is what
//      would answer a self-directed AX request, so asking from it
//      deadlocks until the messaging timeout. See AppWindowList's header.
//
//   C. ONE NAMED APP, for driving a real target by hand. `close` and
//      `others` refuse to do anything without `--yes`, because this file
//      is the one place in MacPulse where a command line could close
//      somebody's window.
//
// WHAT IT CANNOT DO. Section A and section C need the Accessibility
// grant, and MacPulse asks for that ONLY when a user opens a badge
// popover. Without it both print `notTrusted` and stop — which is also
// the exact state the popover degrades to, so a run on an ungranted
// machine is a check of the degraded path rather than a failure.
// =====================================================================

enum WindowProbe {

    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        print("    \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    /// `String(format:)` ignores width flags on `%@` here, so the columns
    /// are padded by hand — a ragged table is a table nobody reads, and
    /// this one is the feature's headline evidence.
    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let gap = max(0, width - text.count)
        return right ? String(repeating: " ", count: gap) + text
                     : text + String(repeating: " ", count: gap)
    }

    private static func mb(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f МБ", Double(v) / 1_048_576)
    }

    static func run(arguments: [String]) -> Never {
        print("=== MacPulse --windows-probe ===")
        print("")
        let trusted = AppWindowList.isTrusted
        print("Универсальный доступ (Accessibility): \(trusted ? "ЕСТЬ" : "НЕТ")")
        print("  read with AXIsProcessTrusted(), which never prompts. MacPulse asks")
        print("  for this permission in exactly one place — the first time a user")
        print("  opens a badge popover — and never at launch. See AppWindowList.swift.")
        print("")

        var rest = arguments
        if let i = rest.firstIndex(of: "--windows-probe") { rest = Array(rest[(i + 1)...]) }
        let yes = rest.contains("--yes")
        rest = rest.filter { $0 != "--yes" }

        switch rest.first {
        case "list":
            guard let pid = rest.dropFirst().first.flatMap({ pid_t($0) }) else { usage() }
            listOne(pid)
        case "close":
            guard let pid = rest.dropFirst().first.flatMap({ pid_t($0) }),
                  let index = rest.dropFirst(2).first.flatMap({ Int($0) }) else { usage() }
            closeOne(pid: pid, index: index, yes: yes)
        case "others":
            guard let pid = rest.dropFirst().first.flatMap({ pid_t($0) }) else { usage() }
            closeOthers(pid: pid, yes: yes)
        case "self":
            accessState()
        default:
            badgeTable()
            print("")
            accessState()
        }

        print("")
        if failures == 0 { print("=== все проверки пройдены ==="); exit(0) }
        print("=== \(failures) проверок провалено ==="); exit(1)
    }

    private static func usage() -> Never {
        print("usage: --windows-probe [list <pid> | close <pid> <index> --yes")
        print("                        | others <pid> --yes | self]")
        exit(2)
    }

    // MARK: - A. processes vs windows

    /// Windows per owning PID straight from the window server. NO
    /// ACCESSIBILITY AT ALL — this is the independent witness the AX
    /// numbers below are checked against, and the only reason section A
    /// is a measurement instead of one API agreeing with itself.
    ///
    /// Layer 0 only: layer != 0 is menu bars, shadows, tooltips and the
    /// desktop. On-screen only, which is also why a MINIMISED window is
    /// counted by AX and not by this — the two columns disagreeing on a
    /// minimised window is correct behaviour, not a discrepancy.
    private static func windowServerCounts() -> [pid_t: Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [pid_t: Int] = [:]
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            out[pid, default: 0] += 1
        }
        return out
    }

    private static func badgeTable() {
        print("--- A. что считает серый бейдж ----------------------------------")
        print("    «процессов» — ровно то число, которое рисует бейдж строки:")
        print("    AppUsage.memberPIDs.count из живого ProcessSampler.")
        print("    «окон (AX)» — AppWindowList.scan, то есть сам feature.")
        print("    «окон (WS)» — CGWindowList, оконный сервер, без всякого AX:")
        print("    независимый свидетель, а не второе мнение того же API.")
        print("")

        let model = IslandModel()
        model.start()
        // Two ticks: the sampler needs a delta before the group table is
        // worth reading.
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))
        let apps = model.snapshot?.processes?.apps ?? []
        model.stop()
        let server = windowServerCounts()

        print("    " + pad("приложение", 24) + pad("процессов", 11, right: true)
              + pad("окон (AX)", 12, right: true) + pad("окон (WS)", 12, right: true))
        var disagreements = 0, scanned = 0, agreed = 0, compared = 0
        var anyUnresolved = false
        for app in apps.prefix(12) where app.isApplication {
            let (scan, _) = AppWindowList.scan(pid: app.pid)
            var windows: String
            if let n = scan.count {
                windows = String(n)
            } else {
                switch scan.failure {
                case .notTrusted: windows = "нет прав"
                case .notResponding: windows = "молчит"
                case .noSuchProcess: windows = "ушёл"
                case .unresolved, nil: windows = "—"
                }
            }
            var unresolvedSeen = false
            if case .unresolved = scan.failure { windows += " *"; unresolvedSeen = true }
            anyUnresolved = anyUnresolved || unresolvedSeen
            let ws = server[app.pid].map(String.init) ?? "—"
            print("    " + pad(app.name, 24) + pad(String(app.memberPIDs.count), 11, right: true)
                  + pad(windows, 12, right: true) + pad(ws, 12, right: true))
            if let n = scan.count {
                scanned += 1
                if n != app.memberPIDs.count { disagreements += 1 }
                if let s = server[app.pid] {
                    compared += 1
                    if n == s { agreed += 1 }
                }
            }
        }
        if scanned == 0 {
            print("")
            print("    Ни одного приложения прочитать не удалось. Без «Универсального")
            print("    доступа» это единственный возможный ответ, и popover в этом")
            print("    состоянии показывает ровно ту же строку и ту же кнопку.")
            return
        }
        if anyUnresolved {
            print("")
            print("    * число окон верное — оконный сервер подтверждает его в колонке")
            print("      справа, — но сами элементы окон этому процессу не читаются.")
            print("      Что это значит и почему, разбирает раздел B.")
        }
        print("")
        check(disagreements > 0,
              ">>> у приложений процессов НЕ столько же, сколько окон "
              + "(расхождений: \(disagreements) из \(scanned)) — бейдж считает не окна")
        check(compared > 0 && agreed == compared,
              ">>> счёт окон сходится с оконным сервером, который про AX ничего не знает "
              + "(\(agreed) из \(compared))")
    }

    // MARK: - B. which kind of access does THIS process have

    /// Three states, and telling them apart is the whole point.
    ///
    /// They were separated because the middle one was MEASURED here and
    /// is invisible otherwise: a binary run from a terminal whose parent
    /// app holds the Accessibility grant reads `AXIsProcessTrusted() ==
    /// true`, gets correct window COUNTS, and still cannot resolve a
    /// single window element. Before `.unresolved` existed that state
    /// drew a list of rows titled with the app's own name and a bulk
    /// button promising zero.
    /// Public CoreGraphics, no permission, no accessibility. It matters
    /// here because a locked screen produces `.unresolved` and looks
    /// exactly like a missing permission if nobody asks.
    private static func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
            || (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private static func accessState() {
        print("--- B. какой доступ у ЭТОГО процесса ----------------------------")
        print("    экран заблокирован: \(screenIsLocked() ? "ДА" : "нет")")
        let trusted = AppWindowList.isTrusted
        let server = windowServerCounts()
        // The busiest app on screen is the most informative target.
        let target = server.max { $0.value < $1.value }?.key
        guard let target else { print("    на экране нет ни одного окна — не на чем проверить"); return }
        let (scan, _) = AppWindowList.scan(pid: target)
        let name = NSRunningApplication(processIdentifier: target)?.localizedName ?? "pid \(target)"

        print("    цель: \(name) — оконный сервер насчитал \(server[target] ?? 0) окон")
        print("")
        if !trusted {
            print("    НЕТ ДОСТУПА. AXIsProcessTrusted() = false, и запросы отвергаются")
            print("    начисто (kAXErrorAPIDisabled, -25211). Popover в этом состоянии")
            print("    открывается, показывает одну строку и кнопку в настройки, и")
            print("    половина с процессами продолжает работать.")
            check(scan.failure == .notTrusted, ">>> scan честно говорит notTrusted")
            return
        }
        if case .unresolved(let n) = scan.failure {
            print("    СЧИТАЕТСЯ, НО НЕ ЧИТАЕТСЯ. AXIsProcessTrusted() = true,")
            print("    kAXWindows вернул \(n) элементов — число верное, его подтверждает")
            print("    оконный сервер, — но ни один из них не окно: AXRole = AXApplication,")
            print("    кнопки закрытия нет.")
            print("")
            if screenIsLocked() {
                print("    ЭКРАН ЗАБЛОКИРОВАН (CGSSessionScreenIsLocked). Это и есть")
                print("    причина: macOS согласна сказать, СКОЛЬКО у приложения окон,")
                print("    но не выдаёт сами окна с заблокированного экрана. Разблокируйте")
                print("    и запустите этот же probe снова — он покажет заголовки и")
                print("    кнопки закрытия.")
            } else {
                print("    Экран НЕ заблокирован, так что дело не в нём: это приложение")
                print("    не отдаёт своё дерево окон. Закрыть их отсюда нельзя.")
            }
            print("")
            print("    В любом случае ни одно окно в этом состоянии закрыть нельзя, и")
            print("    popover говорит это вслух вместо бесполезного списка строк,")
            print("    названных именем самого приложения.")
            check(true, ">>> scan распознал состояние и не выдал мусорный список")
            return
        }
        print("    ДОСТУП ВЫДАН. Элементы окон читаются полностью:")
        for r in scan.windows ?? [] {
            print(String(format: "      [%d] main=%@ закрываемо=%@  %@",
                         r.id, r.isMain ? "да" : "нет", r.canClose ? "да" : "нет",
                         r.title ?? "(без заголовка)"))
        }
        check(scan.windows?.contains { $0.canClose } == true,
              ">>> хотя бы у одного окна есть кнопка закрытия, которую можно нажать")
        check(scan.windows?.filter(\.isMain).count == 1,
              ">>> ровно одно окно помечено главным — то, что переживёт «Закрыть остальные»")
    }

    // MARK: - C. one app by pid

    private static func listOne(_ pid: pid_t) {
        print("--- C. pid \(pid) ------------------------------------------------")
        let (scan, _) = AppWindowList.scan(pid: pid)
        if let why = scan.failure { print("    не прочитать: \(why)"); return }
        print("    окон: \(scan.windows?.count ?? 0)")
        for r in scan.windows ?? [] {
            print(String(format: "      [%d] main=%@ свёрнуто=%@ закрываемо=%@  %@",
                         r.id, r.isMain ? "да" : "нет", r.isMinimized ? "да" : "нет",
                         r.canClose ? "да" : "нет", r.title ?? "(без заголовка)"))
        }
        print("    «Закрыть остальные» закрыло бы: \(scan.closableOthers.count)")
        print("")
        print("    процессы группы (диагностика, кнопок у них нет):")
        for m in AppWindowList.members([pid]) { print("      \(m.pid)  \(m.name)  \(mb(m.footprintBytes))") }
    }

    private static func closeOne(pid: pid_t, index: Int, yes: Bool) {
        guard yes else { print("    отказ: нужен --yes. Это единственное место в MacPulse,")
                         print("    откуда командная строка может закрыть чужое окно."); return }
        let (scan, elements) = AppWindowList.scan(pid: pid)
        guard scan.failure == nil, elements.indices.contains(index) else {
            print("    нет такого окна (\(String(describing: scan.failure)))"); return
        }
        print("    до: \(scan.windows?.count ?? 0) окон")
        print("    жму крестик на [\(index)] \(scan.windows?[index].title ?? "—")")
        _ = AppWindowList.close(elements[index])
        Thread.sleep(forTimeInterval: 0.7)
        let (after, _) = AppWindowList.scan(pid: pid)
        print("    после: \(after.windows?.count ?? -1) окон")
    }

    private static func closeOthers(pid: pid_t, yes: Bool) {
        guard yes else { print("    отказ: нужен --yes."); return }
        let (scan, elements) = AppWindowList.scan(pid: pid)
        guard scan.failure == nil else { print("    не прочитать: \(String(describing: scan.failure))"); return }
        let targets = scan.closableOthers
        print("    до: \(scan.windows?.count ?? 0) окон; закрываю \(targets.count), "
              + "останется: \(scan.windows?.first(where: \.isMain)?.title ?? "—")")
        for r in targets where elements.indices.contains(r.id) { _ = AppWindowList.close(elements[r.id]) }
        Thread.sleep(forTimeInterval: 1.0)
        let (after, _) = AppWindowList.scan(pid: pid)
        print("    после: \(after.windows?.count ?? -1) окон")
        for r in after.windows ?? [] { print("      выжило: \(r.title ?? "—")") }
    }
}
