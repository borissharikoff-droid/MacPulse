import AppKit

// =====================================================================
// THE ONLY FILE IN MacPulse THAT MAY SPEAK HTTPS, AND ONLY TO GITHUB.
//
// Read this header before touching anything below it, the same way
// PultLink.swift's header has to be read before touching that file.
// This is the SECOND deliberate hole in the app's networking property,
// and like the first one it is only defensible because of how narrow it
// is and because build.sh mechanically holds it to that width.
//
// ---------------------------------------------------------------------
// WHAT WAS GIVEN UP
//
// Before this file existed, `otool -L` on MacPulse showed no CFNetwork,
// no Network.framework and no Security.framework, and `nm -u` imported
// only socket/connect/getpeername/poll — not even bind or listen. The
// only host-shaped string in the entire binary was 127.0.0.1. That
// property is now gone, and pretending otherwise would be worse than
// losing it. CFNetwork is in the link map because this file calls
// URLSession; api.github.com, github.com and objects.githubusercontent.com
// are now strings in the binary; the app can and will open a TLS
// connection to a machine that is not this one.
//
// WHAT WAS KEPT, and what build.sh now enforces instead:
//
//   * URLSession is still banned in all ~50 other files. The banned-API
//     sweep in build.sh excludes exactly this one path.
//   * Every http(s) literal IN this file must name api.github.com,
//     github.com, or objects.githubusercontent.com — checked by grep at
//     build time, comments included. The owner and repo below are
//     interpolated into the PATH of that URL. NEVER into the host: a
//     host assembled at runtime is a host an attacker who can write one
//     preference can choose, and the build guard fails closed on any
//     `\(` appearing between "://" and the first "/".
//   * The one URL this file does NOT spell out is the release asset's
//     download URL, which arrives inside GitHub's JSON. So it is checked
//     at RUNTIME against the allow-list, before any byte of it is
//     fetched — see `isAllowedGitHubURL`.
//
//     WHAT THAT CHECK DOES NOT COVER, stated plainly because the comment
//     here used to claim otherwise: REDIRECTS ARE NOT CHECKED. There is
//     no `willPerformHTTPRedirection` delegate, so URLSession follows
//     GitHub's redirect chain wherever it goes. The guarantee is about
//     the FIRST hop only — the URL we are handed must be on the list —
//     and after that we are trusting GitHub with a TLS connection we
//     opened to GitHub.
//
//     Measured the day v1.0.0 shipped: the asset URL is on github.com
//     and redirects to release-assets.githubusercontent.com — NOT to
//     objects.githubusercontent.com, which is where it used to go and
//     which this comment used to assert. That is exactly why no delegate
//     was added to enforce the list on every hop: such a rule would have
//     been written against the old host and would now silently break
//     every auto-update, and an updater that stops working is a worse
//     outcome than an updater whose redirect chain is GitHub's business.
//     An accurate comment is the honest version of that trade.
//   * No raw socket is opened here. `nm -u` on the built binary still
//     shows exactly the socket/connect/getpeername/poll it showed before
//     — those are PultLink's and TunnelSampler's. CFNetwork does its own
//     socket work inside CFNetwork, so the stray-socket sweep in
//     build.sh stayed exactly as strict as it was.
//   * No sudo. If the installed bundle sits somewhere this user cannot
//     write, the update REFUSES rather than prompting for a password.
//   * Deletion stays inside ~/Library/Caches: the download, the unzip
//     and the staging all happen in a directory this app creates under
//     its own bundle-id folder there. The one deletion outside that is
//     the installed MacPulse.app itself, which is the entire point of an
//     updater and cannot be avoided.
//
// ---------------------------------------------------------------------
// TWO LESSONS INHERITED FROM CmdTabSwitcher, BOTH PAID FOR
//
//   1. THE APP INSIDE THE ZIP MUST ALREADY BE NAMED "MacPulse.app".
//      `ditto --keepParent` preserves whatever the staged folder is
//      literally called. The sibling project shipped six consecutive
//      releases (v1.0.2 .. v1.0.7) whose auto-update silently did
//      nothing, because the zip carried a "-dist"-suffixed build
//      artifact name and the updater, looking for the app by its final
//      name after unzip, found nothing every single time and reported
//      failure into a log nobody read. `validate` below turns that
//      into an explicit, named failure, and release.sh stages under the
//      correct name so it cannot happen in the first place.
//
//   2. THE PUBLIC ARTIFACT MUST BE AD-HOC SIGNED, NOT DEV-CERT SIGNED.
//      The local build is signed with a self-signed "CmdTabSwitcher
//      Local Dev" certificate so Gatekeeper treats rebuilds as the same
//      app. A stranger's Mac has never seen that certificate, so it
//      chains to nothing, and current macOS can call such a bundle
//      outright "damaged" — a harder block than the ordinary
//      "unidentified developer" prompt, which is at least a path the
//      user can walk. release.sh therefore re-signs the distribution
//      copy ad-hoc. This file does not re-sign anything it downloads;
//      it only VERIFIES that whatever arrived is internally intact.
//
// ---------------------------------------------------------------------
// WHAT A SIGNATURE CHECK HERE DOES AND DOES NOT PROVE
//
// `codesign --verify` on an ad-hoc bundle proves INTEGRITY — that the
// bundle has not been altered since it was signed, i.e. the download is
// not truncated or corrupt. It proves nothing about PROVENANCE, because
// an ad-hoc signature has no identity behind it. Provenance here comes
// from exactly one thing: TLS to a host on the allow-list above. Say so
// plainly rather than letting the word "verified" do work it cannot do.
// =====================================================================

