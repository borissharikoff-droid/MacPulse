import AppKit
import Darwin
import Foundation

// =====================================================================
// «Туннель» — WHO IS CARRYING MY TRAFFIC RIGHT NOW.
//
// STATUS ONLY. This file can read the routing table and open an app. It
// cannot connect, disconnect, toggle or quit anything, and that is a
// measured decision, not an omission — see "WHY THERE IS NO TOGGLE".
//
// ---------------------------------------------------------------------
// THE ONE IDEA
//
// Ask the KERNEL which interface it would use for a real public
// destination, and believe the answer. Everything else lies:
//
//   * the default route
//         MEASURED ON THIS MACHINE: `route get default` returns en0 /
//         10.75.96.1 while 100% of traffic is tunnelled. Clash never
//         replaces the default route; it installs eight more-specific
//         splits — 1/8, 2/7, 4/6, 8/5, 16/4, 32/3, 64/2, 128.0/1 — which
//         together cover every routable IPv4 address, all via 198.18.0.1
//         on utun6. A detector that reads the default route reports "no
//         VPN" on a fully tunnelled machine.
//         THIS IS THE SINGLE BIGGEST TRAP IN THIS FEATURE. Do not
//         "simplify" the carrier query back to the default route.
//   * `scutil --nwi`      -> lists only en0; never mentions utun6.
//   * `scutil --nc list`  -> lists Outline, Streisand and two PPP modems,
//                            all Disconnected; none of the real tools.
//   * "is the daemon running"
//         AmneziaVPN-service has run as root for days on a machine where
//         Amnezia is completely idle. A running daemon proves nothing.
//   * vendor CLIs — dangling shims here, and MacPulse shells out to
//         nothing on a sample path in any case.
//
// So: one RTM_GET per public probe address on a PF_ROUTE socket, plus one
// getifaddrs() to put an address on the interface that comes back.
//
// NO PACKET IS SENT TO THE PROBE ADDRESSES, and this is the reason this
// file is allowed to exist under the contract at all. RTM_GET is a pure
// kernel forwarding-table lookup over an AF_ROUTE socket — the same thing
// route(8) does. Nothing is resolved, nothing is dialled, nothing is
// contacted. There is no peer to contact: a PF_ROUTE descriptor cannot be
// connected to an address. build.sh's link check must keep reporting NO
// CFNetwork, NO Network.framework, NO Security.framework, and this file
// links none of them.
//
// ---------------------------------------------------------------------
// THE GHOST-INSTALL TRAP
//
// Four separate artefacts on this machine claim Cloudflare WARP is
// installed: two /Library/LaunchDaemons plists, four /usr/local/bin/warp-*
// symlinks, a login item, and `launchctl print-disabled` reporting it
// "enabled". WARP is NOT installed — every one of those is a leftover. The
// Tailscale shim is worse: a 68-byte regular file, not a symlink, so even
// a dangling-symlink check misses it.
//
// The ONLY correct installation test is a LaunchServices bundle lookup,
// done once on the cold path — plus a stat of the URL it returns, because
// the LaunchServices database can itself hand back a path to a bundle that
// has since been deleted.
//
// ---------------------------------------------------------------------
// WHY THERE IS NO TOGGLE — do not add one
//
// FlClashX: `external-controller` is the empty string, so there is no HTTP
// API (9090/9097 refuse). No AppleScript dictionary. Its URL schemes
// (clash/clashmeta/flclash/flclashx) are PROFILE-IMPORT schemes, not
// connection toggles — firing a guessed URL at a live tunnel could
// silently switch the user's profile. Its only real control channel is an
// undocumented binary protocol over a Unix socket. And it is carrying
// every packet on this machine, so a failed toggle takes the user offline
// with no reliable way back to the same profile.
//
// AmneziaVPN: no URL scheme, no AppleScript dictionary, no CLI entry
// point. Connect/disconnect goes through a root helper over an
// undocumented IPC socket.
//
// Quitting either app via NSRunningApplication works mechanically and
// tears down the tunnel. That is not a feature, it is an outage — and it
// is also outside the contract, which permits terminating helpd and apps
// the user explicitly clicked, and nothing else. `TunnelActions` therefore
// exposes exactly one verb: open the app and let the user decide.
//
// ---------------------------------------------------------------------
// COST
//
// One getifaddrs() walk plus one RTM_GET per probe address plus one
// RTM_GET for the default route: ~95 us in total, measured over 200
// samples on this M2. Zero subprocesses, zero root, zero entitlements.
//
// That is cheap, but it is NOT on the 1 Hz metrics tick and must not be
// put there. `TunnelWatcher` at the bottom of this file owns the cadence:
// 10 s shut, 4 s with the panel open. Routes change when a tunnel comes up
// or goes down and essentially never otherwise, so 10 s of staleness is
// the whole cost of not having an event source — see the comment on
// `idleInterval` for why there deliberately is not one.
// =====================================================================

// MARK: - Value types

/// The tools this engine knows how to name. Everything else that carries
/// traffic is reported as an unattributed tunnel, never guessed at.
enum TunnelTool: String, CaseIterable, Sendable {
    case flClash
    case amnezia
    case warp
    case tailscale

