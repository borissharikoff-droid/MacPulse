import Combine
import Foundation

// =====================================================================
// «СНАРУЖИ» — the address the world currently sees, and roughly where it
// thinks that address is.
//
// ---------------------------------------------------------------------
// WHY THIS FILE HAS TO EXIST AT ALL
//
// A machine cannot know its own public IP. Every address it can see
// locally is an address on THIS side of the tunnel: on this laptop utun6
// carries 198.18.0.1, an RFC 2544 benchmarking address that is not a
// peer and not an exit node. getifaddrs, the routing table and every
// other purely local source can only ever answer the wrong question.
// There is exactly one way to learn the outside address, and it is to
// ask something that is on the outside.
//
// So this file asks. Once, when the user opens the tunnel section, and
// essentially never otherwise.
//
// ---------------------------------------------------------------------
// THE ONE HOST, AND IT IS A HARDCODED LITERAL
//
//     https://www.cloudflare.com/cdn-cgi/trace
//
// It answers in plain key=value lines. `ip=` is the address the request
// arrived from, `loc=` the ISO 3166-1 alpha-2 country, `colo=` the
// Cloudflare datacentre that served it — a fair proxy for "where you
// appear to be", and the honest granularity: it is the edge that
// answered, not a street address. No API key, no account, no JSON, and
// Cloudflare is not in the business of selling geolocation.
//
// THE HOST IS NEVER INTERPOLATED, NEVER CONFIGURABLE, NEVER READ FROM
// DISK OR FROM UserDefaults. It is spelled out above, spelled out once
// more in `endpoint` below, and build.sh fails the build if any http
// literal in this file is anything other than that exact string —
// comments included. Making it a setting would turn one auditable
// destination into "wherever whoever wrote the plist wants", which is
// the entire property this arrangement buys.
//
// ---------------------------------------------------------------------
// WHAT THIS COSTS THE USER, SAID OUT LOUD
//
// THIS REQUEST TELLS CLOUDFLARE THAT SOMEONE AT THIS ADDRESS ASKED. That
// is unavoidable — it is the same fact the answer consists of — and it is
// the price of the feature. The user was told and accepted it. What is
// avoidable is everything else, and all of it is avoided:
//
//   * no identifying User-Agent. URLSession's default would announce the
//     app's name and version; it is overwritten with an empty string, so
//     the request says nothing about what asked. Verifiable rather than
//     asserted: the endpoint echoes back what it received as `uag=`, and
//     `--tunnel-probe` prints that echo.
//   * no Accept-Language, which would leak this machine's locale.
//   * no cookies, no credential store, no URL cache, no redirects worth
//     following — an ephemeral session that is invalidated the moment its
//     one request finishes, so it owns no thread and no connection
//     between asks.
//   * nothing about the user, the tunnel, the tool, or this app is in the
//     request. It is a bare GET of a fixed path.
//   * THE ANSWER IS NEVER LOGGED. It is not written to a file, a defaults
//     key, os_log or NSLog, and no code path on the UI side prints it. It
//     lives in one @Published value in memory and dies with the process.
//     The single place it is ever printed is `--tunnel-probe`, which
//     prints it because a human typed that flag in a terminal asking to
//     see it.
//
// ---------------------------------------------------------------------
// LAZY AND RARE — this must not show up in the idle budget
//
// The whole idle-cost argument for this app is 1.0% of one core with the
// panel CLOSED, and it currently measures ~0.3%. A network call has no
// business anywhere near that number, so:
//
//   * NOTHING happens at launch. This object does no work until
//     `sectionAppeared()` is called, and the only caller is the tunnel
//     section's `.onAppear` — which SwiftUI runs only when the panel is
//     open AND the tunnel tab is the selected one (IslandRouter builds
//     exactly one body, and only while `isOpen`).
//   * NOTHING is on the 1 Hz tick. MetricsEngine does not know this file
//     exists, and neither does TunnelWatcher — the routing sample stays a
//     pure local kernel query at 10 s / 4 s, exactly as it was.
//   * While the section stays open the answer is refreshed at most every
//     `refreshInterval` (four minutes), with 30 s of leeway so the wakeup
//     coalesces with somebody else's.
//   * `sectionDisappeared()` cancels the timer. Closing the panel or
//     switching tabs stops it dead; between sections this object owns no
//     timer, no thread and no connection.
//
// With the panel shut, the cost of this file is exactly zero — not
// "small", zero, because no code in it runs.
//
// ---------------------------------------------------------------------
// FAILURE IS A DASH
//
// Offline, captive portal, DNS refusing, tunnel mid-reconnect, four-second
// timeout blown: every one of them produces nil, and the section renders
// nil as "—". There is no error text on the panel and no retry storm —
// the next attempt is the next refresh interval, or the next time the
// user opens the tab. A stale reading is not kept after a failed refresh
// either: showing a four-minute-old address as though it were current is
// the same class of lie as rendering the interface address as an exit IP.
// =====================================================================

