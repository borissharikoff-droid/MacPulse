import Foundation

// =====================================================================
// Two languages, chosen in the menu.
//
// WHY NOT .lproj AND NSLocalizedString, which is the obvious answer.
// MacPulse has no Xcode project and no resource pipeline: the bundle is
// assembled by hand in build.sh, and `genstrings` over ~60 flat files
// would add a build step whose failure mode is a silently untranslated
// string — the worst kind, because it looks fine to whoever built it.
// More to the point, NSLocalizedString reads the SYSTEM language, and
// the thing being asked for here is a switch the user flips, in the app,
// against a Russian system. That needs its own preference either way.
//
// So: `tr("Память", "Memory")`, inline at the call site. The Russian is
// still readable where it is drawn, the English sits beside it, and
// there is no key table that can drift away from the text it names. A
// missing translation is a compile error rather than a string that falls
// back to its own key.
//
// CHANGING IT REBUILDS THE UI RATHER THAN REACTIVELY UPDATING IT.
// `tr` returns a plain String, so a SwiftUI view that has already drawn
// one has no reason to redraw. Rather than thread a language token
// through every view — and be wrong wherever it was forgotten — the
// language change tears the panel down and lets it be rebuilt, and
// rebuilds the menu. Both are cheap, both happen at most when a person
// picks a menu item, and neither can be forgotten in a file somewhere.
// =====================================================================

enum AppLanguage: String, CaseIterable {
    /// Follow the system: Russian if macOS is set to Russian, else English.
    case system
    case ru
    case en

    var title: String {
        switch self {
        case .system: return tr("Как в системе", "Same as system")
        case .ru:     return "Русский"
        case .en:     return "English"
        }
    }
}

enum Lang {

    static let didChange = Notification.Name("com.local.macpulse.languageDidChange")

    private static let key = "language"

    /// What the user picked, which is not the same as what is displayed:
    /// `.system` resolves to one of the two at read time.
    static var preference: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
            ?? .system
    }

    /// The language actually in use right now. Never `.system`.
    static var resolved: AppLanguage {
        switch preference {
        case .ru: return .ru
        case .en: return .en
        case .system:
            // `preferredLanguages` is the user's ORDERED list, which is
            // what macOS itself uses; `Locale.current.language` on a
            // Russian Mac with an English region answers the region's
            // language and would read as English.
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("ru") ? .ru : .en
        }
    }

    static var isEnglish: Bool { resolved == .en }

    static func set(_ new: AppLanguage) {
        guard new != preference else { return }
        UserDefaults.standard.set(new.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// Every user-visible string in MacPulse goes through this.
///
/// Deliberately NOT applied to probe output (`--probe`, `--rail-probe`
/// and the rest). Those are developer tools whose readers are looking at
/// them next to the source that printed them; translating them would
/// double the text that has to stay in step with the code, for nobody.
@inline(__always)
func tr(_ ru: String, _ en: String) -> String {
    Lang.isEnglish ? en : ru
}

/// Russian has three plural forms and English has two, so a count and a
/// noun cannot be assembled by concatenation in either language without
/// getting one of them wrong.
///
///     plural(1,  "запись", "записи", "записей", "entry",   "entries")
///     -> "1 запись" / "1 entry"
func plural(_ n: Int,
            _ ruOne: String, _ ruFew: String, _ ruMany: String,
            _ enOne: String, _ enMany: String) -> String {
    if Lang.isEnglish { return "\(n) \(n == 1 ? enOne : enMany)" }
    let mod100 = n % 100
    let mod10 = n % 10
    if mod100 >= 11 && mod100 <= 14 { return "\(n) \(ruMany)" }
    if mod10 == 1 { return "\(n) \(ruOne)" }
    if mod10 >= 2 && mod10 <= 4 { return "\(n) \(ruFew)" }
    return "\(n) \(ruMany)"
}