    /// Product name, as the vendor spells it. NOT localised — this file is
    /// language-neutral exactly like `MemoryPressureLevel`, and the section
    /// does the Russian. See IslandSectionTunnel.swift.
    var displayName: String {
        switch self {
        case .flClash: return "FlClashX"
        case .amnezia: return "AmneziaVPN"
        case .warp: return "Cloudflare WARP"
        case .tailscale: return "Tailscale"
        }
    }

    /// Every bundle identifier the tool has shipped under. Tailscale has
    /// two — the standalone build and the App Store build — and they are
    /// not interchangeable, so both are checked.
    var bundleIdentifiers: [String] {
        switch self {
        case .flClash: return ["com.follow.clash"]
        case .amnezia: return ["com.yourcompany.AmneziaVPN"]
        case .warp: return ["com.cloudflare.1dot1dot1dot1.macos"]
        case .tailscale: return ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
        }
    }

    /// Whether opening this app could change the user's connectivity.
    ///
    /// nil means "opening it is inert". A non-nil string is a warning the
    /// UI MUST show and have confirmed BEFORE it opens the app.
    ///
    /// Amnezia's stored profile has `routeMode = 1` and a saved server, and
    /// the spike deliberately never launched it, so whether launching
    /// auto-connects is UNVERIFIED. Treat it as if it does.
    var launchCaution: String? {
        switch self {
        case .amnezia:
            return "Может подключиться сам при запуске (сохранён сервер, routeMode 1). Не проверено."
        case .flClash, .warp, .tailscale:
            return nil
        }
    }
}

/// The honest five-way answer, per tool.
///
/// `carryingTraffic` is the only state that makes a claim about traffic,
/// and it is only ever set from routing-table evidence.
///
/// NOTE THE ABSENCE OF "off". "Not installed" and "installed but idle" are
/// different facts and the UI must never blur them into one word — an
/// uninstalled tool shown as merely off is a claim about a thing that is
/// not there.
enum TunnelToolState: String, Sendable {
    /// No application bundle. Leftover daemons, symlinks, login items and
    /// launchctl entries do NOT count as installed.
    case notInstalled
    /// Installed, and provably not carrying traffic: something else owns
    /// the route to the public internet.
    case installedIdle
    /// Owns the route to the public internet. Routing-table evidence only.
    case carryingTraffic
    /// Its interface is up, but a different interface owns the public
    /// route — a split tunnel, or a tunnel connected but unused.
    case upNotCarrying
    /// Installed, and we genuinely do not know. Either the routing query
    /// failed, or traffic leaves via a tunnel whose address matches no
    /// signature we trust — and this tool could be that tunnel.
    case cannotDetermine
}

/// How much a signature match is worth.
enum TunnelSignatureConfidence: String, Sendable {
    /// Observed on this machine, against this tool, with traffic flowing.
    case verified
    /// From vendor documentation only. NOT observed here, because the tool
    /// is not installed on this machine and could not be tested.
    case documented
}

struct TunnelToolStatus: Equatable, Sendable {
    let tool: TunnelTool
    let state: TunnelToolState
    /// nil exactly when `state == .notInstalled`.
    let bundleURL: URL?
    /// The interface we can pin on this tool, if any. nil is NOT "idle" —
    /// read `state` for that.
    let attributedInterface: String?
    /// Whether the GUI app is running.
    ///
    /// DISPLAY ONLY. This must never influence `state`, and in this file it
    /// does not: AmneziaVPN's root helper runs at boot and stays resident
    /// whether or not a tunnel is up. nil means the cold path has not
    /// looked yet.
    let isAppRunning: Bool?
    /// Why this verdict, in one clause. Worth surfacing in a tooltip — the
    /// whole point of this feature is that the obvious answer is wrong, and
    /// this is the sentence that says why.
    let reason: String
}

/// One interface that looks like a tunnel.
struct TunnelInterface: Equatable, Sendable {
    let name: String
    /// nil means the interface has no IPv4 address.
    ///
    /// This is the NORMAL case for most utuns: macOS keeps a handful of
    /// addressless utuns permanently (utun0–utun8 exist here; only utun6
    /// has an IPv4 address). An addressless utun is never evidence of a
    /// VPN.
    let ipv4: String?
    let mtu: UInt32?
    let isUp: Bool
    let isRunning: Bool
    /// Which tool this interface's address matches, and how much that match
    /// is worth. nil = no signature we trust.
    let signature: TunnelTool?
    let signatureConfidence: TunnelSignatureConfidence?
}

/// The interface that owns the route to the public internet.
struct TunnelCarrier: Equatable, Sendable {
    let interface: String
    let ifIndex: UInt32
    /// Next hop. For a Clash fake-ip tunnel this is 198.18.0.1, which is
    /// NOT a real peer and must never be rendered as an "exit IP".
    let gateway: String?
    let ipv4: String?
    let mtu: UInt32?
    let isTunnel: Bool
    /// nil when the carrier is a physical interface, or a tunnel whose
    /// address matches no signature we trust.
    let tool: TunnelTool?
}