/// One answer. Every field Optional, nil meaning "not measured" — never a
/// fabricated placeholder, per the house rule.
struct GeoReading: Equatable, Sendable {
    /// The address the world currently sees. If the tunnel changes it,
    /// that IS the feature.
    let ip: String?
    /// ISO 3166-1 alpha-2, from `loc=`.
    let country: String?
    /// Cloudflare's datacentre code, from `colo=`.
    let colo: String?
    /// DIAGNOSTICS ONLY — the panel never renders this.
    ///
    /// It is the `uag=` line, i.e. the User-Agent the endpoint says it
    /// received from us. It exists so that "we send no identifying
    /// User-Agent" is a thing `--tunnel-probe` can DEMONSTRATE with the
    /// server's own words instead of a claim in a comment.
    let agentEcho: String?
}

/// The asker. A singleton because there is exactly one machine and
/// exactly one public address; two instances would mean two requests for
/// one fact.
///
/// It publishes its own `reading` rather than pushing into `IslandModel`.
/// That is deliberate and allowed: the rule in IslandSection.swift is that
/// anything `hasState` or `footerSummary` reads must be @Published on
/// IslandModel — and neither of them reads this. The rail chip and the
/// footer clause are decided entirely by the routing sample, exactly as
/// before; only the section BODY observes this object, and a body that
/// observes a second ObservableObject rebuilds correctly. The payoff is
/// that IslandModel, a shared file, needs no change at all.
final class GeoLookup: ObservableObject {

    static let shared = GeoLookup()

    /// nil until an answer lands, and nil again after a failed refresh.
    /// The section renders nil as "—" and says nothing else.
    @Published private(set) var reading: GeoReading?

    /// At most one ask every four minutes, and only while the section is
    /// on screen.
    private let refreshInterval: TimeInterval = 240

    /// A SHORT HARD TIMEOUT. This is a decoration on a panel the user is
    /// looking at right now; if the answer is not back in four seconds it
    /// is not worth having, and a dash is the correct thing to show.
    private static let timeoutSeconds: TimeInterval = 4

    /// The body is ~300 bytes of key=value. Anything past this is not the
    /// endpoint answering and is not parsed.
    private static let maxBodyBytes = 4096

    // Main-thread confined, all of them.
    private var awake = false
    private var inFlight = false
    private var lastAttempt: Date?
    private var timer: DispatchSourceTimer?

    private init() {}

    // MARK: - Lifecycle, driven by the section's onAppear/onDisappear

