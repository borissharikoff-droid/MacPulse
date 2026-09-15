import Darwin
import Foundation

// =====================================================================
// THE ONLY FILE IN MacPulse THAT OPENS A SOCKET.
//
// Read this whole header before touching anything below it. This file is
// the single, deliberate exception to the app's "no networking" property,
// and the exception is only defensible because of how narrow it is.
//
// ---------------------------------------------------------------------
// WHAT THE CONTRACT SAYS, AND WHAT THIS CHANGES
//
// MacPulse links no CFNetwork, no Network.framework, no Security.
// `otool -L` proves that, and build.sh asserts it on every build. A raw
// POSIX socket keeps that true — it is libSystem, which is already
// linked — whereas one URLSession call pulls CFNetwork into the link map.
// That was measured, not assumed: the spike compiled both candidates and
// diffed `otool -L`; URLSession added
// `/System/Library/Frameworks/CFNetwork.framework/...` and the raw socket
// added nothing.
//
// BE HONEST ABOUT WHAT IT DOES CHANGE. The binary now has IPC it did not
// have. "Nothing leaves this machine" still holds; "no network at all" no
// longer holds literally, and `otool -L` alone stops being a sufficient
// check of the contract. That is why build.sh now greps the source tree
// as well — see the `CONTRACT GUARD` block there.
//
// ---------------------------------------------------------------------
// WHY AN EXTERNAL CONNECTION IS UNREPRESENTABLE, NOT MERELY UNINTENDED
//
//   * The address is built from the `INADDR_LOOPBACK` CONSTANT. There is
//     no hostname, no `getaddrinfo`, no `gethostbyname`, no URL type, no
//     proxy lookup, and no string anywhere in this file that could hold
//     an address.
//   * The port is a compile-time literal. It is not read from
//     panel_state.json, not from a pref, not from the environment. Note
//     that the panel's own bambu_core.py DOES let its printer host come
//     from state/env — MacPulse must never inherit that flexibility.
//   * There is no `path` parameter. The entire HTTP request, verb and
//     all, is one `let` string literal. A caller cannot pass a route, so
//     a caller cannot pass an absolute URL either.
//   * The verb in that literal is GET. There is no POST path in this
//     file, which is what makes "MacPulse never commands the printer"
//     structural: the panel's control routes (/api/printer/cmd — pause,
//     resume, stop, light) are POST-only, so this code physically cannot
//     reach them. Read-only is enforced by the absence of code, not by
//     anyone remembering.
//   * /api/state is NEVER fetched. It returns the printer's access code
//     in plaintext. Not fetching it is why that secret never enters this
//     process's memory.
//   * After connect, `getpeername` is asked where the kernel actually
//     landed us and the answer is required to be 127.0.0.1. Belt and
//     braces against a future edit above it.
//   * Response bodies are never logged.
//
// ---------------------------------------------------------------------
// WHY IT CANNOT HANG THE UI
//
// The panel's /api/printer is a BLOCKING call: it does a 3 s TCP probe of
// the printer and then waits up to 8 s for an MQTT report, ~11 s worst
// case, on its own request thread. Measured on this machine: 3.5 s cold
// with the printer powered down, ~1 ms once ARP had learned the host was
// down, and 0.2 ms to fail outright when the panel is not running.
//
// So: connect gets a short non-blocking deadline; the read gets a
// wall-clock deadline AND an SO_RCVTIMEO that is DERIVED FROM IT and
// re-armed before every read, so neither a peer that goes silent nor one
// that dribbles a byte at a time can outlast `readTimeout`; the body is
// capped; and every call is made from a utility queue. Nothing here ever
// runs on main.
//
// (It used to set SO_RCVTIMEO to `connectTimeout + 12` = 13 s underneath a
// 12 s wall deadline that was only checked BETWEEN reads, so one silent
// peer could hold the thread 13 s and a dribbler ~25 s — both longer than
// the ~12 s this header and FeaturePrinter both promised. The socket
// timeout must never be larger than the deadline it is supposed to serve.)
// =====================================================================