/// One complete, immutable reading. Produced on the watcher's queue, safe
/// to hand to the main thread and hold.
///
/// Every field that could fail to be measured is Optional. nil means
/// "could not measure" and is never the same thing as a measured negative
/// — the section renders every one of them as a dash.
struct TunnelMetrics: Sendable {
    /// nil = the routing query failed. NOT "no tunnel".
    let carrier: TunnelCarrier?
    /// The 0.0.0.0/0 route's interface — the DECOY. Kept for exactly two
    /// purposes: `deservesStripSlot`, and being named on screen as the
    /// thing that is NOT carrying the traffic. Never render it as "your
    /// VPN".
    let defaultRouteInterface: String?
    /// True when different public destinations leave by different
    /// interfaces, i.e. there is genuinely no single carrier. `carrier`
    /// then holds the answer for the FIRST probe address only.
    let routeIsSplit: Bool
    /// One entry per known tool, in `TunnelTool.allCases` order.
    let tools: [TunnelToolStatus]
    /// Every tunnel-shaped interface that is UP right now, addressless ones
    /// included. See `addressedTunnels` for the ones that mean something.
    let tunnels: [TunnelInterface]
    /// Any interface holding a global (non-link-local) IPv6 address.
    ///
    /// This engine resolves IPv4 routes only. When this is true a v6-only
    /// tunnel could be carrying traffic it cannot see, and the section says
    /// so rather than pretending the IPv4 answer is the whole answer.
    let hasGlobalIPv6: Bool
    /// Wall-clock cost of producing this snapshot, in milliseconds.
    /// Diagnostics for `--tunnel-probe`; deliberately NOT part of `==`.
    let sampleCostMs: Double

    /// THE STRIP-SLOT RULE, from the architecture spike:
    ///
    ///   "this only earns strip space when a tunnel is up AND is not the
    ///    default route — a permanently-lit VPN badge is noise"
    ///
    /// So: true only when traffic leaves through a TUNNEL and that tunnel
    /// is NOT the 0.0.0.0/0 route. An always-on full-tunnel VPN that owns
    /// the default route is the user's permanent normal state and earns
    /// nothing. The interesting case — the one on this machine — is a
    /// tunnel that carries everything through more-specific splits while
    /// the default route still points at en0.
    ///
    /// nil = could not measure. Render nil as "—", and NEVER light the
    /// badge on a nil.
    let deservesStripSlot: Bool?

    /// The tool carrying traffic, if we can name it.
    var carryingTool: TunnelTool? {
        tools.first(where: { $0.state == .carryingTraffic })?.tool
    }

    /// Tunnels with an IPv4 address — the only ones worth a line.
    var addressedTunnels: [TunnelInterface] {
        tunnels.filter { $0.ipv4 != nil }
    }

    func status(of tool: TunnelTool) -> TunnelToolStatus? {
        tools.first(where: { $0.tool == tool })
    }
}

extension TunnelMetrics: Equatable {
    /// HAND-WRITTEN, AND `sampleCostMs` IS LEFT OUT ON PURPOSE.
    ///
    /// `IslandModel` republishes only when the displayed value changes —
    /// that is the rule the whole idle budget rests on. `sampleCostMs`
    /// differs on literally every sample, so a synthesised `==` would make
    /// every 10 s tick a publish, a router refresh and a SwiftUI rebuild
    /// for a number nothing draws. Everything the section can render is
    /// compared; the stopwatch is not.
    static func == (a: TunnelMetrics, b: TunnelMetrics) -> Bool {
        a.carrier == b.carrier
            && a.defaultRouteInterface == b.defaultRouteInterface
            && a.routeIsSplit == b.routeIsSplit
            && a.tools == b.tools
            && a.tunnels == b.tunnels
            && a.hasGlobalIPv6 == b.hasGlobalIPv6
            && a.deservesStripSlot == b.deservesStripSlot
    }
}

/// What LaunchServices knows about one tool.
struct TunnelInstall: Equatable, Sendable {
    /// nil = not installed. The URL has been stat'd, so it is not a
    /// LaunchServices ghost.
    let bundleURL: URL?
    /// GUI app running. DISPLAY ONLY — never a traffic signal.
    let isAppRunning: Bool
}

// MARK: - Address signatures

/// Which address range belongs to which tool.
///
/// Deliberately does NOT contain an entry for AmneziaVPN. Amnezia can run
/// AmneziaWG, WireGuard, OpenVPN, Shadowsocks or Xray depending on the
/// server profile, so its interface address is not predictable from any
/// fixed list. Guessing one would produce exactly the permanently-wrong
/// badge this whole design exists to avoid. An Amnezia tunnel therefore
/// surfaces as an unattributed tunnel, and Amnezia's own state becomes
/// `cannotDetermine` — which is the true answer, and the section prints it
/// in those words.
private enum TunnelSignature {

    /// Not named `Range` — shadowing `Swift.Range` inside a file other
    /// people will read is a needless trap.
    private struct CIDR {
        let base: UInt32
        let prefix: UInt32
        let tool: TunnelTool
        let confidence: TunnelSignatureConfidence
    }