    /// The tunnel section is on screen. Ask now if the answer is stale,
    /// then keep it fresh while the user is looking.
    func sectionAppeared() {
        precondition(Thread.isMainThread)
        guard !awake else { return }
        awake = true
        fetchIfStale()

        // Scheduled from `.now() + refreshInterval`, NOT from `.now()`:
        // the immediate ask was just made above, and a timer that fires on
        // arming would double it.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + refreshInterval,
                   repeating: refreshInterval,
                   leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.fetchIfStale() }
        t.resume()
        timer = t
    }

    /// The panel closed, or the user switched to another tab. Stop.
    func sectionDisappeared() {
        precondition(Thread.isMainThread)
        awake = false
        timer?.cancel()
        timer = nil
    }

    /// The carrier changed under us — a tunnel came up, went down, or a
    /// different tool took the traffic. The public address is exactly the
    /// thing that just changed, so the cached answer is now wrong: drop it
    /// and ask again if anyone is looking.
    ///
    /// Cheap to call: it is driven by `onChange` of the carrier interface
    /// name, which changes when a tunnel flips and at no other time.
    func carrierChanged() {
        precondition(Thread.isMainThread)
        reading = nil
        lastAttempt = nil
        guard awake else { return }
        fetchIfStale()
    }

    // MARK: - The ask

    private func fetchIfStale() {
        precondition(Thread.isMainThread)
        guard !inFlight else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < refreshInterval { return }
        lastAttempt = Date()
        inFlight = true
        GeoLookup.fetchOnce { [weak self] answer in
            // `fetchOnce` completes on URLSession's own queue; everything
            // in this class is main-confined, so hop before touching it.
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                // A failed refresh clears the reading rather than leaving
                // the old address on screen looking current.
                guard self.reading != answer else { return }
                self.reading = answer
            }
        }
    }

    /// THE ONLY NETWORK CALL IN THIS FILE, and — with Sources/Updater.swift
    /// — one of only two in the whole app.
    ///
    /// The completion arrives on a BACKGROUND thread, not on main. That is
    /// on purpose and is what lets `--tunnel-probe` wait on it from the
    /// main thread with a semaphore without deadlocking; the UI path hops
    /// to main itself, above.
    ///
    /// nil means "could not measure", for every reason there is. The
    /// caller does not get to find out which, because nothing on screen
    /// would say anything different about any of them.
    static func fetchOnce(completion: @escaping (GeoReading?) -> Void) {
        // Hardcoded, spelled out, not assembled. The runtime check below
        // is belt-and-braces over build.sh's source-level guard: if this
        // literal is ever edited into something else, the request is not
        // made at all.
        guard let url = URL(string: "https://www.cloudflare.com/cdn-cgi/trace"),
              isTheOneEndpoint(url)
        else {
            completion(nil)
            return
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutSeconds
        cfg.timeoutIntervalForResource = timeoutSeconds
        // false, so that offline fails in seconds and is forgotten rather
        // than parking a task that waits for an interface to come up.
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        // SEND NOTHING THAT NAMES THIS MACHINE. URLSession's defaults would
        // put the app's name and version in User-Agent and this machine's
        // locale in Accept-Language; both are overwritten with empty
        // strings. What is left is a bare GET.
        request.setValue("", forHTTPHeaderField: "User-Agent")
        request.setValue("", forHTTPHeaderField: "Accept-Language")

        session.dataTask(with: request) { data, response, error in
            // The session existed for this one request. Between asks this
            // file owns no worker thread and no open connection.
            session.finishTasksAndInvalidate()

            guard error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data, !data.isEmpty, data.count <= maxBodyBytes,
                  let text = String(data: data, encoding: .utf8)
            else {
                completion(nil)
                return
            }
            completion(parse(text))
        }.resume()
    }

    /// Fails CLOSED. Anything that is not exactly the one endpoint —
    /// another host, plain http, a port, userinfo smuggling, a different
    /// path — is not it.
    static func isTheOneEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "www.cloudflare.com"
            && url.port == nil
            && url.user == nil
            && url.password == nil
            && url.path == "/cdn-cgi/trace"
    }

    // MARK: - Parsing

    /// `key=value`, one per line. Unknown keys are ignored, and every
    /// value that is kept is validated into a shape the panel can render —
    /// a response that is not the endpoint's cannot put arbitrary text on
    /// the island.
    private static func parse(_ text: String) -> GeoReading? {
        var ip: String?
        var country: String?
        var colo: String?
        var agentEcho: String?

        for line in text.split(separator: "\n").prefix(40) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq]
            let value = line[line.index(after: eq)...]
            switch key {
            case "ip":   ip = sanitizedAddress(value)
            case "loc":  country = sanitizedCode(value, length: 2...2)
            case "colo": colo = sanitizedCode(value, length: 3...4)
            // Not rendered anywhere. See `GeoReading.agentEcho`.
            case "uag":  agentEcho = String(value.prefix(64))
            default:     break
            }
        }

        // An answer with neither an address nor a country is not an
        // answer. nil, and the section shows a dash.
        guard ip != nil || country != nil else { return nil }
        return GeoReading(ip: ip, country: country, colo: colo, agentEcho: agentEcho)
    }

    /// v4 dotted-quad or v6 hex-and-colons, and nothing else. Not a
    /// correctness parse — a shape check, so that whatever this renders is
    /// at worst a wrong address and never a sentence somebody chose.
    private static func sanitizedAddress(_ value: Substring) -> String? {
        let allowed = Set("0123456789abcdefABCDEF.:")
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 45,
              trimmed.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return trimmed
    }

    /// Two letters for a country, three or four for a datacentre. Upper
    /// case only.
    private static func sanitizedCode(_ value: Substring, length: ClosedRange<Int>) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard length.contains(trimmed.count),
              trimmed.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return trimmed
    }
}