enum PultLinkError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case connectRefused(Int32)
    case connectTimedOut
    case notLoopback(String)
    case writeFailed(Int32)
    case readFailed(Int32)
    case readTimedOut
    case malformedResponse(String)
    case httpStatus(Int)

    var description: String {
        switch self {
        case .socketFailed(let e):   return "socket(): \(Self.strerror(e))"
        case .connectRefused(let e): return "connect(): \(Self.strerror(e))"
        case .connectTimedOut:       return "connect timed out"
        case .notLoopback(let who):  return "peer is not loopback (\(who))"
        case .writeFailed(let e):    return "write(): \(Self.strerror(e))"
        case .readFailed(let e):     return "read(): \(Self.strerror(e))"
        case .readTimedOut:          return "read timed out"
        case .malformedResponse(let why): return "malformed response: \(why)"
        case .httpStatus(let code):  return "HTTP \(code)"
        }
    }

    private static func strerror(_ e: Int32) -> String {
        String(cString: Darwin.strerror(e))
    }
}

enum PultLink {

    /// The user's own panel, a LaunchAgent (com.pult.p1s) bound to
    /// 127.0.0.1 only. A literal, never configuration — see the header.
    private static let port: UInt16 = 8787

    /// The WHOLE request, as one literal. No interpolation of anything a
    /// caller could supply.
    ///
    /// `Host:` has to be exactly this: the panel's own `_same_origin()`
    /// answers 403 to any other Host value (verified — `evil.example` and
    /// `127.0.0.1:9999` both got 403 over the same loopback socket).
    private static let request = """
    GET /api/printer HTTP/1.1\r
    Host: 127.0.0.1:8787\r
    Accept: application/json\r
    Connection: close\r
    User-Agent: MacPulse\r
    \r

    """

    /// Panel replies are a few hundred bytes. Anything past this is not a
    /// reply we understand, and the cap is what stops a misbehaving local
    /// process from making us allocate without bound.
    private static let maxBodyBytes = 64 * 1024

