import SwiftUI

// =====================================================================
// THE ROUTER'S EXTENSION POINT.
//
// The expanded panel is 560 x 280 and is never going to be anything else.
// It holds ONE section at a time; the rail above the body is the table of
// contents, and it lists ONLY the sections that have something real to
// show at this instant. On a quiet machine the rail has one chip
// (Память), the body is the memory section, and the footer is empty — the
// panel is what it has always been. It grows a tab when a feature
// genuinely has state, and loses it again when the state goes away. That
// is the whole answer to "there is too much in this panel".
//
// ---------------------------------------------------------------------
// HOW TO ADD A SECTION — you should not need to touch IslandRail.swift,
// IslandViews.swift or IslandModel.swift to do it.
//
//   1. Add a stable id:
//          extension IslandSectionID { static let printer = IslandSectionID("printer") }
//
//   2. Create Sources/IslandSectionPrinter.swift (FLAT — build.sh globs
//      Sources/*.swift and does not descend into subdirectories) holding
//      your 560 x 186 view and:
//
//          extension IslandSection {
//              static let printer = IslandSection(
//                  id: .printer,
//                  chipTitle: "Печать",
//                  chipSymbol: "printer",
//                  hasState: { $0.printer?.isActive == true },
//                  footerSummary: { m in m.printer.map { "Печать \($0.percent)%" } },
//                  makeBody: { m in AnyView(PrinterSection(model: m)) }
//              )
//          }
//
//   3. Register it, in IslandFeatures.swift and nowhere else:
//          IslandSectionRegistry.register(.printer)
//
// FIVE RULES, all of them load-bearing:
//
//   * `hasState` must be CHEAP and PURE. It is asked once per published
//     panel refresh, on the main thread. No syscalls, no NSWorkspace, no
//     file I/O — read a value your sampler already published.
//
//   * `hasState` must be FALSE when the feature has nothing to say. A
//     chip that is always present is a chip the user did not ask for.
//     "The printer is configured" is not state; "the printer is printing"
//     is.
//
//   * The body is handed a 560 x 186 canvas and must not want more. It is
//     laid out with `.frame(width: 560, height: 186, alignment: .top)`;
//     anything taller is clipped, not accommodated.
//
//   * `footerSummary` is ONE SHORT CLAUSE — "Печать 62%", "Тоннель выкл".
//     It is shown only while some OTHER section is selected, joined with
//     " · " into an 18 pt line. Return nil for "nothing worth a word".
//
//   * Whatever your `hasState` and `footerSummary` read must be reachable
//     from `IslandModel` and must be `@Published` there, because
//     `IslandModel` is the only object the island's views observe. A
//     feature that publishes from its own ObservableObject will update
//     its body and leave the rail and the footer stale.
// =====================================================================

/// Stable identity for a section. A string rather than an enum case
/// precisely so that adding one does not mean editing a shared type that
/// every switch statement in the router would then have to handle.
struct IslandSectionID: Hashable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

extension IslandSectionID {
    /// The only section that always has state, and therefore the fallback
    /// selection whenever the previously selected one goes quiet.
    static let memory = IslandSectionID("memory")
}

/// One tab of the router. A value, not a protocol with an associated
/// view type: the rail has to hold a heterogeneous list of these and ask
/// each one whether it is live, which an existential with an associated
/// type cannot do without more ceremony than the job is worth.
struct IslandSection: Identifiable {
    let id: IslandSectionID
    /// Rail chip label. Two words at most — the rail is 28 pt tall and
    /// 560 pt wide and may have to hold five of these.
    let chipTitle: String
    /// SF Symbol name for the chip. Empty string for "no icon".
    let chipSymbol: String
    /// Cheap and pure. See the rules above.
    let hasState: (IslandModel) -> Bool
    /// One short clause, or nil.
    let footerSummary: (IslandModel) -> String?
    /// The 560 x 186 body.
    let makeBody: (IslandModel) -> AnyView
}

/// The rail's contents, in rail order.
///
/// Not a `let` array in the router, because then adding a section would
/// mean editing the router. Registration order is rail order, and Память
/// is registered first so it is always leftmost.
enum IslandSectionRegistry {

    private(set) static var sections: [IslandSection] = [.memory]

    /// Appends, or replaces an existing section with the same id.
    /// Main thread only — it is read during SwiftUI layout.
    static func register(_ section: IslandSection) {
        precondition(Thread.isMainThread, "IslandSectionRegistry is main-thread only")
        if let i = sections.firstIndex(where: { $0.id == section.id }) {
            sections[i] = section
        } else {
            sections.append(section)
        }
    }

    static func section(_ id: IslandSectionID) -> IslandSection? {
        sections.first { $0.id == id }
    }
}