    private static let ranges: [CIDR] = [
        // 198.18.0.0/15 is the RFC 2544 benchmarking range, which is why
        // Clash picked it for fake-ip: nothing real routes there. VERIFIED
        // on this machine — utun6 holds 198.18.0.1 at mtu 9000 while
        // FlClashX's stored config has fake-ip-range 198.18.0.1/16 and
        // tun.enable true.
        CIDR(base: ipv4("198.18.0.0")!, prefix: 15, tool: .flClash, confidence: .verified),
        // 100.64.0.0/10, the CGNAT range Tailscale assigns from. DOCUMENTED
        // ONLY: Tailscale is not installed here, so this branch has never
        // executed against a real Tailscale interface.
        CIDR(base: ipv4("100.64.0.0")!, prefix: 10, tool: .tailscale, confidence: .documented),
        // WARP hands out a /32 out of 172.16.0.0/24. DOCUMENTED ONLY, and
        // the weakest signature here: 172.16.0.x is also an ordinary
        // private LAN range. It is only ever consulted for an interface
        // that is already tunnel-shaped, and only when WARP is actually
        // installed — see THE INSTALL GATE in `TunnelSampler.sample`.
        CIDR(base: ipv4("172.16.0.0")!, prefix: 24, tool: .warp, confidence: .documented),
    ]

    static func match(_ address: String) -> (tool: TunnelTool, confidence: TunnelSignatureConfidence)? {
        guard let value = ipv4(address) else { return nil }
        for range in ranges {
            let mask: UInt32 = range.prefix == 0 ? 0 : ~UInt32(0) << (32 - range.prefix)
            if value & mask == range.base & mask {
                return (range.tool, range.confidence)
            }
        }
        return nil
    }

    /// Dotted quad -> host-order UInt32. nil on anything that is not one.
    private static func ipv4(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}

// MARK: - Interface inventory

/// One getifaddrs() walk. ~21 us measured.
private enum InterfaceInventory {

    struct Entry {
        var name: String
        var ipv4: String?
        var mtu: UInt32?
        var isUp: Bool
        var isRunning: Bool
        var hasGlobalIPv6: Bool
    }

    /// Names that mean "this is a tunnel, not a wire".
    ///
    /// Name-prefix matching, not `if_data.ifi_type`: every utun on this
    /// machine reports IFT_OTHER (1), and so do several things that are not
    /// tunnels. The prefix is the honest discriminator on macOS.
    static func isTunnelName(_ name: String) -> Bool {
        for prefix in ["utun", "ipsec", "ppp", "tun", "tap", "wg", "gpd"] where name.hasPrefix(prefix) {
            return true
        }
        return false
    }

    static func walk() -> [String: Entry]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var result: [String: Entry] = [:]
        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            var entry = result[name] ?? Entry(name: name, ipv4: nil, mtu: nil,
                                              isUp: flags & IFF_UP != 0,
                                              isRunning: flags & IFF_RUNNING != 0,
                                              hasGlobalIPv6: false)
            guard let sa = current.pointee.ifa_addr else { result[name] = entry; continue }

            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    entry.ipv4 = String(cString: buffer)
                }
            case AF_INET6:
                // Only a GLOBAL v6 address counts. Every interface on a
                // modern Mac carries fe80::/10 link-local addresses;
                // treating those as "has IPv6" would make the flag
                // meaningless.
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let isLinkLocal = withUnsafeBytes(of: &sin6.sin6_addr) { raw -> Bool in
                    guard raw.count >= 2 else { return true }
                    return raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80
                }
                let isLoopback = withUnsafeBytes(of: &sin6.sin6_addr) { raw -> Bool in
                    guard raw.count == 16 else { return false }
                    for i in 0..<15 where raw[i] != 0 { return false }
                    return raw[15] == 1
                }
                if !isLinkLocal && !isLoopback { entry.hasGlobalIPv6 = true }
            case AF_LINK:
                // The AF_LINK entry is the only one carrying if_data, and
                // that is where the MTU lives. FlClash's tun runs at 9000,
                // which is a useful corroborating signal — never a decisive
                // one.
                if let data = current.pointee.ifa_data {
                    entry.mtu = data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu
                }
            default:
                break
            }
            result[name] = entry
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Route probe

/// One RTM_GET on a PF_ROUTE socket. ~24 us measured.
///
/// THE ONE PLACE IN THIS FILE THAT OPENS A DESCRIPTOR, and it is the
/// reason build.sh's stray-socket guard names this file. A PF_ROUTE
/// descriptor is a kernel query channel, not a connection: it has no peer,
/// it cannot be connected, bound or sent through, and nothing that goes
/// into it leaves the machine. `connect`, `bind`, `sendto` and
/// `getaddrinfo` remain banned here exactly as everywhere else.
///
/// A fresh socket per query, on purpose. A long-lived PF_ROUTE socket
/// receives every routing message the kernel broadcasts to every listener,
/// so between samples its receive buffer fills with other processes'
/// traffic that we would then have to drain. A fresh one starts empty, and
/// the whole open/write/read/close round trip measures 24 us — there is
/// nothing here to optimise.
private enum RouteProbe {

    struct Answer {
        let ifIndex: UInt32
        let ifName: String
        let gateway: String?
    }