    /// Fetch the panel's printer status. Blocking — CALL ONLY FROM A
    /// BACKGROUND QUEUE. Returns the raw JSON body; parsing is somebody
    /// else's job (see FeaturePrinter).
    static func fetchPrinterStatus(connectTimeout: TimeInterval = 0.75,
                                   readTimeout: TimeInterval = 12.0) throws -> String {
        // Both budgets are clamped to something a timeval can hold, so a
        // caller (or a future edit) cannot turn a timeout into a trapping
        // Double -> Int conversion, and cannot ask for a wait measured in
        // centuries either.
        let connectBudget = Self.clampSeconds(connectTimeout, max: 10)
        let readBudget = Self.clampSeconds(readTimeout, max: 60)

        let fd = try connectLoopback(timeout: connectBudget, readBudget: readBudget)
        defer { close(fd) }

        let out = Array(request.utf8)
        let total = out.count
        var sent = 0
        while sent < total {
            let n = out.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: sent), total - sent)
            }
            if n <= 0 {
                if errno == EINTR { continue }
                throw PultLinkError.writeFailed(errno)
            }
            sent += n
        }

        // Wall-clock deadline as well as SO_RCVTIMEO: the socket timeout
        // only fires on a read that stalls completely, and a peer that
        // sends one byte per second would reset it forever.
        //
        // THE SOCKET TIMEOUT IS DERIVED FROM THE DEADLINE, NEVER LARGER
        // THAN IT, AND IT IS RE-ARMED BEFORE EVERY READ. It used to be a
        // flat `connectTimeout + 12` = 13 s sitting under a 12 s wall
        // deadline that was only tested BETWEEN reads, so a peer that
        // completed the handshake and then went silent held this thread
        // inside ONE read() for 13 s, and a dribbler that stalled just
        // before the deadline reached ~25 s — against a documented "~12 s
        // worst case". Now the remaining budget is what the kernel is told,
        // so the real worst case is the number in the signature.
        let deadline = Date().addingTimeInterval(readBudget)
        var buf = [UInt8](repeating: 0, count: 8192)
        var acc = [UInt8]()
        acc.reserveCapacity(2048)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw PultLinkError.readTimedOut }
            Self.setReceiveTimeout(fd, seconds: remaining)
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }                       // clean EOF: Connection: close
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw PultLinkError.readTimedOut }
                throw PultLinkError.readFailed(errno)
            }
            acc.append(contentsOf: buf[0..<n])
            if acc.count > maxBodyBytes {
                throw PultLinkError.malformedResponse("over \(maxBodyBytes) bytes")
            }
        }

        let raw = String(decoding: acc, as: UTF8.self)
        guard let sep = raw.range(of: "\r\n\r\n") else {
            throw PultLinkError.malformedResponse("no header break")
        }
        let head = raw[raw.startIndex..<sep.lowerBound]
        let body = String(raw[sep.upperBound...])

        // "HTTP/1.0 200 OK" -> 200
        let status = head.split(separator: "\r\n").first
            .flatMap { $0.split(separator: " ").dropFirst().first }
            .flatMap { Int($0) }
        guard let status else { throw PultLinkError.malformedResponse("no status line") }
        guard status == 200 else { throw PultLinkError.httpStatus(status) }
        return body
    }

    // MARK: - The socket

    /// Seconds, guaranteed finite, non-negative and small enough that
    /// `Int(_:)` on it cannot trap. Every timeout in this file goes through
    /// here before it reaches a `timeval` or a `poll` millisecond count.
    private static func clampSeconds(_ v: TimeInterval, max cap: TimeInterval) -> TimeInterval {
        guard v.isFinite, v > 0 else { return 0.05 }
        return Swift.min(v, cap)
    }

    /// Arm SO_RCVTIMEO with a budget already known to be finite and small.
    private static func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        let s = clampSeconds(seconds, max: 60)
        var tv = timeval(tv_sec: Int(s),                                  // <= 60, cannot trap
                         tv_usec: suseconds_t((s - s.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connectLoopback(timeout: TimeInterval,
                                        readBudget: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PultLinkError.socketFailed(errno) }

        // THE ONE ADDRESS THIS BINARY CAN FORM. INADDR_LOOPBACK is the
        // C constant 0x7f000001; `.bigEndian` puts it in network order.
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        // Non-blocking connect + poll, so a panel that is not listening
        // (or a firewall that black-holes the SYN) cannot stall us for the
        // kernel's default 75 s.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var rc: Int32 = -1
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                rc = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else {
                let e = errno; close(fd); throw PultLinkError.connectRefused(e)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            // `timeout` is already clamped finite and <= 10 s by the caller,
            // so this Int32 conversion cannot trap.
            let pr = poll(&pfd, 1, Int32(timeout * 1000))
            if pr <= 0 { close(fd); throw PultLinkError.connectTimedOut }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { close(fd); throw PultLinkError.connectRefused(soErr) }
        }
        _ = fcntl(fd, F_SETFL, flags)     // back to blocking for the r/w timeouts

        // Send side: the request is 120 bytes into a loopback socket buffer,
        // so this only matters if the peer never drains. It gets the connect
        // budget, not the read budget — there is nothing to wait for yet.
        var sndtv = timeval(tv_sec: Int(clampSeconds(timeout, max: 10)), tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndtv, socklen_t(MemoryLayout<timeval>.size))
        // Receive side: an initial arming only. The read loop re-arms it
        // with the REMAINING wall-clock budget before every read, which is
        // what makes the documented worst case true.
        setReceiveTimeout(fd, seconds: readBudget)
        // Without this a write to a peer that closed first raises SIGPIPE
        // and kills the whole app rather than returning EPIPE.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // Ask the KERNEL where we landed rather than trusting the lines
        // above. If someone ever edits this file so that a non-loopback
        // address becomes representable, this is the tripwire.
        do {
            try assertLoopback(fd)
        } catch {
            close(fd); throw error
        }
        return fd
    }

    /// `getpeername` must say 127.0.0.0/8, or we hang up without sending
    /// a byte.
    private static func assertLoopback(_ fd: Int32) throws {
        var peer = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &peer) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &len)
            }
        }
        guard rc == 0 else { throw PultLinkError.notLoopback("getpeername failed") }
        let host = UInt32(bigEndian: peer.sin_addr.s_addr)
        guard peer.sin_family == sa_family_t(AF_INET), host >> 24 == 127 else {
            throw PultLinkError.notLoopback(String(format: "0x%08x", host))
        }
    }

    /// Human-readable peer, for `--printer-probe` only. Never used by the
    /// UI and never logged in the shipping path.
    static func describePeerForProbe() -> String {
        guard let fd = try? connectLoopback(timeout: 0.75, readBudget: 1) else {
            return "not listening"
        }
        defer { close(fd) }
        var peer = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &peer) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &len)
            }
        }
        guard rc == 0 else { return "getpeername failed" }
        let h = UInt32(bigEndian: peer.sin_addr.s_addr)
        return "\((h >> 24) & 255).\((h >> 16) & 255).\((h >> 8) & 255).\(h & 255)"
            + ":\(UInt16(bigEndian: peer.sin_port))"
    }
}