enum Updater {

    // MARK: - Identity

    static let owner = "borissharikoff-droid"
    static let repo = "MacPulse"
    /// The name of the asset attached to the GitHub Release. release.sh
    /// produces exactly this.
    static let assetName = "MacPulse.zip"
    /// Lesson 1. The bundle name expected INSIDE that zip.
    static let bundleName = "MacPulse.app"

    /// The complete set of hosts this app may ever contact.
    ///
    ///   api.github.com                — the Releases API
    ///   github.com                    — where browser_download_url points
    ///   objects.githubusercontent.com — a host GitHub has served assets
    ///                                   from; kept because the API may
    ///                                   hand us such a URL directly.
    ///
    /// This is the set the URL FROM THE JSON is checked against. It is not
    /// a list of every host the download touches: redirects are followed
    /// unchecked, and today's chain leaves it for
    /// release-assets.githubusercontent.com. See the note at the top.
    ///
    /// Deliberately bare hostnames and not URLs, so the build-time
    /// http(s)-literal sweep has nothing to chew on here and the list
    /// can be read as what it is: an allow-list, not an endpoint.
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
    ]

    /// Runtime half of the host guard. The build-time grep covers the
    /// URLs this file SPELLS; this covers the one it is HANDED.
    static func isAllowedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return allowedHosts.contains(host)
    }

    // MARK: - Versions

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func currentBundleIdentifier() -> String {
        Bundle.main.bundleIdentifier ?? ""
    }

    /// Splits a dotted version into integers POSITIONALLY.
    ///
    /// The sibling's version of this used `compactMap { Int($0) }`, which
    /// silently DROPS a component it cannot parse instead of keeping its
    /// place — so "1.x.5" collapsed to [1, 5] and compared equal to 1.5.
    /// Here a non-numeric component becomes its leading digit run, or 0,
    /// and never moves the components after it.
    ///
    /// `omittingEmptySubsequences: false` matters for the same reason:
    /// "1..3" is [1, 0, 3], not [1, 3].
    static func versionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { part in Int(part.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0 }
    }

    /// Numeric compare, component by component — NOT string ordering.
    /// String ordering puts "1.0.10" BEFORE "1.0.9", which is how an
    /// updater stops updating at the tenth patch release and nobody
    /// notices for a month. Missing trailing components read as 0, so
    /// "1.1" and "1.1.0" are the same version.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = versionComponents(remote)
        let l = versionComponents(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - Check

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
    }

    enum CheckOutcome {
        case upToDate(String)
        case available(ReleaseInfo)
        /// Offline, DNS dead, rate-limited, malformed JSON — every one of
        /// these is the same thing to the user: nothing happened. The
        /// reason string is for NSLog, never for a dialog.
        case unreachable(String)
    }

    /// An ephemeral, single-use session.
    ///
    /// * ephemeral: no cookie jar, no on-disk cache, no credential store
    ///   — nothing about this app's one network call is persisted.
    /// * waitsForConnectivity = false: on a plane this fails in seconds
    ///   and is forgotten. `true` is what produces a task that sits there
    ///   waiting for an interface to come up, which is the retry storm
    ///   this app must never have.
    /// * invalidated in the completion handler, so the session's worker
    ///   threads do not outlive the one request they existed for. That is
    ///   the idle-cost half: between checks this file owns no thread, no
    ///   connection and no timer other than the single 6-hour one.
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }

    static func checkForUpdate(completion: @escaping (CheckOutcome) -> Void) {
        // The owner and repo are interpolated into the PATH. The host is
        // a literal and must stay one — see the header.
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"),
              isAllowedGitHubURL(url)
        else {
            completion(.unreachable("could not form the releases URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacPulse/\(currentVersion())", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let session = makeSession()
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()

            if let error {
                completion(.unreachable(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404 is what GitHub returns for a repo with no published
            // release at all — which is the honest state of this repo
            // until the user decides to publish one. It is not an error
            // and it must not look like one: there is no release, so we
            // are not behind one.
            if status == 404 {
                completion(.upToDate(currentVersion()))
                return
            }
            guard status == 200, let data else {
                completion(.unreachable("HTTP \(status)"))
                return
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String,
                let assets = json["assets"] as? [[String: Any]],
                let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
                let urlString = asset["browser_download_url"] as? String,
                let downloadURL = URL(string: urlString)
            else {
                completion(.unreachable("release JSON did not contain \(assetName)"))
                return
            }
            // THE RUNTIME HOST GUARD. This URL came off the wire; the
            // build-time literal sweep never saw it.
            guard isAllowedGitHubURL(downloadURL) else {
                completion(.unreachable("asset URL host is not on the allow-list"))
                return
            }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if isNewer(version, than: currentVersion()) {
                completion(.available(ReleaseInfo(version: version, downloadURL: downloadURL)))
            } else {
                completion(.upToDate(currentVersion()))
            }
        }.resume()
    }

    // MARK: - Failures

    enum InstallFailure: Error, CustomStringConvertible {
        case downloadFailed(String)
        case scratchUnavailable(String)
        case unzipFailed(Int32)
        /// LESSON 1, as an explicit named failure rather than silence.
        case wrongBundleName([String])
        case noInfoPlist
        case identifierMismatch(found: String, expected: String)
        case noExecutable
        case notNewer(found: String, running: String)
        case signatureBroken(Int32)
        case targetNotWritable(String)
        case unexpectedInstallLocation(String)
        case applyFailed(String)

        var description: String {
            switch self {
            case .downloadFailed(let why):
                return "download failed: \(why)"
            case .scratchUnavailable(let why):
                return "could not prepare the staging directory: \(why)"
            case .unzipFailed(let code):
                return "unzip exited \(code)"
            case .wrongBundleName(let found):
                return "the zip does not contain \(bundleName) — it contains \(found) "
                     + "(this is the bug that broke six of the sibling project's releases)"
            case .noInfoPlist:
                return "the downloaded bundle has no Contents/Info.plist"
            case .identifierMismatch(let found, let expected):
                return "CFBundleIdentifier is \(found), expected \(expected)"
            case .noExecutable:
                return "the downloaded bundle has no executable at Contents/MacOS/\(repo)"
            case .notNewer(let found, let running):
                return "the downloaded bundle is v\(found), which is not newer than the running v\(running)"
            case .signatureBroken(let code):
                return "codesign --verify exited \(code): the download is corrupt or was altered"
            case .targetNotWritable(let path):
                return "\(path) is not writable by this user, and MacPulse never asks for a password"
            case .unexpectedInstallLocation(let path):
                return "the running bundle is \(path), which is not a \(bundleName) this updater may replace"
            case .applyFailed(let why):
                return "could not launch the swap script: \(why)"
            }
        }
    }

    // MARK: - Staging

    /// Everything this updater writes lives here, and it is inside
    /// ~/Library/Caches on purpose: it keeps the app's "deletes nothing
    /// outside Caches and Logs" property true for every byte except the
    /// installed bundle itself.
    ///
    /// The one consequence to know about: «Очистить кэши и логи» deletes
    /// the CONTENTS of ~/Library/Caches, so a cleanup run in the second
    /// between download and relaunch can remove a staged update. The
    /// swap script below checks the staged bundle still exists before it
    /// touches the installed one, so the worst case is that the update
    /// does not happen — never that the app is removed and not replaced.
    static func scratchDirectory() throws -> URL {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = caches
            .appendingPathComponent(currentBundleIdentifier().isEmpty ? "MacPulse" : currentBundleIdentifier(),
                                    isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Validation

    /// Unzips `zipURL` into `scratch/extract` and refuses everything that
    /// is not, beyond reasonable doubt, a newer build of THIS app.
    ///
    /// Returns the path of the validated bundle. NOTHING is installed by
    /// this function — it is safe to call on an arbitrary file, which is
    /// what `--update-probe validate` does.
    static func validate(zipAt zipURL: URL, in scratch: URL) -> Result<URL, InstallFailure> {
        let fm = FileManager.default
        let extractDir = scratch.appendingPathComponent("extract", isDirectory: true)
        try? fm.removeItem(at: extractDir)
        do {
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.scratchUnavailable(error.localizedDescription))
        }

        let code = runTool("/usr/bin/unzip", ["-q", zipURL.path, "-d", extractDir.path])
        guard code == 0 else { return .failure(.unzipFailed(code)) }

        // ---- CHECK 1: the bundle is named MacPulse.app. (Lesson 1.)
        let appURL = extractDir.appendingPathComponent(bundleName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            // Report what IS in there, because "not found" on its own is
            // precisely the uninformative failure that let the sibling
            // ship the bug six times.
            let found = ((try? fm.contentsOfDirectory(atPath: extractDir.path)) ?? [])
                .filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
            return .failure(.wrongBundleName(found))
        }

        // ---- CHECK 2: it has an Info.plist we can read.
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard
            let plistData = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization
                .propertyList(from: plistData, format: nil) as? [String: Any]
        else {
            return .failure(.noInfoPlist)
        }

        // ---- CHECK 3: it is THIS app, not some other app in a zip that
        // happened to be named right.
        let expectedID = currentBundleIdentifier()
        let foundID = plist["CFBundleIdentifier"] as? String ?? ""
        guard !expectedID.isEmpty, foundID == expectedID else {
            return .failure(.identifierMismatch(found: foundID.isEmpty ? "(absent)" : foundID,
                                                expected: expectedID.isEmpty ? "(absent)" : expectedID))
        }

        // ---- CHECK 4: it can actually launch.
        let exeURL = appURL.appendingPathComponent("Contents/MacOS/\(repo)")
        guard fm.isExecutableFile(atPath: exeURL.path) else {
            return .failure(.noExecutable)
        }

        // ---- CHECK 5: the BUNDLE says it is newer. Not the git tag —
        // the tag is a label a human typed and can lie or drift. The
        // plist inside the thing we are about to install is the only
        // version that describes what will actually be running.
        let running = currentVersion()
        let incoming = plist["CFBundleShortVersionString"] as? String ?? "0.0.0"
        guard isNewer(incoming, than: running) else {
            return .failure(.notNewer(found: incoming, running: running))
        }

        // ---- CHECK 6: the signature is internally consistent, i.e. the
        // download is intact. See the header for what this does NOT
        // prove.
        let signCode = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        guard signCode == 0 else { return .failure(.signatureBroken(signCode)) }

        return .success(appURL)
    }

    // MARK: - Download

    /// `progress` fires on the main thread with 0...1 as bytes arrive,
    /// driven by the task's own Progress via KVO — real bytes, not a
    /// guess.
    static func downloadAndInstall(
        _ release: ReleaseInfo,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<String, InstallFailure>) -> Void
    ) {
        // Belt and braces: this was checked when the JSON was parsed, and
        // it is checked again here, because this is the last place before
        // a byte moves.
        guard isAllowedGitHubURL(release.downloadURL) else {
            completion(.failure(.downloadFailed("asset URL host is not on the allow-list")))
            return
        }

        let scratch: URL
        do {
            scratch = try scratchDirectory()
        } catch {
            completion(.failure(.scratchUnavailable(error.localizedDescription)))
            return
        }

        var observation: NSKeyValueObservation?
        let session = makeSession()
        let task = session.downloadTask(with: release.downloadURL) { tempURL, response, error in
            observation?.invalidate()
            observation = nil
            session.finishTasksAndInvalidate()

            guard let tempURL, error == nil else {
                completion(.failure(.downloadFailed(error?.localizedDescription ?? "no file")))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                completion(.failure(.downloadFailed("HTTP \(status)")))
                return
            }

            let zipURL = scratch.appendingPathComponent(assetName)
            do {
                try? FileManager.default.removeItem(at: zipURL)
                try FileManager.default.moveItem(at: tempURL, to: zipURL)
            } catch {
                completion(.failure(.downloadFailed(error.localizedDescription)))
                return
            }

            switch validate(zipAt: zipURL, in: scratch) {
            case .failure(let why):
                // The installed app is untouched. That is the whole point
                // of validating before swapping.
                completion(.failure(why))
            case .success(let stagedApp):
                if let why = applySwap(stagedApp: stagedApp, scratch: scratch) {
                    completion(.failure(why))
                } else {
                    completion(.success(release.version))
                }
            }
        }

        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { taskProgress, _ in
            let fraction = taskProgress.fractionCompleted
            DispatchQueue.main.async { progress(fraction) }
        }
        task.resume()
    }

    // MARK: - The swap

    /// Single-quotes a path for /bin/sh. Paths here come from
    /// FileManager and Bundle, not from the network, but a home
    /// directory with an apostrophe in it is a real thing and an
    /// unquoted path is how a script starts executing pieces of it.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A process cannot safely rewrite its own running bundle, so a small
    /// detached script does the swap a moment after we quit.
    ///
    /// It replaces THE BUNDLE WE ARE RUNNING FROM, read from
    /// `Bundle.main`, rather than a hardcoded /Applications path: if the
    /// user keeps the app somewhere else, that is the copy that should be
    /// updated, and an unrelated /Applications/MacPulse.app should not be
    /// clobbered by a copy running from elsewhere.
    ///
    /// The swap MOVES the old bundle aside first and only deletes it once
    /// the new one is in place — so a copy that fails halfway leaves the
    /// user with a working app instead of no app.
    ///
    /// Relaunch is a plain `open`, which works however the app was
    /// started, including via the SMAppService login-item registration.
    static func applySwap(stagedApp: URL, scratch: URL) -> InstallFailure? {
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard target.lastPathComponent == bundleName else {
            return .unexpectedInstallLocation(target.path)
        }
        // NO SUDO, EVER. If the parent directory is not writable by this
        // user the update simply does not happen and says so.
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .targetNotWritable(parent.path)
        }

        let script = """
        #!/bin/sh
        # Written and launched by MacPulse's Updater. Replaces the bundle
        # it was running from with the one it just validated, then
        # relaunches. Fails closed: if anything is missing it exits
        # without touching the installed app.
        sleep 1
        STAGED=\(shq(stagedApp.path))
        TARGET=\(shq(target.path))
        BACKUP="$TARGET.macpulse-old"
        SCRATCH=\(shq(scratch.path))

        [ -d "$STAGED" ] || exit 1

        rm -rf "$BACKUP"
        if [ -d "$TARGET" ]; then
          mv "$TARGET" "$BACKUP" || exit 1
        fi
        if cp -R "$STAGED" "$TARGET"; then
          rm -rf "$BACKUP"
        else
          rm -rf "$TARGET"
          [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
          exit 1
        fi
        open -a "$TARGET"
        rm -rf "$SCRATCH"
        """

        let scriptURL = scratch.appendingPathComponent("apply-update.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: scriptURL.path)
        } catch {
            return .applyFailed(error.localizedDescription)
        }

        let apply = Process()
        apply.executableURL = URL(fileURLWithPath: "/bin/sh")
        apply.arguments = [scriptURL.path]
        do {
            try apply.run()
        } catch {
            return .applyFailed(error.localizedDescription)
        }
        return nil
    }

    // MARK: - Small helper

    /// Runs a tool to completion, discarding its output, and returns its
    /// exit status. -1 if it could not be launched at all.
    @discardableResult
    private static func runTool(_ path: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
