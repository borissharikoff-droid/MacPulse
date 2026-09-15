import AppKit

// =====================================================================
// The updater's own check, run against the SHIPPING Updater.
//
// WHY IT EXISTS: an updater is the one component whose real code path
// cannot be exercised on the machine that wrote it. You need a published
// release, a second machine, and an older installed copy before a single
// line of the interesting half runs. Everything up to the moment bytes
// arrive, though, is ordinary logic — and all of it is exactly the kind
// of logic that fails quietly and stays failed for six releases.
//
// So this pulls every decision the updater makes out of the network path
// and runs it here, in the shipping binary, against the shipping
// functions — no re-implementation, no test double:
//
//   --update-probe                 version table + host allow-list table
//   --update-probe validate <zip>  the REAL validator on a real zip
//   --update-probe check           one real GitHub check, no install
//
// The first form exits non-zero if any row disagrees, so it is usable
// from a script. See build.sh's contract guards for the other half of
// this — what the updater may LINK and may NAME is checked there.
// =====================================================================

enum UpdateProbe {

    /// Left-aligned column padding. `String(format: "%-12@", x as NSString)`
    /// looks like it does this and does not — the width is ignored for %@ —
    /// which is how a table like the one below ends up as ragged prose.
    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    static func run(arguments: [String]) -> Never {
        let idx = arguments.firstIndex(of: "--update-probe") ?? 0
        let mode = idx + 1 < arguments.count ? arguments[idx + 1] : ""

        switch mode {
        case "validate":
            guard idx + 2 < arguments.count else {
                print("usage: --update-probe validate <path-to-zip>")
                exit(2)
            }
            validate(path: arguments[idx + 2])
        case "check":
            check()
        default:
            tables()
        }
    }

    // MARK: - Tables