    /// Bounded so a wedged routing socket can never stall the watcher's
    /// queue. The measured call costs 24 us, so 250 ms is four orders of
    /// magnitude of headroom while capping the worst case well inside one
    /// base metrics tick.
    private static let receiveTimeoutMicroseconds: Int32 = 250_000

    private static func roundup(_ value: Int) -> Int { value > 0 ? ((value + 3) & ~3) : 4 }

    /// - Parameters:
    ///   - destination: a routable public IPv4 address. NO PACKET IS SENT
    ///     TO IT; this is a forwarding-table lookup and nothing else.
    ///   - exactDefault: ask for the 0.0.0.0/0 entry itself rather than the
    ///     best match for `destination`. Sends a zero-length netmask, which
    ///     is how route(8) spells "default", forcing an EXACT-match lookup.
    ///     Without it, a tunnel that installs the classic 0.0.0.0/1 +
    ///     128.0.0.0/1 pair would answer a best-match query for 0.0.0.0 and
    ///     we would mistake the tunnel for the default route.
    ///   - sequence: caller-owned, must differ between concurrent queries.
    ///     Kept out of this enum so there is no shared mutable state.
    static func lookup(destination: String, exactDefault: Bool = false, sequence: Int32) -> Answer? {
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: receiveTimeoutMicroseconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let headerSize = MemoryLayout<rt_msghdr>.size
        let sinSize = MemoryLayout<sockaddr_in>.size
        // A zero sa_len netmask still occupies roundup(0) == 4 bytes on the
        // wire.
        let total = headerSize + roundup(sinSize) + (exactDefault ? 4 : 0)
        var request = [UInt8](repeating: 0, count: 1024)
        guard total <= request.count else { return nil }

        var built = false
        request.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let header = base.assumingMemoryBound(to: rt_msghdr.self)
            header.pointee.rtm_msglen = UInt16(total)
            header.pointee.rtm_version = UInt8(RTM_VERSION)
            header.pointee.rtm_type = UInt8(RTM_GET)
            // RTF_HOST asks for the best match for one host; for the
            // default route we must NOT set it, or the kernel looks for a
            // host entry.
            header.pointee.rtm_flags = exactDefault
                ? Int32(RTF_UP | RTF_GATEWAY | RTF_STATIC)
                : Int32(RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC)
            // RTA_IFP is declared but not supplied: that is the BSD idiom
            // for "fill the interface in on the way back".
            header.pointee.rtm_addrs = exactDefault
                ? Int32(RTA_DST | RTA_NETMASK | RTA_IFP)
                : Int32(RTA_DST | RTA_IFP)
            header.pointee.rtm_pid = 0
            header.pointee.rtm_seq = sequence

            let sin = (base + headerSize).assumingMemoryBound(to: sockaddr_in.self)
            sin.pointee.sin_len = UInt8(sinSize)
            sin.pointee.sin_family = sa_family_t(AF_INET)
            built = destination.withCString { inet_pton(AF_INET, $0, &sin.pointee.sin_addr) } == 1
            // The netmask, when present, is already all zeros — including
            // its sa_len, which is exactly what makes it 0.0.0.0/0.
        }
        guard built else { return nil }
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, total) }) == total else { return nil }

        let myPID = getpid()
        var reply = [UInt8](repeating: 0, count: 4096)
        // Bounded: every other listener's messages land here too, and we
        // must not spin forever discarding them.
        for _ in 0..<32 {
            let n = reply.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n < 0 && errno == EINTR { continue }
            guard n >= MemoryLayout<rt_msghdr>.size else { return nil }

            var answer: Answer?
            var isOurs = false
            reply.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let header = base.assumingMemoryBound(to: rt_msghdr.self)
                // seq AND pid, or we consume another process's reply.
                guard header.pointee.rtm_seq == sequence, header.pointee.rtm_pid == myPID else { return }
                isOurs = true

                var gateway: String?
                var cursor = base + headerSize
                let end = base + n
                let addrs = header.pointee.rtm_addrs
                // The returned sockaddrs are packed in RTA_* bit order.
                for bit in 0..<8 {
                    guard addrs & (1 << bit) != 0, cursor + MemoryLayout<sockaddr>.size <= end else { continue }
                    let sa = cursor.assumingMemoryBound(to: sockaddr.self)
                    let length = Int(sa.pointee.sa_len)
                    if (1 << bit) == RTA_GATEWAY, sa.pointee.sa_family == sa_family_t(AF_INET) {
                        var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                            gateway = String(cString: buffer)
                        }
                    }
                    cursor += roundup(length == 0 ? 4 : length)
                }

                let index = UInt32(header.pointee.rtm_index)
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                let name = if_indextoname(index, &nameBuffer) != nil ? String(cString: nameBuffer) : nil
                guard let name, !name.isEmpty else { return }
                answer = Answer(ifIndex: index, ifName: name, gateway: gateway)
            }
            if isOurs { return answer }
        }
        return nil
    }
}

// MARK: - Installation index (COLD PATH — main thread)