    private static func tables() -> Never {
        var failures = 0

        print("== version comparison — Updater.isNewer(remote, than: local) ==")
        print("")
        print("  " + pad("REMOTE", 10) + pad("LOCAL", 10) + pad("EXPECT", 8)
              + pad("GOT", 8) + pad("", 6) + "WHY THE ROW IS HERE")

        // The first row is the one that matters most: it is the exact
        // case that string ordering gets wrong, and it is the case a
        // project reaches on its tenth patch release, by which point
        // nobody is looking at the updater any more.
        let cases: [(String, String, Bool, String)] = [
            ("1.0.10", "1.0.9",  true,  "THE string-ordering trap: \"1.0.10\" < \"1.0.9\" as text"),
            ("1.0.9",  "1.0.10", false, "and it must not go the other way either"),
            ("1.10.0", "1.9.0",  true,  "same trap one component left"),
            ("2.0.0",  "1.99.99", true, "major wins over everything"),
            ("1.0.0",  "1.0.0",  false, "equal is not newer"),
            ("1.0.0",  "1.0.1",  false, "older is not newer"),
            ("1.1",    "1.1.0",  false, "missing trailing components read as 0"),
            ("1.1.1",  "1.1",    true,  "...and a real trailing component still counts"),
            ("1.0.0",  "0.9.9",  true,  "ordinary case"),
            ("10.0.0", "9.0.0",  true,  "two-digit major"),
            ("1.0.0",  "",       true,  "empty local parses as 0"),
            ("",       "1.0.0",  false, "empty remote must never win"),
            ("1.x.5",  "1.0.5",  false, "junk component is 0 IN PLACE — must not shift 5 left"),
            ("1..3",   "1.0.3",  false, "empty component likewise holds its position"),
            ("v1.0.1", "1.0.0",  false, "a tag still carrying its v parses as 0 — checkForUpdate strips it first"),
        ]
        for (remote, local, expect, note) in cases {
            let got = Updater.isNewer(remote, than: local)
            let ok = got == expect
            if !ok { failures += 1 }
            print("  " + pad(remote.isEmpty ? "(empty)" : remote, 10)
                  + pad(local.isEmpty ? "(empty)" : local, 10)
                  + pad(String(describing: expect), 8)
                  + pad(String(describing: got), 8)
                  + pad(ok ? "ok" : "FAIL", 6) + note)
        }

        print("")
        print("  components: \"1.0.10\" -> \(Updater.versionComponents("1.0.10"))"
            + "   \"1.0.9\" -> \(Updater.versionComponents("1.0.9"))"
            + "   \"1.x.5\" -> \(Updater.versionComponents("1.x.5"))")

        print("")
        print("== host allow-list — Updater.isAllowedGitHubURL ==")
        print("")
        let urls: [(String, Bool, String)] = [
            ("https://api.github.com/repos/borissharikoff-droid/MacPulse/releases/latest", true, "the only URL this app spells"),
            ("https://github.com/borissharikoff-droid/MacPulse/releases/download/v1.0.1/MacPulse.zip", true, "browser_download_url"),
            ("https://objects.githubusercontent.com/github-production-release-asset/1/2", true, "where that redirects"),
            ("http://api.github.com/x", false, "plaintext http is refused even on an allowed host"),
            ("https://api.github.com.attacker.invalid/x", false, "suffix attack"),
            ("https://attacker.invalid/api.github.com", false, "host in the path is not a host"),
            ("https://raw.githubusercontent.com/x", false, "a GITHUB host that is not on the list"),
            ("https://gist.github.com/x", false, "likewise"),
            ("file:///Applications/MacPulse.app", false, "non-https scheme"),
        ]
        for (s, expect, note) in urls {
            let url = URL(string: s)
            let got = url.map(Updater.isAllowedGitHubURL) ?? false
            let ok = got == expect
            if !ok { failures += 1 }
            print("  " + pad(ok ? "ok" : "FAIL", 6) + pad(String(describing: got), 7)
                  + pad(s, 76) + note)
        }

        print("")
        print("== identity ==")
        print("  owner/repo        \(Updater.owner)/\(Updater.repo)")
        print("  asset in release  \(Updater.assetName)")
        print("  bundle in zip     \(Updater.bundleName)   <- lesson 1")
        print("  running version   \(Updater.currentVersion())")
        print("  bundle id         \(Updater.currentBundleIdentifier())")
        print("  allowed hosts     \(Updater.allowedHosts.sorted().joined(separator: ", "))")

        print("")
        if failures == 0 {
            print("ALL ROWS OK")
            exit(0)
        }
        print("\(failures) ROW(S) FAILED")
        exit(1)
    }

    // MARK: - validate

    /// Runs the REAL `Updater.validate` on a zip built by hand, which is
    /// how every rejection branch gets exercised without a release.
    private static func validate(path: String) -> Never {
        let scratch: URL
        do {
            scratch = try Updater.scratchDirectory()
        } catch {
            print("could not make a staging directory: \(error)")
            exit(2)
        }
        print("zip      \(path)")
        print("staging  \(scratch.path)")
        print("running  v\(Updater.currentVersion())  (\(Updater.currentBundleIdentifier()))")
        print("")
        switch Updater.validate(zipAt: URL(fileURLWithPath: path), in: scratch) {
        case .success(let app):
            print("ACCEPTED  \(app.path)")
            print("          this bundle would have replaced the running app.")
            exit(0)
        case .failure(let why):
            print("REFUSED   \(why)")
            print("          the installed app is untouched.")
            exit(1)
        }
    }

    // MARK: - check

    /// One real round trip, printed. Installs nothing. This is also the
    /// offline demonstration: with no network it prints `unreachable`
    /// and exits 0, because "could not check" is not an error state for
    /// a user who never asked.
    private static func check() -> Never {
        let done = DispatchSemaphore(value: 0)
        var line = "no completion"
        let t0 = Date()
        Updater.checkForUpdate { outcome in
            switch outcome {
            case .upToDate(let v):
                line = "up to date (v\(v)) — nothing published that is newer"
            case .available(let r):
                line = "update available: v\(r.version)\n  asset: \(r.downloadURL.absoluteString)"
            case .unreachable(let why):
                line = "unreachable (SILENT in the UI): \(why)"
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        print(String(format: "%.2f s  %@", Date().timeIntervalSince(t0), line as NSString))
        exit(0)
    }
}