/// LaunchServices lookups and NSRunningApplication queries, kept OFF the
/// sample path.
///
/// Both are cross-process queries into LaunchServices. MetricsEngine
/// already measured what happens when you put one on a tick:
/// `NSWorkspace.runningApplications` cost 63 ms of main-thread CPU in a
/// 20 s window, asking thirty times a minute a question whose answer had
/// not changed — see `Cadence.appIdentityFloorTicks`. So: sweep once, then
/// let NSWorkspace's launch/terminate notifications maintain the running
/// flags, with a manual `refresh()` for anything else (an install or a
/// delete while MacPulse is up).
///
/// MAIN THREAD ONLY, like `AppIconCache`. `refresh()` is EXPENSIVE; never
/// call it on a cadence.
final class TunnelInstallIndex {

    static let shared = TunnelInstallIndex()

    /// The value handed across to the watcher's queue. Immutable, Sendable.
    private(set) var snapshot: [TunnelTool: TunnelInstall] = [:]

    /// Fired on the main thread whenever the snapshot changes. ONE
    /// consumer — assigning it twice silently drops the first.
    var onChange: (([TunnelTool: TunnelInstall]) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        refresh()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            // Tokens are HELD so stop() can remove them. A dropped token is
            // a subscription that outlives stop() and keeps firing.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                // The bundle-id filter runs BEFORE refresh(), so the
                // expensive sweep costs nothing for the hundred other apps
                // that launch and quit on this machine.
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = app.bundleIdentifier,
                      TunnelTool.allCases.contains(where: { $0.bundleIdentifiers.contains(identifier) })
                else { return }
                self.refresh()
            })
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        started = false
    }

    /// Re-sweep LaunchServices. Main thread; call it sparingly.
    @discardableResult
    func refresh() -> [TunnelTool: TunnelInstall] {
        precondition(Thread.isMainThread)
        var next: [TunnelTool: TunnelInstall] = [:]
        for tool in TunnelTool.allCases {
            var url: URL?
            for identifier in tool.bundleIdentifiers {
                guard let candidate = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                else { continue }
                // Stat it. The LaunchServices database can hand back a path
                // to a bundle that has since been deleted, which would
                // resurrect exactly the ghost install this check exists to
                // kill.
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                url = candidate
                break
            }
            let running = tool.bundleIdentifiers.contains {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            }
            next[tool] = TunnelInstall(bundleURL: url, isAppRunning: running)
        }
        let changed = next != snapshot
        snapshot = next
        if changed { onChange?(next) }
        return next
    }
}

// MARK: - The sampler (HOT PATH — watcher queue)

/// Derives the verdict from routing-table evidence. Call from a serial
/// queue, exactly like the samplers in DeviceSamplers.swift.
final class TunnelSampler {

    /// Public destinations to resolve. NO PACKET IS SENT TO THEM — they
    /// are lookup keys, not destinations.
    ///
    /// Two, in opposite halves of the address space, because one is not
    /// enough to tell "everything is tunnelled" from "half of it is". A
    /// tunnel that installs 0.0.0.0/1 + 128.0.0.0/1 catches both; one that
    /// splits only part of the space catches one, and `routeIsSplit` then
    /// says so instead of this engine picking a winner.
    var probeDestinations: [String] = ["1.1.1.1", "208.67.222.222"]

    /// Monotonic per-query sequence. Confined to the watcher's queue.
    private var sequence: Int32 = 1

    init() {}

    private func nextSequence() -> Int32 {
        sequence = sequence == Int32.max ? 1 : sequence + 1
        return sequence
    }

    /// - Parameter installed: the cold-path snapshot, handed over from
    ///   main. Pass `[:]` if the index has not swept yet — every tool then
    ///   reports `notInstalled`, which is why the watcher sweeps before its
    ///   first sample.
    /// - Returns: nil only when the interface walk itself failed, i.e. we
    ///   know nothing at all. A failed ROUTE query still returns a
    ///   snapshot, with `carrier == nil`, `deservesStripSlot == nil` and
    ///   every installed tool `cannotDetermine`.
    func sample(installed: [TunnelTool: TunnelInstall]) -> TunnelMetrics? {
        let started = Mono.now()

        guard let entries = InterfaceInventory.walk() else { return nil }

        // --- routing-table evidence ---------------------------------------
        var answers: [RouteProbe.Answer] = []
        for destination in probeDestinations {
            if let answer = RouteProbe.lookup(destination: destination, sequence: nextSequence()) {
                answers.append(answer)
            }
        }
        let defaultRoute = RouteProbe.lookup(destination: "0.0.0.0",
                                             exactDefault: true,
                                             sequence: nextSequence())
        let routeIsSplit = answers.count > 1 && Set(answers.map(\.ifName)).count > 1

        // --- attribution ---------------------------------------------------
        func isInstalled(_ tool: TunnelTool) -> Bool { installed[tool]?.bundleURL != nil }

        var tunnels: [TunnelInterface] = []
        var attributed: [TunnelTool: String] = [:]
        var ghostSignatures: [TunnelTool: String] = [:]
        var hasGlobalIPv6 = false

        for entry in entries.values.sorted(by: { $0.name < $1.name }) {
            if entry.hasGlobalIPv6 { hasGlobalIPv6 = true }
            guard InterfaceInventory.isTunnelName(entry.name), entry.isUp else { continue }

            var signature: TunnelTool?
            var confidence: TunnelSignatureConfidence?
            if let ipv4 = entry.ipv4, let match = TunnelSignature.match(ipv4) {
                // THE INSTALL GATE. A signature match only names a tool that
                // is actually installed. Without this, a 172.16.0.x LAN-ish
                // utun would be reported as Cloudflare WARP on a machine
                // whose only WARP artefacts are two dead LaunchDaemon
                // plists.
                if isInstalled(match.tool) {
                    signature = match.tool
                    confidence = match.confidence
                    if attributed[match.tool] == nil { attributed[match.tool] = entry.name }
                } else {
                    ghostSignatures[match.tool] = entry.name
                }
            }
            tunnels.append(TunnelInterface(name: entry.name, ipv4: entry.ipv4, mtu: entry.mtu,
                                           isUp: entry.isUp, isRunning: entry.isRunning,
                                           signature: signature, signatureConfidence: confidence))
        }

        // --- the carrier -----------------------------------------------------
        var carrier: TunnelCarrier?
        if let primary = answers.first {
            let entry = entries[primary.ifName]
            let isTunnel = InterfaceInventory.isTunnelName(primary.ifName)
            let tool = isTunnel ? attributed.first(where: { $0.value == primary.ifName })?.key : nil
            carrier = TunnelCarrier(interface: primary.ifName, ifIndex: primary.ifIndex,
                                    gateway: primary.gateway, ipv4: entry?.ipv4, mtu: entry?.mtu,
                                    isTunnel: isTunnel, tool: tool)
        }
        let carrierIsUnnamedTunnel = (carrier?.isTunnel == true) && carrier?.tool == nil

        // --- per-tool verdicts ------------------------------------------------
        var tools: [TunnelToolStatus] = []
        for tool in TunnelTool.allCases {
            let install = installed[tool]
            guard let bundleURL = install?.bundleURL else {
                var reason = "Нет приложения в базе LaunchServices."
                if let ghost = ghostSignatures[tool] {
                    reason += " (\(ghost) попадает в его документированный диапазон, но приложения нет — не засчитано.)"
                }
                tools.append(TunnelToolStatus(tool: tool, state: .notInstalled, bundleURL: nil,
                                              attributedInterface: nil,
                                              isAppRunning: install?.isAppRunning, reason: reason))
                continue
            }

            let state: TunnelToolState
            let reason: String
            let interface = attributed[tool]

            // ORDER MATTERS, AND THIS ORDER IS LOAD-BEARING. A failed route
            // query is checked FIRST, before the attributed-interface
            // branch. Getting this backwards is how an engine says "up, not
            // carrying" — a claim about traffic — on the strength of no
            // measurement at all. An interface being up is never evidence
            // about traffic; only the routing table is.
            if let carrier {
                if let interface {
                    if interface == carrier.interface {
                        state = .carryingTraffic
                        let gateway = carrier.gateway.map { " через \($0)" } ?? ""
                        reason = "\(interface) владеет маршрутом к \(probeDestinations.first ?? "интернету")\(gateway)."
                    } else {
                        state = .upNotCarrying
                        reason = "\(interface) поднят, но маршрутом к интернету владеет \(carrier.interface)."
                    }
                } else if carrierIsUnnamedTunnel {
                    state = .cannotDetermine
                    let address = carrier.ipv4.map { " (\($0))" } ?? ""
                    reason = "Трафик уходит через \(carrier.interface)\(address) — адрес не совпадает ни с одной надёжной сигнатурой. Это может быть он."
                } else {
                    state = .installedIdle
                    reason = "Трафик уходит через \(carrier.interface); ни один интерфейс не приписан этому инструменту."
                }
            } else {
                state = .cannotDetermine
                let seen = interface.map { " \($0) поднят, но это не доказательство трафика." } ?? ""
                reason = "Запрос к таблице маршрутов ничего не вернул; утверждать что-либо о трафике нельзя.\(seen)"
            }

            tools.append(TunnelToolStatus(tool: tool, state: state, bundleURL: bundleURL,
                                          attributedInterface: interface,
                                          isAppRunning: install?.isAppRunning, reason: reason))
        }

        // --- the strip-slot rule ----------------------------------------------
        let deservesStripSlot: Bool?
        if let carrier, let defaultRoute {
            deservesStripSlot = carrier.isTunnel && carrier.interface != defaultRoute.ifName
        } else {
            deservesStripSlot = nil
        }

        return TunnelMetrics(carrier: carrier,
                             defaultRouteInterface: defaultRoute?.ifName,
                             routeIsSplit: routeIsSplit,
                             tools: tools,
                             tunnels: tunnels,
                             hasGlobalIPv6: hasGlobalIPv6,
                             sampleCostMs: Mono.seconds(since: started) * 1000,
                             deservesStripSlot: deservesStripSlot)
    }
}

// MARK: - Actions (open only)

/// The ONLY verb this feature has.
///
/// There is deliberately no connect, disconnect, toggle, quit or terminate
/// here, and nothing should be added. See the header: neither installed
/// tool can be switched without sudo or reverse-engineering a private
/// socket, FlClashX carries every packet on this machine, and a failed
/// toggle is an outage with no reliable way back to the user's profile.
enum TunnelActions {

    /// Resolve where the open action would go, WITHOUT launching anything.
    /// The section uses this to HIDE the button rather than offer an action
    /// that would fail.
    ///
    /// Reads the URL off the status row rather than off the install index,
    /// so nothing but `TunnelMetrics` ever has to reach the main thread —
    /// `bundleURL` came from the same stat'd cold sweep either way.
    static func openTarget(_ status: TunnelToolStatus) -> URL? {
        status.bundleURL
    }

    /// Bring the app to the user. Main thread.
    ///
    /// The caller MUST have shown `tool.launchCaution` and had it confirmed
    /// when it is non-nil — launching a VPN client may connect it, and on
    /// this machine that is unverified rather than known-safe.
    static func open(_ status: TunnelToolStatus,
                     completion: ((Error?) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard let url = openTarget(status) else {
            completion?(CocoaError(.fileNoSuchFile))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion?(error) }
        }
    }
}

// MARK: - The watcher

/// Owns the cadence, exactly the way `PrinterPoller` does for the printer:
/// a feature that is NOT driven by MetricsEngine, publishing to
/// `IslandModel` only when the displayed value actually changed.
///
/// WHY NOT THE 1 Hz TICK. The sample costs ~95 us, so riding the base tick
/// would cost 0.0095% of a core — small, but it would be paid 8 640 times
/// an hour for an answer that changes when a tunnel comes up or goes down
/// and at no other time. 10 s is 1/10 of that for 10 s of worst-case
/// staleness on a fact that is stable for days. MetricsEngine's tick stays
/// 1 Hz and never learns this feature exists.
///
/// WHY NOT A PF_ROUTE EVENT LISTENER. The engine spike built one and it
/// works, but it was never witnessed surviving an actual tunnel
/// transition, so it would still have needed a slow safety re-check
/// underneath it — i.e. exactly this timer. It would buy latency only, at
/// the price of a second permanently-open routing socket receiving every
/// routing broadcast on the machine, a second exemption in build.sh's
/// stray-socket guard, and an invalidation path nobody has seen fire. For
/// 0.0009% of a core, polling is the honest trade. If someone later
/// witnesses a real up/down transition against the listener, that is the
/// time to reconsider.
final class TunnelWatcher {

    /// Panel open: the user is looking at the tab and a stale interface
    /// name is exactly what they came to check.
    private let openInterval: TimeInterval = 4
    /// Panel shut. The only consumer is the strip slot, which cares about
    /// "a tunnel came up", not about which second it did.
    private let idleInterval: TimeInterval = 10
    /// Nothing at all happens for this long after launch. The arch spike's
    /// rule: never do discovery work in didFinishLaunching — and the first
    /// thing this does is a LaunchServices sweep on the main thread.
    private let launchDelay: TimeInterval = 12

    /// The sample runs here and nowhere else. `qos: .utility`, matching
    /// MetricsEngine's own queue — this is background measurement, not
    /// anything the user is waiting on.
    private let queue = DispatchQueue(label: "com.local.macpulse.tunnel", qos: .utility)
    private let sampler = TunnelSampler()

    private weak var model: IslandModel?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var panelOpen = false
    /// Queue-confined copy of the cold-path snapshot. NEVER read from main.
    private var installs: [TunnelTool: TunnelInstall] = [:]

    init(model: IslandModel) {
        self.model = model
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) { [weak self] in
            guard let self, self.running else { return }
            TunnelInstallIndex.shared.start()
            let initial = TunnelInstallIndex.shared.snapshot
            self.queue.async { self.installs = initial }
            TunnelInstallIndex.shared.onChange = { [weak self] snapshot in
                guard let self else { return }
                self.queue.async {
                    self.installs = snapshot
                    // An install or a launch changes every row's verdict, so
                    // re-derive at once rather than wait out the interval.
                    self.sampleAndPublish()
                }
            }
            self.reschedule()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        running = false
        timer?.cancel()
        timer = nil
        TunnelInstallIndex.shared.onChange = nil
        TunnelInstallIndex.shared.stop()
    }

    /// The panel opened or closed. Only the cadence changes; there is no
    /// extra sample on open, because the timer is rescheduled with a
    /// `.now()` deadline and the first fire is immediate — which is safe
    /// here in a way it is not for the printer, since nothing in this
    /// sample is a delta and nothing off this machine is touched.
    func setPanelOpen(_ open: Bool) {
        precondition(Thread.isMainThread)
        guard panelOpen != open else { return }
        panelOpen = open
        guard running, timer != nil else { return }
        reschedule()
    }

    private func reschedule() {
        precondition(Thread.isMainThread)
        let interval = panelOpen ? openInterval : idleInterval
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this is a staleness bound, not a clock, and
        // leeway is what lets the kernel coalesce our wakeup with somebody
        // else's instead of waking the CPU on its own account.
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.sampleAndPublish() }
        t.resume()
        timer = t
    }

    /// WATCHER QUEUE.
    private func sampleAndPublish() {
        guard let metrics = sampler.sample(installed: installs) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.model?.setTunnel(metrics)
        }
    }
}
