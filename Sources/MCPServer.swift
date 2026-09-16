import Foundation
import AppKit

// =====================================================================
// MacPulse as an MCP server — «что не так с машиной», answered to an
// AI coding agent instead of to a pair of eyes.
//
//     /Applications/MacPulse.app/Contents/MacOS/MacPulse --mcp
//
// Hidden flag on the existing binary, dispatched from main.swift exactly
// like --probe / --printer-probe / --rail-probe. Nothing in the UI
// reaches it and the shipping app never takes this path.
//
// ---------------------------------------------------------------------
// THE TRANSPORT IS STDIO, AND THAT IS NOT AN IMPLEMENTATION DETAIL.
//
// Read this before you "improve" the transport, because the obvious
// improvement — a small HTTP or WebSocket listener on localhost — would
// silently destroy a property this binary has been rebuilt three times
// to keep.
//
// build.sh permits networking in exactly two files: Updater.swift (three
// GitHub hosts) and GeoLookup.swift (www.cloudflare.com), and it permits
// a raw socket in exactly one, PultLink.swift, whose address is built
// from the INADDR_LOOPBACK constant and a literal port and is therefore
// unrepresentably anything but 127.0.0.1:8787. On top of that, the
// SHIPPED binary imports no bind, no listen and no accept at all — check
// it yourself:
//
//     nm -u /Applications/MacPulse.app/Contents/MacOS/MacPulse | grep -E 'bind|listen|accept'
//
// That command printing nothing is the whole claim. MacPulse cannot
// receive a connection, from anywhere, because the code to receive one
// is not linked into it. A listener added here — for any reason, on any
// port, bound to loopback or not — would add those three symbols and end
// that sentence permanently.
//
// MCP over stdio needs none of it. The CLIENT spawns this binary as a
// child process and speaks JSON-RPC 2.0 over the child's stdin and
// stdout. There is no port, no socket, no address, no name resolution,
// no new networking symbol, and no change to any guard in build.sh.
// The transport is a pipe the client already owns; access control is
// process spawning, which is a thing the operating system already does
// well. This file adds zero bytes to the attack surface the contract
// describes, and that is not a coincidence — it is why stdio was chosen.
//
// If some future client needs HTTP, the answer is a SEPARATE binary that
// speaks HTTP and spawns this one, not a listener in here.
//
// ---------------------------------------------------------------------
// READ-ONLY, STRUCTURALLY.
//
// Every tool below reads. None of them quits an app, kills a process,
// deletes a file, changes a setting, or sends the printer anything. That
// is not a promise about intent, it is a property of what this file can
// reach: it never touches IslandModel.quit(...), NSRunningApplication's
// terminate()/forceTerminate(), PressureAlert's quit plan, PultLink, or
// any Maintenance path. The quit path is not imported, not referenced
// and not reachable from any code in this file — grep it.
//
// The reason is specific, not decorative. An agent reading these tools is
// acting on its own judgement about a machine it cannot see. It must be
// able to tell the user "Cursor is holding 4.2 GB and the compressor is
// decompressing 180 MB/s, close a window" — and it must NOT be able to
// close it. A wrong diagnosis costs the user a sentence; a wrong action
// costs them unsaved work.
//
// `is_quittable_application` in the top-apps rows is the one place this
// could be misread: it is a FACT ABOUT THE PROCESS (macOS considers it a
// real application with a UI the user could quit), not an offer. Nothing
// here can act on it.
//
// ---------------------------------------------------------------------
// PRIVACY: THE EXACT SHAPE OF THE BARGAIN.
//
// These tools hand PROCESS NAMES and APP NAMES to whatever model the
// client is talking to. That is the deal — "which app is eating your
// RAM" is unanswerable without naming the app — and it is the ONLY thing
// widened beyond numbers. Specifically NOT exposed, and not by accident:
//
//   * no window titles, ever. Nothing here reads any.
//   * no file paths. A footprint row carries name, bundle id and pid;
//     it does not carry the executable path, and the tunnel rows report
//     interface names, never the bundle location LaunchServices returned.
//   * NO CLIPBOARD CONTENT OF ANY KIND. MacPulse has a full clipboard
//     history engine (ClipboardEngine.swift) and it is deliberately
//     unreachable from here. A clipboard is where passwords, tokens and
//     one-time codes live for thirty seconds at a time; "the agent can
//     read your clipboard" is a different product with a different
//     consent conversation, and shipping it as a side effect of a memory
//     tool would be indefensible. Stronger than not exposing it: this
//     process sets ClipboardEngine.shared.isPaused = true BEFORE the
//     metrics engine starts, because MetricsEngine.tick() polls the
//     clipboard for the island's shelf. Paused, the engine tracks
//     changeCount and records nothing — so an --mcp process never even
//     HOLDS clipboard content, let alone serves it.
//   * nothing from ~/.vibehub. Its config.json holds a device token.
//     IslandSectionVibe is not started, not read and not referenced.
//   * no calendar, no meeting titles, no audio device history.
//
// ---------------------------------------------------------------------
// STDOUT DISCIPLINE, MADE STRUCTURAL.
//
// A stdio MCP server dies from one bug more than all others combined: a
// stray print() on stdout. The client is parsing that stream as JSON; a
// log line there is not a message the user sees, it is a parse error
// that kills the session and hides whatever the line said.
//
// So stdout is TAKEN AWAY from the rest of the process on entry. run()
// dups fd 1 to a private descriptor, writes protocol frames only to that
// descriptor, and then points fd 1 at stderr. After those two lines, any
// print() anywhere in MacPulse — this file, a sampler, a framework —
// lands on stderr and is harmless. There are no print() calls in this
// file either (grep it), but the dup2 is what makes that a property of
// the process rather than a property of my discipline.
// =====================================================================

// MARK: - JSON output

/// A JSON value we can render EXACTLY, with the two behaviours this
/// server needs and JSONSerialization does not give:
///
///   1. `nil` renders as `null`, always, never as 0. The whole metrics
///      layer distinguishes "could not measure" from "measured zero"
///      (MetricTypes.swift's design rule) and that distinction has to
///      survive the wire, or an agent reads a failed sysctl as a quiet
///      machine.
///   2. A non-finite Double renders as `null` instead of throwing.
///      JSONSerialization THROWS on NaN and infinity, which would turn a
///      divide-by-a-near-zero-dt into a dead session; here it degrades to
///      the same "unavailable" every other unmeasurable value uses.
///
/// Object keys keep insertion order, so the output reads top-down like a
/// report rather than alphabetically like a dump.
indirect enum MCPValue {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([MCPValue])
    case object([(String, MCPValue)])

    // ---- Optional-aware constructors. Each maps nil to .null. ----
    static func num(_ v: Double?) -> MCPValue {
        guard let v, v.isFinite else { return .null }
        return .double(v)
    }
    /// Rounded to `places` decimals — for rates and percentages, where 14
    /// significant figures are noise an agent has to read past.
    static func num(_ v: Double?, _ places: Int) -> MCPValue {
        guard let v, v.isFinite else { return .null }
        let scale = pow(10.0, Double(places))
        let rounded = (v * scale).rounded() / scale
        return rounded.isFinite ? .double(rounded) : .null
    }
    static func intOrNull(_ v: Int?) -> MCPValue {
        guard let v else { return .null }
        return .int(Int64(v))
    }
    static func intOrNull(_ v: Int32?) -> MCPValue {
        guard let v else { return .null }
        return .int(Int64(v))
    }
    static func intOrNull(_ v: UInt32?) -> MCPValue {
        guard let v else { return .null }
        return .int(Int64(v))
    }
    static func bytes(_ v: UInt64?) -> MCPValue {
        guard let v else { return .null }
        return .uint(v)
    }
    static func str(_ v: String?) -> MCPValue {
        guard let v else { return .null }
        return .string(v)
    }
    static func flag(_ v: Bool?) -> MCPValue {
        guard let v else { return .null }
        return .bool(v)
    }
    static func strings(_ v: [String]) -> MCPValue {
        .array(v.map { .string($0) })
    }

    // MARK: Rendering

    func rendered(pretty: Bool = false, depth: Int = 0) -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .double(let d):
            guard d.isFinite else { return "null" }
            // An integral double renders without the ".0" tail: 16384.0 is
            // a page size, and printing it as 16384.0 makes a reader ask
            // what the fraction means.
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return MCPValue.escape(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if !pretty {
                return "[" + items.map { $0.rendered() }.joined(separator: ",") + "]"
            }
            let pad = String(repeating: " ", count: (depth + 1) * 2)
            let closePad = String(repeating: " ", count: depth * 2)
            let body = items.map { pad + $0.rendered(pretty: true, depth: depth + 1) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + closePad + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            if !pretty {
                let body = pairs.map { MCPValue.escape($0.0) + ":" + $0.1.rendered() }
                return "{" + body.joined(separator: ",") + "}"
            }
            let pad = String(repeating: " ", count: (depth + 1) * 2)
            let closePad = String(repeating: " ", count: depth * 2)
            let body = pairs.map {
                pad + MCPValue.escape($0.0) + ": " + $0.1.rendered(pretty: true, depth: depth + 1)
            }
            return "{\n" + body.joined(separator: ",\n") + "\n" + closePad + "}"
        }
    }

    /// JSON string escaping. Control characters below 0x20 MUST be escaped
    /// or the frame is invalid JSON — and an app name really can contain
    /// one, because an app name is whatever the bundle says it is.
    private static func escape(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Convenience: build an object from an ordered list of pairs.
func mcpObject(_ pairs: [(String, MCPValue)]) -> MCPValue { .object(pairs) }

// MARK: - stderr

/// The ONLY logging channel. Never stdout — see the header. Unbuffered,
/// because a crash that swallows its own explanation is worse than no
/// explanation.
func mcpLog(_ message: String) {
    FileHandle.standardError.write(Data(("[macpulse-mcp] " + message + "\n").utf8))
}

// MARK: - Framing

/// The two framings a stdio MCP client can speak.
///
/// The current MCP specification (the stdio transport section) says
/// newline-delimited JSON: one JSON-RPC message per line, and the message
/// itself MUST NOT contain an embedded newline. Earlier drafts, and every
/// client written against LSP habits, use the `Content-Length:` header
/// framing instead.
///
/// So this server READS both and WRITES whichever the client used for the
/// message being answered. A client that sends line-delimited JSON gets
/// line-delimited JSON back; one that sends headers gets headers back. A
/// server that guesses wrong here looks, from the client side, exactly
/// like a server that crashed on startup.
enum MCPFraming {
    case line
    case contentLength
}

/// Reads frames from a file descriptor with no assumption that a read()
/// returns whole messages: a pipe splits wherever it likes, and a 40 KB
/// tools/list response arrives in pieces on the other side too.
final class MCPFrameReader {

    /// Refuse to buffer more than this without a complete frame. A client
    /// that streams 64 MB of garbage gets an error and a reset buffer, not
    /// an out-of-memory kill.
    private static let maxFrameBytes = 8 * 1024 * 1024

    private let fd: Int32
    private var buffer = Data()
    private var reachedEOF = false

    init(fd: Int32) { self.fd = fd }

    enum Outcome {
        case frame(Data, MCPFraming)
        /// The stream is unparseable at this point; the caller answers with
        /// a JSON-RPC parse error. The buffer has been reset.
        case malformed(String)
        /// Clean end of input — the client closed the pipe.
        case eof
    }

    func next() -> Outcome {
        while true {
            trimLeadingSeparators()

            switch headerDecision() {
            case .needMoreInput:
                if reachedEOF { return finishAtEOF() }
                if !fill() { return finishAtEOF() }
                continue

            case .contentLength:
                guard let headerEnd = indexOfHeaderTerminator() else {
                    if buffer.count > Self.maxFrameBytes {
                        return reset("Content-Length header never terminated")
                    }
                    if reachedEOF { return finishAtEOF() }
                    if !fill() { return finishAtEOF() }
                    continue
                }
                let headerBytes = buffer.prefix(headerEnd.start)
                guard let length = parseContentLength(headerBytes) else {
                    buffer.removeFirst(headerEnd.end)
                    return .malformed("Content-Length header missing or not a number")
                }
                guard length >= 0, length <= Self.maxFrameBytes else {
                    buffer.removeFirst(headerEnd.end)
                    return .malformed("Content-Length \(length) out of range")
                }
                let bodyStart = headerEnd.end
                while buffer.count < bodyStart + length {
                    if reachedEOF { return finishAtEOF() }
                    if !fill() { return finishAtEOF() }
                }
                let body = Data(buffer[buffer.startIndex.advanced(by: bodyStart)
                                       ..< buffer.startIndex.advanced(by: bodyStart + length)])
                buffer.removeFirst(bodyStart + length)
                return .frame(body, .contentLength)

            case .line:
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let offset = buffer.distance(from: buffer.startIndex, to: newline)
                    var line = Data(buffer.prefix(offset))
                    buffer.removeFirst(offset + 1)
                    if line.last == 0x0D { line.removeLast() }   // tolerate CRLF
                    if line.isEmpty { continue }                 // blank keep-alive line
                    return .frame(line, .line)
                }
                if buffer.count > Self.maxFrameBytes {
                    return reset("line longer than \(Self.maxFrameBytes) bytes with no newline")
                }
                if reachedEOF { return finishAtEOF() }
                if !fill() { return finishAtEOF() }
            }
        }
    }

    // MARK: Internals

    private enum Decision { case line, contentLength, needMoreInput }

    /// Is this frame header-framed? Decided on the first bytes, and it has
    /// to tolerate not having them all yet.
    private func headerDecision() -> Decision {
        let probe = Array("content-length:".utf8)
        if buffer.isEmpty { return .needMoreInput }
        let have = min(buffer.count, probe.count)
        for i in 0..<have {
            let byte = buffer[buffer.startIndex.advanced(by: i)]
            // A newline inside the probe window settles it: no header here.
            if byte == 0x0A { return .line }
            let lowered = (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
            if lowered != probe[i] { return .line }
        }
        return have == probe.count ? .contentLength : .needMoreInput
    }

    /// End of the header block: \r\n\r\n, or \n\n from a lenient client.
    private func indexOfHeaderTerminator() -> (start: Int, end: Int)? {
        let bytes = [UInt8](buffer)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D, i + 3 < bytes.count,
               bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                return (i, i + 4)
            }
            if bytes[i] == 0x0A, bytes[i + 1] == 0x0A {
                return (i, i + 2)
            }
            i += 1
        }
        return nil
    }

    private func parseContentLength(_ header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }

    /// Blank lines and stray CR/LF between frames are not errors.
    private func trimLeadingSeparators() {
        while let first = buffer.first, first == 0x0A || first == 0x0D {
            buffer.removeFirst()
        }
    }

    private func reset(_ reason: String) -> Outcome {
        buffer.removeAll(keepingCapacity: false)
        return .malformed(reason)
    }

    /// EOF with bytes still in hand: a last line with no trailing newline is
    /// a legitimate frame (echo without -n, a heredoc, a test script). Bytes
    /// that are not a whole frame are reported as malformed, never silently
    /// dropped.
    private func finishAtEOF() -> Outcome {
        trimLeadingSeparators()
        guard !buffer.isEmpty else { return .eof }
        let tail = Data(buffer)
        buffer.removeAll(keepingCapacity: false)
        if case .contentLength = headerDecisionForTail(tail) {
            return .malformed("EOF inside a Content-Length frame")
        }
        return .frame(tail, .line)
    }

    private func headerDecisionForTail(_ tail: Data) -> Decision {
        let probe = Array("content-length:".utf8)
        guard tail.count >= probe.count else { return .line }
        for i in 0..<probe.count {
            let byte = tail[tail.startIndex.advanced(by: i)]
            let lowered = (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
            if lowered != probe[i] { return .line }
        }
        return .contentLength
    }

    /// One read(). false means EOF.
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                return true
            }
            if n == 0 {
                reachedEOF = true
                return false
            }
            if errno == EINTR { continue }      // a signal, not an error
            mcpLog("stdin read failed: \(String(cString: strerror(errno))) — treating as EOF")
            reachedEOF = true
            return false
        }
    }
}

/// Writes frames to the PRIVATE copy of the original stdout. Raw write(2)
/// with no FILE* buffering in the way, so nothing can be left unflushed in
/// a userspace buffer when the process exits.
final class MCPFrameWriter {

    private let fd: Int32

    init(fd: Int32) { self.fd = fd }

    /// - Returns: false when the client has gone away (EPIPE). The caller
    ///   exits cleanly; it does NOT retry, and it does not crash, which is
    ///   the whole point of ignoring SIGPIPE on entry.
    @discardableResult
    func send(_ value: MCPValue, framing: MCPFraming) -> Bool {
        let body = Data(value.rendered().utf8)
        var frame: Data
        switch framing {
        case .line:
            frame = body
            frame.append(0x0A)
        case .contentLength:
            frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            frame.append(body)
        }
        return writeAll(frame)
    }

    private func writeAll(_ data: Data) -> Bool {
        let remaining = [UInt8](data)
        var offset = 0
        while offset < remaining.count {
            let written = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), remaining.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EPIPE {
                mcpLog("client closed the pipe mid-response — exiting cleanly")
                return false
            }
            mcpLog("stdout write failed: \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }
}

// MARK: - JSON-RPC plumbing

/// A JSON-RPC error that becomes an `error` object in the response.
/// Thrown, never fatal — no input from the client may end this process
/// except a closed pipe.
struct MCPRPCError: Error {
    let code: Int
    let message: String
    var data: MCPValue?

    static func invalidParams(_ message: String) -> MCPRPCError {
        MCPRPCError(code: -32602, message: message, data: nil)
    }
    static func methodNotFound(_ method: String) -> MCPRPCError {
        MCPRPCError(code: -32601,
                    message: "Method not found: \(method)",
                    data: .object([("supported", .strings(MCPDispatch.supportedMethods))]))
    }
    static func internalError(_ message: String) -> MCPRPCError {
        MCPRPCError(code: -32603, message: message, data: nil)
    }
}

enum MCPDispatch {
    static let supportedMethods = [
        "initialize", "notifications/initialized", "ping",
        "tools/list", "tools/call", "shutdown", "exit"
    ]
}

/// Reading untyped JSON without force-casts. Every accessor answers nil
/// rather than trapping: the input is whatever the client sent.
enum MCPJSONIn {
    static func object(_ any: Any?) -> [String: Any]? { any as? [String: Any] }

    static func string(_ any: Any?) -> String? { any as? String }

    /// Rejects booleans, which bridge to NSNumber and would otherwise read
    /// as 1 and 0.
    static func int(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let d = number.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return number.intValue
    }

    /// The request id, echoed back byte-for-byte in kind. JSON-RPC allows a
    /// string or a number and they are not interchangeable — a client that
    /// sent "1" and gets back 1 will not match the response to its request.
    static func id(_ any: Any?) -> MCPValue? {
        if let s = any as? String { return .string(s) }
        guard let number = any as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let d = number.doubleValue
        if d == d.rounded(), abs(d) < 9e15 { return .int(number.int64Value) }
        return .double(d)
    }
}

// MARK: - The session

/// One client, one pair of pipes, one thread. Everything in here runs on
/// the reader thread; anything that has to touch the metrics engine hops
/// to main with `DispatchQueue.main.sync` (MetricsEngine documents
/// `latest`/`history` as main-thread-only, and PrivacyWatcher's name
/// resolution asserts it).
final class MCPSession {

    static let protocolVersion = "2025-06-18"
    /// Versions we will echo back if the client asks for one of them. An
    /// unknown version is answered with ours, which is what the spec says
    /// to do and lets an older client decide whether to continue.
    static let knownProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
    ]

    private let reader: MCPFrameReader
    private let writer: MCPFrameWriter
    private let tools: MCPToolbox
    /// Framing of the last frame received — used for a parse error, where
    /// there is no frame to answer in kind.
    private var lastFraming: MCPFraming = .line
    private var initialized = false
    private var exitAfterCurrentResponse = false

    init(inputFD: Int32, outputFD: Int32, toolbox: MCPToolbox) {
        self.reader = MCPFrameReader(fd: inputFD)
        self.writer = MCPFrameWriter(fd: outputFD)
        self.tools = toolbox
    }

    func run() -> Never {
        while true {
            switch reader.next() {
            case .eof:
                mcpLog("stdin closed — exiting")
                exit(0)

            case .malformed(let reason):
                // Malformed input is the client's problem, not a reason to
                // die: answer -32700 with a null id (JSON-RPC's rule when
                // the id could not be recovered) and keep reading.
                mcpLog("parse error: \(reason)")
                emit(Self.errorEnvelope(id: .null, error:
                        MCPRPCError(code: -32700, message: "Parse error: \(reason)", data: nil)),
                     framing: lastFraming)

            case .frame(let data, let framing):
                lastFraming = framing
                handle(frame: data, framing: framing)
            }
        }
    }

    // MARK: Frame handling

    private func handle(frame: Data, framing: MCPFraming) {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: frame, options: [.fragmentsAllowed])
        } catch {
            let preview = String(data: frame.prefix(200), encoding: .utf8) ?? "<non-utf8 bytes>"
            mcpLog("invalid JSON (\(frame.count) bytes): \(error.localizedDescription)")
            emit(Self.errorEnvelope(id: .null, error:
                    MCPRPCError(code: -32700,
                                message: "Parse error: not valid JSON",
                                data: .object([("received", .string(preview))]))),
                 framing: framing)
            return
        }

        // A batch. Removed from the current MCP revision, still trivially
        // supportable, and being liberal about it costs nothing: answer only
        // the requests, and send nothing at all if every element was a
        // notification (JSON-RPC's rule).
        if let batch = parsed as? [Any] {
            guard !batch.isEmpty else {
                emit(Self.errorEnvelope(id: .null, error:
                        MCPRPCError(code: -32600, message: "Invalid Request: empty batch", data: nil)),
                     framing: framing)
                return
            }
            var responses: [MCPValue] = []
            for element in batch {
                if let response = process(message: element) { responses.append(response) }
            }
            if !responses.isEmpty { emit(.array(responses), framing: framing) }
            return
        }

        if let response = process(message: parsed) {
            emit(response, framing: framing)
        }
    }

    /// - Returns: the response to send, or nil when the message was a
    ///   notification (JSON-RPC forbids responding to those).
    private func process(message: Any) -> MCPValue? {
        guard let dict = MCPJSONIn.object(message) else {
            return Self.errorEnvelope(id: .null, error:
                MCPRPCError(code: -32600,
                            message: "Invalid Request: expected a JSON object",
                            data: nil))
        }

        let rawID = dict["id"]
        let isNotification = rawID == nil || rawID is NSNull
        let id = MCPJSONIn.id(rawID) ?? .null

        if rawID != nil, !(rawID is NSNull), MCPJSONIn.id(rawID) == nil {
            return Self.errorEnvelope(id: .null, error:
                MCPRPCError(code: -32600,
                            message: "Invalid Request: id must be a string or a number",
                            data: nil))
        }

        guard MCPJSONIn.string(dict["jsonrpc"]) == "2.0" else {
            let response = Self.errorEnvelope(id: id, error:
                MCPRPCError(code: -32600,
                            message: "Invalid Request: \"jsonrpc\" must be exactly \"2.0\"",
                            data: nil))
            return isNotification ? nil : response
        }

        guard let method = MCPJSONIn.string(dict["method"]) else {
            let response = Self.errorEnvelope(id: id, error:
                MCPRPCError(code: -32600,
                            message: "Invalid Request: \"method\" is missing or not a string",
                            data: nil))
            return isNotification ? nil : response
        }

        // `params` is optional; when present it must be an object. We do not
        // accept positional (array) params — MCP never uses them.
        var params: [String: Any] = [:]
        if let raw = dict["params"], !(raw is NSNull) {
            guard let object = MCPJSONIn.object(raw) else {
                let response = Self.errorEnvelope(id: id, error:
                    MCPRPCError.invalidParams("\"params\" must be an object"))
                return isNotification ? nil : response
            }
            params = object
        }

        if isNotification {
            handleNotification(method: method, params: params)
            return nil
        }

        do {
            let result = try handleRequest(method: method, params: params)
            return Self.successEnvelope(id: id, result: result)
        } catch let error as MCPRPCError {
            mcpLog("\(method) -> error \(error.code): \(error.message)")
            return Self.errorEnvelope(id: id, error: error)
        } catch {
            // Nothing throws anything else, but a server that can be killed
            // by an unexpected error is a server that hangs a client.
            mcpLog("\(method) -> unexpected error: \(error)")
            return Self.errorEnvelope(id: id, error:
                MCPRPCError.internalError("Unexpected failure in \(method)"))
        }
    }

    /// Notifications get NO response, ever — that is the protocol, not a
    /// shortcut. An unknown one is reported on stderr, which is why stderr
    /// exists: it is visible to the operator without corrupting the stream.
    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "notifications/initialized":
            initialized = true
            mcpLog("client completed initialization")
        case "notifications/cancelled", "notifications/progress", "$/cancelRequest":
            mcpLog("ignoring \(method) — nothing here is long-running or cancellable")
        case "exit":
            mcpLog("exit notification — shutting down")
            exit(0)
        default:
            mcpLog("unknown notification \(method) — ignored (JSON-RPC forbids a reply to a notification)")
        }
    }

    private func handleRequest(method: String, params: [String: Any]) throws -> MCPValue {
        switch method {
        case "initialize":
            return initializeResult(params: params)

        case "ping":
            return .object([])

        case "tools/list":
            if !initialized { mcpLog("tools/list before notifications/initialized — answering anyway") }
            return .object([("tools", tools.listing())])

        case "tools/call":
            return try callTool(params: params)

        case "shutdown":
            // Not an MCP method (it is LSP's), but clients built on LSP
            // habits send it, and a clean answer plus a clean exit beats a
            // "method not found" followed by a hang.
            mcpLog("shutdown requested — exiting after this response")
            exitAfterCurrentResponse = true
            return .object([])

        // Declared-capability probes. We advertise only `tools`, so these
        // are answered with a proper error rather than an empty list that
        // would imply the capability exists and is empty.
        case "resources/list", "resources/templates/list", "resources/read",
             "prompts/list", "prompts/get", "completion/complete",
             "logging/setLevel", "sampling/createMessage", "roots/list":
            throw MCPRPCError(code: -32601,
                              message: "Method not found: \(method)",
                              data: .object([
                                ("reason", .string("this server advertises the \"tools\" capability only")),
                                ("supported", .strings(MCPDispatch.supportedMethods))]))

        default:
            throw MCPRPCError.methodNotFound(method)
        }
    }

    private func initializeResult(params: [String: Any]) -> MCPValue {
        let requested = MCPJSONIn.string(params["protocolVersion"])
        let agreed: String
        if let requested, Self.knownProtocolVersions.contains(requested) {
            agreed = requested
        } else {
            agreed = Self.protocolVersion
            if let requested {
                mcpLog("client asked for protocolVersion \(requested), which we do not know; offering \(agreed)")
            } else {
                mcpLog("client sent no protocolVersion; offering \(agreed)")
            }
        }
        if let client = MCPJSONIn.object(params["clientInfo"]) {
            mcpLog("client: \(MCPJSONIn.string(client["name"]) ?? "?") "
                   + (MCPJSONIn.string(client["version"]) ?? ""))
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        return .object([
            ("protocolVersion", .string(agreed)),
            ("capabilities", .object([
                // listChanged is false and stated: the tool list is compiled
                // into the binary and cannot change while the process lives.
                ("tools", .object([("listChanged", .bool(false))]))
            ])),
            ("serverInfo", .object([
                ("name", .string("macpulse")),
                ("title", .string("MacPulse — macOS pressure, compressor and power telemetry")),
                ("version", .string(version ?? "0.0.0"))
            ])),
            ("instructions", .string("""
                MacPulse measures things Activity Monitor does not show. All six tools are \
                READ-ONLY: this server cannot quit an app, kill a process, change a setting or \
                write anything. Tell the user what to close; you cannot close it.

                When a machine "feels slow" and CPU and disk look fine, call compressor_churn \
                before anything else — sustained decompression is memory pressure being paid \
                for in latency, it never touches the disk, and no shipping tool displays it. \
                Judge memory with memory_pressure (the kernel's own verdict), never with free \
                RAM, which on macOS is meaningless by design. Then use top_memory_apps to name \
                the app worth closing.

                Every unmeasurable value is null and never 0. A present 0.0 is a real \
                measurement. Process and app names are returned; window titles, file paths and \
                clipboard contents are not, and no tool can be made to return them.
                """))
        ])
    }

    private func callTool(params: [String: Any]) throws -> MCPValue {
        guard let name = MCPJSONIn.string(params["name"]) else {
            throw MCPRPCError.invalidParams(
                "tools/call requires a \"name\" string naming one of: "
                + MCPToolbox.toolNames.joined(separator: ", "))
        }
        var arguments: [String: Any] = [:]
        if let raw = params["arguments"], !(raw is NSNull) {
            guard let object = MCPJSONIn.object(raw) else {
                throw MCPRPCError.invalidParams("\"arguments\" must be an object")
            }
            arguments = object
        }
        return try tools.call(name: name, arguments: arguments)
    }

    // MARK: Envelopes and output

    private static func successEnvelope(id: MCPValue, result: MCPValue) -> MCPValue {
        .object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
    }

    private static func errorEnvelope(id: MCPValue, error: MCPRPCError) -> MCPValue {
        var fields: [(String, MCPValue)] = [
            ("code", .int(Int64(error.code))),
            ("message", .string(error.message))
        ]
        if let data = error.data { fields.append(("data", data)) }
        return .object([("jsonrpc", .string("2.0")), ("id", id), ("error", .object(fields))])
    }

    private func emit(_ value: MCPValue, framing: MCPFraming) {
        if !writer.send(value, framing: framing) {
            // The client is gone. Nothing left to say and nobody to say it
            // to: exit 0, because a client hanging up is not a failure.
            exit(0)
        }
        if exitAfterCurrentResponse { exit(0) }
    }
}

// MARK: - The tools

/// A tool that ran but could not measure what it was asked for. Reported
/// as `isError: true` INSIDE a normal result, which is what the MCP
/// specification asks for: the model is supposed to see the failure and
/// reason about it, not have the call disappear into a protocol error the
/// client swallows.
struct MCPToolFailure: Error {
    let message: String
    var detail: MCPValue?
}

/// Every tool MacPulse exposes. Read-only by construction — see the file
/// header. Nothing in this type imports, references or can reach the quit
/// path, the printer link, the clipboard history or the calendar.
final class MCPToolbox {

    /// Held only to read `privacy`, which PrivacyWatcher publishes into it.
    /// The model is never `start()`ed: that would light up the printer
    /// poller, the calendar, the clipboard shelf and the sound watcher,
    /// none of which this server exposes and none of which it should pay
    /// for. The watcher is driven directly instead.
    private let model: IslandModel
    /// Routing-table reads happen here, never on main — same discipline as
    /// TunnelWatcher and --tunnel-probe.
    private let tunnelQueue = DispatchQueue(label: "com.local.macpulse.mcp.tunnel", qos: .utility)

    /// How long a tool will wait for the engine to produce a snapshot with
    /// derivative (per-second) values in it. Rates need TWO samples, so a
    /// call that lands in the first second after spawn has nothing to
    /// divide yet. The engine ticks at 1 Hz; six seconds is five chances.
    private static let warmupTimeout: TimeInterval = 6

    static let toolNames = [
        "memory_pressure", "compressor_churn", "top_memory_apps",
        "machine_snapshot", "capture_holders", "network_path"
    ]

    init(model: IslandModel) {
        self.model = model
    }

    // MARK: Listing

    func listing() -> MCPValue {
        .array([
            tool(name: "memory_pressure",
                 title: "Kernel memory pressure",
                 description: """
                 The kernel's own memory-pressure verdict, plus the used/total/swap figures \
                 that belong beside it.

                 READ THIS INSTEAD OF FREE RAM. On macOS free RAM is NOT the signal and never \
                 was: the VM system deliberately drives free memory towards zero by filling it \
                 with file cache and compressed pages, so "only 180 MB free" is the normal, \
                 healthy state of a machine that is working properly, and reporting it as a \
                 problem is the single most common way to misdiagnose a Mac. The signal is \
                 kern.memorystatus_vm_pressure_level — the value the kernel itself makes jetsam \
                 decisions on: 1 = normal, 2 = warning, 4 = critical (there is no 3).

                 Returns the level and its label, used/total/free bytes, the wired and \
                 compressed-pool sizes, the app-versus-cache split, the achieved compression \
                 ratio, and swap used/total. Anything that could not be measured is null, never 0.
                 """,
                 schema: Self.schema([])),

            tool(name: "compressor_churn",
                 title: "VM compressor churn (the 'feels slow' signal)",
                 description: """
                 Compressions and decompressions per second, in pages and MB/s, with min, \
                 median and peak over a window of MacPulse's rolling history so you can tell a \
                 momentary spike from sustained churn.

                 THIS IS THE METRIC NO SHIPPING TOOL DISPLAYS, and on an 8 GB Apple Silicon \
                 machine it is the real explanation for "it feels slow". When memory runs short \
                 macOS does not swap first — it COMPRESSES: pages stay in RAM, and every \
                 subsequent touch of one costs a synchronous decompression on the faulting \
                 thread. The machine is then spending its time unpacking its own memory. It \
                 never touches the disk, so disk I/O is flat; the work is charged to whichever \
                 thread faulted, so CPU looks merely busy; and Activity Monitor has no column \
                 for it. Sustained decompression above roughly 50 MB/s is the threshold where a \
                 user starts calling the machine slow.

                 If the complaint is "slow" and CPU and disk look fine, look here before \
                 anywhere else. Arguments: window_seconds (1-60, default 10).
                 """,
                 schema: Self.schema([
                    ("window_seconds", .object([
                        ("type", .string("integer")),
                        ("description", .string("Seconds of rolling history to summarise (1-60, default 10).")),
                        ("minimum", .int(1)), ("maximum", .int(60)), ("default", .int(10))
                    ]))
                 ])),

            tool(name: "top_memory_apps",
                 title: "Top apps by phys_footprint",
                 description: """
                 Which apps are actually holding the memory, largest first, grouped by \
                 RESPONSIBLE APP — so an Electron app's six helper processes are one row \
                 naming the app, not six rows naming helpers.

                 The number is ri_phys_footprint: the kernel ledger jetsam kills on, and the \
                 same one Activity Monitor's "Memory" column and top's MEM show. RSS IS NOT \
                 THIS NUMBER and using it will mislead you badly — measured on this machine, \
                 Telegram reported 44 MB resident against 1780 MB phys_footprint, a 40x \
                 discrepancy, because RSS excludes compressed and IOKit/Metal pages, which on \
                 a pressured machine is most of what an app is holding.

                 COVERAGE CEILING: unprivileged, only the CURRENT USER'S processes can be \
                 introspected — measured 258 of 442 PIDs on this machine. The response reports \
                 both counts. Present this as "your apps", never as a whole-system process list.

                 Each row carries pid, the member pids folded into it, footprint, peak \
                 footprint, CPU percent of one core, disk write rate, and \
                 is_quittable_application — which is a FACT about the process (macOS considers \
                 it a real application), not an offer. Nothing in this server can quit, kill or \
                 signal anything. Arguments: limit (1-40, default 10).
                 """,
                 schema: Self.schema([
                    ("limit", .object([
                        ("type", .string("integer")),
                        ("description", .string("How many rows to return (1-40, default 10).")),
                        ("minimum", .int(1)), ("maximum", .int(40)), ("default", .int(10))
                    ]))
                 ])),

            tool(name: "machine_snapshot",
                 title: "Whole-machine reading",
                 description: """
                 One complete reading of everything MacPulse measures, for when the complaint \
                 is vague ("it's slow", "the fan is loud", "the battery is going"):

                 CPU per cluster with P-cores and E-cores separated (and per-core, and load \
                 averages) · power in watts from IOReport per domain plus whole-machine, \
                 adapter and battery draw from the SMC · temperatures per sensor family · \
                 thermal pressure state and low-power mode · GPU utilization · battery charge, \
                 health, cycles and current · disk capacity and system-wide I/O · network per \
                 interface · memory and compressor churn · the top apps by footprint.

                 Every value that could not be measured on this hardware is null, NEVER 0. A \
                 present 0.0 is a real measurement — the ANE genuinely idles at exactly 0 W. \
                 The measurement_availability block says which sources are live, so an absent \
                 metric can be told apart from a broken one.
                 """,
                 schema: Self.schema([])),

            tool(name: "capture_holders",
                 title: "Microphone and camera holders",
                 description: """
                 Who is holding the microphone and the camera right now.

                 The MICROPHONE answer is attributed. macOS 14+ exposes an unprivileged \
                 CoreAudio process-object list, so this names the actual apps with a live input \
                 stream, with helper processes mapped back to their responsible app — it says \
                 "Telegram", not "Telegram Helper (Renderer)". No TCC grant and no entitlement \
                 is involved.

                 The CAMERA answer is DEVICE-LEVEL ONLY and deliberately names no app. There is \
                 no unprivileged per-process camera API on macOS: cameras are IOKit user \
                 clients with no /dev nodes, the system log redacts every identifying field, \
                 and the one route that does name camera apps needs an Accessibility grant, \
                 visibly flashes Control Center open, and merges microphone and camera into a \
                 single list so it cannot say which app uses which sensor. Showing a possibly \
                 wrong name for a privacy question is worse than showing none, so this reports \
                 which DEVICE is running (built-in versus Continuity Camera) and claims nothing \
                 about which app opened it.
                 """,
                 schema: Self.schema([])),

            tool(name: "network_path",
                 title: "Which tunnel actually carries the traffic",
                 description: """
                 Which interface is really carrying this machine's traffic to the public \
                 internet, derived from the kernel routing table (PF_ROUTE RTM_GET — the same \
                 query route(8) makes; no packet is sent to anything).

                 THE DEFAULT ROUTE IS OFTEN A DECOY. A split-tunnel VPN installs more-specific \
                 routes — 0.0.0.0/1 plus 128.0.0.0/1, or per-destination splits — while \
                 0.0.0.0/0 still points at en0. Every check that reads the default route, which \
                 is most of them, then names the wrong interface and reports "not on the VPN" \
                 while every packet is in fact tunnelled. This resolves real public \
                 destinations instead, and reports the carrier and the default-route interface \
                 SEPARATELY along with whether they differ.

                 Also reported: every tunnel-shaped interface that is up (an addressless utun \
                 is NOT evidence of a VPN — macOS keeps several permanently), and per-tool \
                 state with the reason for each verdict, including "cannot determine", which is \
                 a real answer here and not a failure. Caveats the response states for itself: \
                 IPv4 routes only, and a fake-ip gateway such as 198.18.0.1 is not a real peer \
                 and must never be presented as an exit IP.
                 """,
                 schema: Self.schema([]))
        ])
    }

    /// Every tool is annotated read-only, non-destructive and closed-world.
    /// The annotations are advisory in the specification; here they are also
    /// true, and structurally so.
    private func tool(name: String, title: String, description: String, schema: MCPValue) -> MCPValue {
        .object([
            ("name", .string(name)),
            ("title", .string(title)),
            ("description", .string(description)),
            ("inputSchema", schema),
            ("annotations", .object([
                ("title", .string(title)),
                ("readOnlyHint", .bool(true)),
                ("destructiveHint", .bool(false)),
                ("idempotentHint", .bool(true)),
                ("openWorldHint", .bool(false))
            ]))
        ])
    }

    private static func schema(_ properties: [(String, MCPValue)]) -> MCPValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("additionalProperties", .bool(false))
        ])
    }

    // MARK: Calling

    func call(name: String, arguments: [String: Any]) throws -> MCPValue {
        do {
            switch name {
            case "memory_pressure":
                try rejectUnknownArguments(arguments, allowed: [], tool: name)
                return result(try memoryPressure())
            case "compressor_churn":
                try rejectUnknownArguments(arguments, allowed: ["window_seconds"], tool: name)
                let window = try intArgument(arguments, "window_seconds", default: 10, range: 1...60)
                return result(try compressorChurn(windowSeconds: window))
            case "top_memory_apps":
                try rejectUnknownArguments(arguments, allowed: ["limit"], tool: name)
                let limit = try intArgument(arguments, "limit", default: 10, range: 1...40)
                return result(try topMemoryApps(limit: limit))
            case "machine_snapshot":
                try rejectUnknownArguments(arguments, allowed: [], tool: name)
                return result(try machineSnapshot())
            case "capture_holders":
                try rejectUnknownArguments(arguments, allowed: [], tool: name)
                return result(try captureHolders())
            case "network_path":
                try rejectUnknownArguments(arguments, allowed: [], tool: name)
                return result(try networkPath())
            default:
                throw MCPRPCError.invalidParams(
                    "Unknown tool \"\(name)\". This server exposes: "
                    + Self.toolNames.joined(separator: ", "))
            }
        } catch let failure as MCPToolFailure {
            mcpLog("\(name) could not measure: \(failure.message)")
            var fields: [(String, MCPValue)] = [
                ("tool", .string(name)),
                ("error", .string(failure.message))
            ]
            if let detail = failure.detail { fields.append(("detail", detail)) }
            return result(.object(fields), isError: true)
        }
    }

    /// The MCP tool-result envelope. The same payload goes out twice on
    /// purpose: `structuredContent` for a client that can use JSON, and a
    /// pretty-printed copy in `content` for a model that only ever sees the
    /// text block. No `outputSchema` is declared, so no client is obliged to
    /// validate the structured half.
    private func result(_ payload: MCPValue, isError: Bool = false) -> MCPValue {
        .object([
            ("content", .array([
                .object([("type", .string("text")),
                         ("text", .string(payload.rendered(pretty: true)))])
            ])),
            ("structuredContent", payload),
            ("isError", .bool(isError))
        ])
    }

    // MARK: Argument validation

    private func rejectUnknownArguments(_ arguments: [String: Any],
                                        allowed: Set<String>,
                                        tool: String) throws {
        let unknown = Set(arguments.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw MCPRPCError.invalidParams(
                "\(tool) does not accept " + unknown.map { "\"\($0)\"" }.joined(separator: ", ")
                + (allowed.isEmpty ? " — it takes no arguments"
                                   : " — accepted: " + allowed.sorted().joined(separator: ", ")))
        }
    }

    private func intArgument(_ arguments: [String: Any], _ key: String,
                             default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = arguments[key], !(raw is NSNull) else { return fallback }
        guard let value = MCPJSONIn.int(raw) else {
            throw MCPRPCError.invalidParams("\"\(key)\" must be an integer")
        }
        guard range.contains(value) else {
            throw MCPRPCError.invalidParams(
                "\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound), got \(value)")
        }
        return value
    }
}

// MARK: - Tool implementations
//
// Every number below comes from MetricsEngine, the samplers it owns, or
// the two watchers this server drives directly. NOTHING here measures
// anything itself: no new sysctl, no new IOKit call, no second opinion
// about what "used memory" means. If a value looks wrong, it is wrong in
// the island too, and it gets fixed in the sampler.

extension MCPToolbox {

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 1 MB = 1048576 bytes throughout, matching what Activity Monitor and
    /// MacPulse's own UI show. Stated in every payload that uses it, because
    /// a factor of 1.048576 in a "180 MB/s" figure is exactly the kind of
    /// silent disagreement that makes two tools look like they contradict
    /// each other.
    static let bytesPerMB = 1024.0 * 1024.0

    // MARK: Engine access (main-thread hops)

    private func latestSnapshot() -> MetricsSnapshot? {
        DispatchQueue.main.sync { MetricsEngine.shared.latest }
    }

    private func snapshotHistory() -> [MetricsSnapshot] {
        DispatchQueue.main.sync { MetricsEngine.shared.history }
    }

    /// The most recent snapshot, optionally waiting for one that carries
    /// derivative values.
    ///
    /// Rates need two samples, so a call that lands in the first second
    /// after the client spawned us has nothing to divide yet. Rather than
    /// return zeros — which an agent would read as "the machine is idle",
    /// the exact false negative this whole engine is built to avoid — we
    /// wait up to `warmupTimeout` and then return what we have, with the
    /// payload saying plainly that the rates are not there yet.
    private func snapshot(requiringRates: Bool) throws -> MetricsSnapshot {
        let deadline = Date().addingTimeInterval(Self.warmupTimeout)
        var newest: MetricsSnapshot?
        while true {
            if let candidate = latestSnapshot() {
                newest = candidate
                if !requiringRates || candidate.memory?.rates != nil { return candidate }
            }
            if Date() >= deadline { break }
            usleep(50_000)
        }
        if let newest { return newest }
        throw MCPToolFailure(
            message: "MetricsEngine produced no snapshot within \(Int(Self.warmupTimeout))s",
            detail: .string("host_statistics64 and the CPU sampler both failed, or the sampling "
                            + "queue never ran. Nothing here can be reported honestly."))
    }

    private func meta(_ snapshot: MetricsSnapshot) -> [(String, MCPValue)] {
        [
            ("sampled_at", .string(Self.iso8601.string(from: snapshot.date))),
            ("sample_interval_seconds", .num(snapshot.interval, 3)),
            ("sample_cost_ms", .num(snapshot.sampleCostMs, 2)),
            ("freshly_measured_this_tick",
             .strings(snapshot.refreshed.map(\.rawValue).sorted()))
        ]
    }

    // MARK: memory_pressure

    func memoryPressure() throws -> MCPValue {
        let snapshot = try self.snapshot(requiringRates: false)
        guard let memory = snapshot.memory else {
            throw MCPToolFailure(message: "host_statistics64 failed — no memory reading at all")
        }

        var fields: [(String, MCPValue)] = [
            ("pressure", .object([
                ("level", .intOrNull(memory.pressureLevel?.rawValue)),
                ("label", .str(memory.pressureLevel?.label)),
                ("scale", .string("1 = normal, 2 = warning, 4 = critical (there is no 3)")),
                ("source", .string("sysctl kern.memorystatus_vm_pressure_level")),
                ("is_kernel_verdict", .bool(true))
            ])),
            ("pressure_heuristic_fraction", .num(memory.pressureHeuristic, 4)),
            ("total_bytes", .bytes(memory.totalBytes)),
            ("used_bytes", .bytes(memory.usedBytes)),
            ("used_fraction", .num(memory.usedFraction, 4)),
            ("free_bytes", .bytes(memory.freeBytes)),
            ("app_bytes", .bytes(memory.appBytes)),
            ("wired_bytes", .bytes(memory.wiredBytes)),
            ("compressed_pool_bytes", .bytes(memory.compressedBytes)),
            ("cache_bytes", .bytes(memory.cacheBytes)),
            ("active_bytes", .bytes(memory.activeBytes)),
            ("inactive_bytes", .bytes(memory.inactiveBytes)),
            ("speculative_bytes", .bytes(memory.speculativeBytes)),
            ("purgeable_bytes", .bytes(memory.purgeableBytes)),
            ("file_backed_bytes", .bytes(memory.externalBytes)),
            ("uncompressed_in_compressor_bytes", .bytes(memory.uncompressedInCompressorBytes)),
            ("compression_ratio", .num(memory.compressionRatio, 3)),
            ("page_size_bytes", .bytes(memory.pageSize)),
            ("swap", .object([
                ("used_bytes", .bytes(memory.swapUsedBytes)),
                ("total_bytes", .bytes(memory.swapTotalBytes)),
                ("free_bytes", .bytes(memory.swapFreeBytes)),
                ("encrypted", .flag(memory.swapEncrypted))
            ])),
            ("compressor_churn_mb_per_sec",
             .num(memory.rates.map { $0.compressorChurnBytesPerSec / Self.bytesPerMB }, 2)),
            ("notes", .array([
                .string("free_bytes is NOT a health signal on macOS. The VM system keeps free "
                        + "memory near zero on purpose; read pressure.level instead."),
                .string("used_bytes is active + inactive + speculative + wired + compressed "
                        + "- purgeable - file_backed, which is what Activity Monitor shows."),
                .string("pressure_heuristic_fraction is (wired + compressed) / total — a bar "
                        + "height, not Apple's formula. Never label it Activity Monitor's "
                        + "memory pressure; the verdict is pressure.level."),
                .string("Call compressor_churn next: pressure says how tight memory is, churn "
                        + "says whether the machine is currently paying for it in latency.")
            ]))
        ]
        fields.append(contentsOf: meta(snapshot))
        return .object(fields)
    }

    // MARK: compressor_churn

    func compressorChurn(windowSeconds: Int) throws -> MCPValue {
        let snapshot = try self.snapshot(requiringRates: true)
        guard let memory = snapshot.memory else {
            throw MCPToolFailure(message: "host_statistics64 failed — no memory reading at all")
        }
        let rates = memory.rates
        let mb = Self.bytesPerMB

        // The rolling history the island's sparkline draws from. Nothing is
        // re-measured: these are the same snapshots already published.
        let cutoff = Date().addingTimeInterval(-Double(windowSeconds))
        let window = snapshotHistory().filter { $0.date >= cutoff }
        let decompression = window.compactMap { $0.memory?.rates?.decompressionBytesPerSec }
        let compression = window.compactMap { $0.memory?.rates?.compressionBytesPerSec }
        let covered = (window.first?.date).map { Date().timeIntervalSince($0) }

        func summary(_ series: [Double]) -> MCPValue {
            guard !series.isEmpty else { return .null }
            let sorted = series.sorted()
            let median = sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            return .object([
                ("min_mb_per_sec", .num((sorted.first ?? 0) / mb, 2)),
                ("median_mb_per_sec", .num(median / mb, 2)),
                ("mean_mb_per_sec", .num(series.reduce(0, +) / Double(series.count) / mb, 2)),
                ("peak_mb_per_sec", .num((sorted.last ?? 0) / mb, 2))
            ])
        }

        var fields: [(String, MCPValue)] = [
            ("rates_available", .bool(rates != nil)),
            ("instant", .object([
                ("measured_over_seconds", .num(rates?.interval, 3)),
                ("compressions_per_sec", .num(rates?.compressionsPerSec, 0)),
                ("decompressions_per_sec", .num(rates?.decompressionsPerSec, 0)),
                ("compression_mb_per_sec", .num(rates.map { $0.compressionBytesPerSec / mb }, 2)),
                ("decompression_mb_per_sec", .num(rates.map { $0.decompressionBytesPerSec / mb }, 2)),
                ("total_churn_mb_per_sec", .num(rates.map { $0.compressorChurnBytesPerSec / mb }, 2)),
                ("compression_bytes_per_sec", .num(rates?.compressionBytesPerSec, 0)),
                ("decompression_bytes_per_sec", .num(rates?.decompressionBytesPerSec, 0))
            ])),
            ("window", .object([
                ("requested_seconds", .intOrNull(windowSeconds)),
                ("samples", .intOrNull(window.count)),
                ("covered_seconds", .num(covered, 2)),
                ("decompression", summary(decompression)),
                ("compression", summary(compression))
            ])),
            ("swap", .object([
                ("swap_ins_per_sec", .num(rates?.swapInsPerSec, 0)),
                ("swap_outs_per_sec", .num(rates?.swapOutsPerSec, 0)),
                ("swap_in_mb_per_sec", .num(rates.map { $0.swapInBytesPerSec / mb }, 2)),
                ("swap_out_mb_per_sec", .num(rates.map { $0.swapOutBytesPerSec / mb }, 2)),
                ("swap_used_bytes", .bytes(memory.swapUsedBytes)),
                ("swap_total_bytes", .bytes(memory.swapTotalBytes))
            ])),
            ("paging", .object([
                ("page_ins_per_sec", .num(rates?.pageInsPerSec, 0)),
                ("page_outs_per_sec", .num(rates?.pageOutsPerSec, 0)),
                ("page_in_mb_per_sec", .num(rates.map { $0.pageInBytesPerSec / mb }, 2)),
                ("page_out_mb_per_sec", .num(rates.map { $0.pageOutBytesPerSec / mb }, 2)),
                ("faults_per_sec", .num(rates?.faultsPerSec, 0))
            ])),
            ("context", .object([
                ("pressure_level", .intOrNull(memory.pressureLevel?.rawValue)),
                ("pressure_label", .str(memory.pressureLevel?.label)),
                ("compressed_pool_bytes", .bytes(memory.compressedBytes)),
                ("uncompressed_in_compressor_bytes", .bytes(memory.uncompressedInCompressorBytes)),
                ("compression_ratio", .num(memory.compressionRatio, 3)),
                ("page_size_bytes", .bytes(memory.pageSize)),
                ("total_bytes", .bytes(memory.totalBytes))
            ])),
            ("interpretation", .object([
                ("mb_definition", .string("1 MB = 1048576 bytes")),
                ("sustained_decompression_slowness_threshold_mb_per_sec", .double(50)),
                ("why_it_matters", .string(
                    "Decompression is charged to the thread that faulted the page, synchronously, "
                    + "and never touches the disk. So the machine can be unusably slow with flat "
                    + "disk I/O and unremarkable CPU. Judge it on the window's median, not the "
                    + "instant value: a one-second spike is an app launching, a sustained median "
                    + "is the machine thrashing its own RAM.")),
                ("what_to_do", .string(
                    "If the median is high, call top_memory_apps and tell the user which app to "
                    + "close. Do not close it yourself — no tool here can."))
            ]))
        ]
        if rates == nil {
            fields.append(("note", .string(
                "No derivative values yet: rates need two samples and the kernel's counters can "
                + "sit bit-identical for up to a second. Every per-second field is null rather "
                + "than 0, because 0 would read as a quiet machine.")))
        }
        fields.append(contentsOf: meta(snapshot))
        return .object(fields)
    }

    // MARK: top_memory_apps

    func topMemoryApps(limit: Int) throws -> MCPValue {
        let snapshot = try self.snapshot(requiringRates: false)
        guard let processes = snapshot.processes else {
            throw MCPToolFailure(
                message: "The per-app table is unavailable — proc_listpids failed",
                detail: .string("Nothing can be said about which app holds memory."))
        }

        let rows = processes.apps.prefix(limit).enumerated().map { index, app -> MCPValue in
            .object([
                ("rank", .intOrNull(index + 1)),
                ("name", .string(app.name)),
                ("bundle_id", .str(app.bundleIdentifier)),
                ("pid", .intOrNull(app.pid)),
                ("footprint_bytes", .bytes(app.footprintBytes)),
                ("footprint_mb", .num(Double(app.footprintBytes) / Self.bytesPerMB, 1)),
                ("peak_footprint_bytes", .bytes(app.peakFootprintBytes)),
                ("cpu_percent_of_one_core", .num(app.cpuPercent, 2)),
                ("disk_write_bytes_per_sec", .num(app.diskWriteBytesPerSec, 0)),
                ("process_count", .intOrNull(app.memberPIDs.count)),
                ("member_pids", .array(app.memberPIDs.map { .intOrNull($0) })),
                ("is_quittable_application", .bool(app.isApplication))
            ])
        }

        var fields: [(String, MCPValue)] = [
            ("metric", .string("ri_phys_footprint (the kernel ledger jetsam kills on)")),
            ("grouping", .string(processes.helperGroupingAvailable
                ? "responsible app — helper processes folded into the app that spawned them"
                : "per-process — responsibility_get_pid_responsible_for_pid is unavailable, "
                  + "so helpers appear as their own rows")),
            ("helper_grouping_available", .bool(processes.helperGroupingAvailable)),
            ("apps", .array(Array(rows))),
            ("returned", .intOrNull(min(limit, processes.apps.count))),
            ("rows_available", .intOrNull(processes.apps.count)),
            ("total_footprint_bytes_visible", .bytes(processes.totalFootprintBytes)),
            ("total_disk_write_bytes_per_sec", .num(processes.totalDiskWriteBytesPerSec, 0)),
            ("coverage", .object([
                ("pids_reported_by_kernel", .intOrNull(processes.pidCount)),
                ("pids_we_could_read", .intOrNull(processes.introspectedCount)),
                ("scope", .string("this user's processes only — unprivileged introspection "
                                  + "cannot see other users' or the system's")),
                ("present_as", .string("your apps — never as a whole-system process list"))
            ])),
            ("notes", .array([
                .string("RSS is NOT this number. Measured here: Telegram 44 MB resident vs "
                        + "1780 MB phys_footprint, 40x apart, because RSS excludes compressed "
                        + "and IOKit/Metal pages."),
                .string("peak_footprint_bytes is the SUM of each member process's own lifetime "
                        + "high-water mark. That is an upper bound on what the group ever held "
                        + "at one instant, not a measurement of it — members do not peak "
                        + "together. Say 'peak (max of each)', never 'this app once used N'."),
                .string("is_quittable_application is a fact about the process, not an offer. "
                        + "This server is read-only and cannot quit, kill or signal anything.")
            ]))
        ]
        fields.append(contentsOf: meta(snapshot))
        return .object(fields)
    }
}

extension MCPToolbox {

    // MARK: machine_snapshot

    func machineSnapshot() throws -> MCPValue {
        let snapshot = try self.snapshot(requiringRates: false)
        let availability = MetricsEngine.shared.availability()
        let host = HostInfo.shared
        let mb = Self.bytesPerMB

        func load(_ value: CPULoad) -> MCPValue {
            .object([
                ("busy_fraction", .num(value.busy, 4)),
                ("user_fraction", .num(value.user, 4)),
                ("system_fraction", .num(value.system, 4)),
                ("nice_fraction", .num(value.nice, 4)),
                ("idle_fraction", .num(value.idle, 4))
            ])
        }

        var fields: [(String, MCPValue)] = []

        fields.append(("host", .object([
            ("model", .str(host.machineModel)),
            ("logical_cores", .intOrNull(host.logicalCoreCount)),
            ("cluster_layout", .string(availability.clusterLayout)),
            ("physical_memory_bytes", .bytes(host.physicalMemoryBytes)),
            ("page_size_bytes", .bytes(host.pageSize)),
            ("thermal_state", .str(snapshot.thermal?.state.label)),
            ("low_power_mode", .flag(snapshot.thermal?.lowPowerMode))
        ])))

        if let memory = snapshot.memory {
            let rates = memory.rates
            fields.append(("memory", .object([
                ("pressure_level", .intOrNull(memory.pressureLevel?.rawValue)),
                ("pressure_label", .str(memory.pressureLevel?.label)),
                ("used_bytes", .bytes(memory.usedBytes)),
                ("total_bytes", .bytes(memory.totalBytes)),
                ("used_fraction", .num(memory.usedFraction, 4)),
                ("free_bytes", .bytes(memory.freeBytes)),
                ("app_bytes", .bytes(memory.appBytes)),
                ("wired_bytes", .bytes(memory.wiredBytes)),
                ("compressed_pool_bytes", .bytes(memory.compressedBytes)),
                ("cache_bytes", .bytes(memory.cacheBytes)),
                ("compression_ratio", .num(memory.compressionRatio, 3)),
                ("swap_used_bytes", .bytes(memory.swapUsedBytes)),
                ("swap_total_bytes", .bytes(memory.swapTotalBytes)),
                ("compression_mb_per_sec", .num(rates.map { $0.compressionBytesPerSec / mb }, 2)),
                ("decompression_mb_per_sec", .num(rates.map { $0.decompressionBytesPerSec / mb }, 2)),
                ("swap_in_mb_per_sec", .num(rates.map { $0.swapInBytesPerSec / mb }, 2)),
                ("swap_out_mb_per_sec", .num(rates.map { $0.swapOutBytesPerSec / mb }, 2)),
                ("faults_per_sec", .num(rates?.faultsPerSec, 0))
            ])))
        } else {
            fields.append(("memory", .null))
        }

        if let cpu = snapshot.cpu {
            fields.append(("cpu", .object([
                ("measured_over_seconds", .num(cpu.interval, 3)),
                ("overall", load(cpu.overall)),
                ("clusters", .array(cpu.clusters.map { cluster in
                    .object([
                        ("name", .string(cluster.name)),
                        ("kind", .string(cluster.kind.rawValue)),
                        ("core_count", .intOrNull(cluster.coreCount)),
                        ("load", load(cluster.load))
                    ])
                })),
                ("cores", .array(cpu.cores.map { core in
                    core.map { load($0) } ?? .null
                })),
                ("load_average_1m", .num(cpu.loadAverage1, 2)),
                ("load_average_5m", .num(cpu.loadAverage5, 2)),
                ("load_average_15m", .num(cpu.loadAverage15, 2)),
                ("note", .string("A null entry in cores is a core whose tick counters did not "
                                 + "advance — unmeasured, NOT idle. An idle core still "
                                 + "accumulates idle ticks. A cluster that could not be "
                                 + "measured is omitted rather than published as 0% busy."))
            ])))
        } else {
            fields.append(("cpu", .null))
        }

        if let power = snapshot.power {
            fields.append(("power_watts", .object([
                ("cpu", .num(power.cpuWatts, 4)),
                ("gpu", .num(power.gpuWatts, 4)),
                ("ane", .num(power.aneWatts, 4)),
                ("dram", .num(power.dramWatts, 4)),
                ("gpu_sram", .num(power.gpuSRAMWatts, 4)),
                ("package", .num(power.packageWatts, 4)),
                ("system_total", .num(power.systemWatts, 3)),
                ("adapter_in", .num(power.adapterWatts, 3)),
                ("battery", .num(power.batteryWatts, 3)),
                ("note", .string("cpu/gpu/ane/dram come from IOReport's Energy Model; "
                                 + "system_total, adapter_in and battery come from the SMC, "
                                 + "which is the only source for whole-machine draw. A present "
                                 + "0.0 is a real zero — the ANE idles at exactly 0 W."))
            ])))
        } else {
            fields.append(("power_watts", .null))
        }

        if let thermal = snapshot.thermal {
            fields.append(("thermal", .object([
                ("state", .string(thermal.state.label)),
                ("state_level", .intOrNull(thermal.state.rawValue)),
                ("low_power_mode", .bool(thermal.lowPowerMode)),
                ("cpu_peak_celsius", .num(thermal.cpuPeakCelsius, 1)),
                ("cpu_performance_celsius", .num(thermal.cpuPerformanceCelsius, 1)),
                ("cpu_efficiency_celsius", .num(thermal.cpuEfficiencyCelsius, 1)),
                ("gpu_celsius", .num(thermal.gpuCelsius, 1)),
                ("battery_celsius", .num(thermal.batteryCelsius, 1))
            ])))
        } else {
            fields.append(("thermal", .null))
        }

        if let gpu = snapshot.gpu {
            fields.append(("gpu", .object([
                ("name", .str(gpu.name)),
                ("utilization_fraction", .num(gpu.utilization, 4)),
                ("renderer_utilization_fraction", .num(gpu.rendererUtilization, 4)),
                ("tiler_utilization_fraction", .num(gpu.tilerUtilization, 4)),
                ("allocated_bytes", .bytes(gpu.allocatedBytes))
            ])))
        } else {
            fields.append(("gpu", .null))
        }

        if let battery = snapshot.battery {
            fields.append(("battery", .object([
                ("charge_fraction", .num(battery.charge, 4)),
                ("is_charging", .flag(battery.isCharging)),
                ("on_ac_power", .flag(battery.isOnAC)),
                ("seconds_to_empty", .num(battery.timeToEmpty, 0)),
                ("seconds_to_full", .num(battery.timeToFull, 0)),
                ("cycle_count", .intOrNull(battery.cycleCount)),
                ("health_fraction", .num(battery.health, 4)),
                ("design_capacity_mah", .intOrNull(battery.designCapacitymAh)),
                ("current_capacity_mah", .intOrNull(battery.currentCapacitymAh)),
                ("voltage", .num(battery.voltage, 3)),
                ("amperage", .num(battery.amperage, 3)),
                ("temperature_celsius", .num(battery.temperatureCelsius, 1)),
                ("condition", .str(battery.conditionLabel))
            ])))
        } else {
            fields.append(("battery", .null))
        }

        if let disk = snapshot.disk {
            fields.append(("disk", .object([
                ("volume_name", .str(disk.volumeName)),
                ("total_bytes", .bytes(disk.totalBytes)),
                ("available_bytes", .bytes(disk.availableBytes)),
                ("available_opportunistic_bytes", .bytes(disk.availableOpportunisticBytes)),
                ("used_bytes", .bytes(disk.usedBytes)),
                ("read_bytes_per_sec", .num(disk.readBytesPerSec, 0)),
                ("write_bytes_per_sec", .num(disk.writeBytesPerSec, 0)),
                ("note", .string("available_bytes is the figure Finder and About This Mac show "
                                 + "(volumeAvailableCapacityForImportantUsage). It runs a few GB "
                                 + "above statfs f_bavail because of APFS purgeable space; "
                                 + "available_opportunistic_bytes is the conservative one."))
            ])))
        } else {
            fields.append(("disk", .null))
        }

        if let network = snapshot.network {
            fields.append(("network", .object([
                ("bytes_in_per_sec", .num(network.bytesInPerSec, 0)),
                ("bytes_out_per_sec", .num(network.bytesOutPerSec, 0)),
                ("busiest_interface", .str(network.primaryInterface)),
                ("interfaces", .array(network.interfaces.map { interface in
                    .object([
                        ("name", .string(interface.name)),
                        ("bytes_in_per_sec", .num(interface.bytesInPerSec, 0)),
                        ("bytes_out_per_sec", .num(interface.bytesOutPerSec, 0)),
                        ("bytes_in_since_macpulse_started", .bytes(interface.bytesInSinceStart)),
                        ("bytes_out_since_macpulse_started", .bytes(interface.bytesOutSinceStart))
                    ])
                })),
                ("note", .string("Per-second rates are exact. The since-started totals are NOT "
                                 + "since-boot totals: the kernel truncates if_data64 byte "
                                 + "counters to 32 bits (measured 2^32 apart from netstat on "
                                 + "en0), so only deltas accumulated while MacPulse ran are "
                                 + "trustworthy. Call network_path for which interface actually "
                                 + "carries traffic — the busiest one is not necessarily it."))
            ])))
        } else {
            fields.append(("network", .null))
        }

        if let processes = snapshot.processes {
            fields.append(("top_apps_by_footprint", .array(processes.apps.prefix(5).map { app in
                .object([
                    ("name", .string(app.name)),
                    ("pid", .intOrNull(app.pid)),
                    ("footprint_bytes", .bytes(app.footprintBytes)),
                    ("footprint_mb", .num(Double(app.footprintBytes) / mb, 1)),
                    ("cpu_percent_of_one_core", .num(app.cpuPercent, 2))
                ])
            })))
            fields.append(("process_coverage", .object([
                ("pids_reported_by_kernel", .intOrNull(processes.pidCount)),
                ("pids_we_could_read", .intOrNull(processes.introspectedCount)),
                ("scope", .string("this user's processes only"))
            ])))
        } else {
            fields.append(("top_apps_by_footprint", .null))
        }

        fields.append(("measurement_availability", .object([
            ("ioreport_loaded", .bool(availability.ioReportLoaded)),
            ("power_subscription", .bool(availability.powerSubscription)),
            ("smc_open", .bool(availability.smcOpen)),
            ("smc_temperature_sensors", .intOrNull(availability.smcSensorCount)),
            ("gpu_accelerator", .str(availability.gpuAccelerator)),
            ("helper_grouping", .bool(availability.helperGrouping))
        ])))

        fields.append(("notes", .array([
            .string("null means could not be measured on this hardware. It is never a zero. "
                    + "A present 0.0 is a real measurement."),
            .string("freshly_measured_this_tick names the metrics re-read on this exact tick; "
                    + "everything else is the last real measurement carried forward, at most a "
                    + "few seconds old.")
        ])))

        fields.append(contentsOf: meta(snapshot))
        return .object(fields)
    }

    // MARK: capture_holders

    func captureHolders() throws -> MCPValue {
        // CAMERA — synchronous, off the main thread, exactly as
        // PrivacyWatcher's own scan does it on its utility queue.
        let devices = PrivacyWatcher.videoDevices()
        var deviceRows: [MCPValue] = []
        var runningDevices: [String] = []
        for device in devices {
            let isRunning = PrivacyWatcher.cameraIsRunning(device)
            let name = PrivacyWatcher.cameraName(device)
            if isRunning { runningDevices.append(name ?? "camera") }
            deviceRows.append(.object([
                ("device_name", .str(name)),
                ("running", .bool(isRunning))
            ]))
        }

        // MICROPHONE — the watcher's published state for the names (it
        // resolves them through NSRunningApplication, a main-thread API),
        // plus a live read of the CoreAudio process objects as evidence.
        let (state, evidence) = DispatchQueue.main.sync { () -> (PrivacyState, [String]) in
            (model.privacy, PrivacyWatcher.describeHoldersForProbe())
        }
        let micActive = state.micActive || !evidence.isEmpty

        var microphone: [(String, MCPValue)] = [
            ("active", .bool(micActive)),
            ("apps", .strings(state.micApps)),
            ("holder_count_now", .intOrNull(evidence.count)),
            ("attribution", .string("CoreAudio process-object list (macOS 14+), unprivileged, no "
                                    + "TCC grant. Helper processes are mapped back to their "
                                    + "responsible app, so this names Telegram rather than "
                                    + "Telegram Helper (Renderer).")),
            ("apps_source", .string("last published PrivacyState — listener-driven, republished "
                                    + "on every change, not polled")),
            ("process_evidence", .strings(evidence))
        ]
        if micActive, state.micApps.isEmpty {
            microphone.append(("note", .string(
                "The microphone is in use but no app name is attached. Either the default input "
                + "device reports itself running with no process claiming an input stream (the "
                + "device-level fallback, which names nothing by design), or the listeners have "
                + "not completed their first scan yet. process_evidence is read live and is the "
                + "authoritative list for this instant.")))
        }

        return .object([
            ("microphone", .object(microphone)),
            ("camera", .object([
                ("active", .bool(!runningDevices.isEmpty)),
                ("running_devices", .strings(runningDevices)),
                ("devices", .array(deviceRows)),
                ("attribution", .string("DEVICE-LEVEL ONLY — no app name, deliberately. macOS "
                                        + "has no unprivileged per-process camera API: cameras "
                                        + "are IOKit user clients with no /dev nodes, the system "
                                        + "log redacts every identifying field, and the one "
                                        + "route that names camera apps needs an Accessibility "
                                        + "grant, flashes Control Center open, and merges mic "
                                        + "and camera into one list. A possibly-wrong name on a "
                                        + "privacy question is worse than no name."))
            ])),
            ("scope", .string("Sensor state and app names only. No window titles, no file paths, "
                              + "no recorded audio or video, and nothing about what is being "
                              + "said or shown."))
        ])
    }

    // MARK: network_path

    func networkPath() throws -> MCPValue {
        // Cold path on main (LaunchServices), hot path on a serial queue —
        // the same split TunnelWatcher and --tunnel-probe use.
        let installs = DispatchQueue.main.sync { TunnelInstallIndex.shared.refresh() }
        let sampler = TunnelSampler()
        let reading = tunnelQueue.sync { sampler.sample(installed: installs) }
        guard let metrics = reading else {
            throw MCPToolFailure(
                message: "getifaddrs failed — no interface inventory at all",
                detail: .string("Nothing can be said about which interface carries traffic. "
                                + "This is 'we know nothing', not 'there is no tunnel'."))
        }

        let decoy: Bool? = {
            guard let carrier = metrics.carrier, let route = metrics.defaultRouteInterface
            else { return nil }
            return carrier.interface != route
        }()

        let carrierValue: MCPValue = metrics.carrier.map { carrier in
            .object([
                ("interface", .string(carrier.interface)),
                ("interface_index", .intOrNull(carrier.ifIndex)),
                ("gateway", .str(carrier.gateway)),
                ("ipv4", .str(carrier.ipv4)),
                ("mtu", .intOrNull(carrier.mtu)),
                ("is_tunnel", .bool(carrier.isTunnel)),
                ("tool", .str(carrier.tool?.rawValue)),
                ("tool_display_name", .str(carrier.tool?.displayName))
            ])
        } ?? .null

        // Assembled in pieces rather than as one literal. A single nested
        // array-of-tuples this large is the exact shape that makes Swift's
        // type checker give up — "unable to type-check this expression in
        // reasonable time" — and handing it the answer in parts costs
        // nothing and reads no worse.
        var fields: [(String, MCPValue)] = [
            ("carrier", carrierValue),
            ("default_route_interface", .str(metrics.defaultRouteInterface)),
            ("default_route_is_a_decoy", .flag(decoy)),
            ("route_is_split", .bool(metrics.routeIsSplit)),
            ("tunnel_deserves_attention", .flag(metrics.deservesStripSlot)),
            ("has_global_ipv6", .bool(metrics.hasGlobalIPv6)),
            ("carrying_tool", .str(metrics.carryingTool?.displayName)),
            ("sample_cost_ms", .num(metrics.sampleCostMs, 2))
        ]

        let tunnelRows: [MCPValue] = metrics.tunnels.map { tunnel in
            MCPValue.object([
                ("name", .string(tunnel.name)),
                ("ipv4", .str(tunnel.ipv4)),
                ("mtu", .intOrNull(tunnel.mtu)),
                ("is_up", .bool(tunnel.isUp)),
                ("is_running", .bool(tunnel.isRunning)),
                ("signature_tool", .str(tunnel.signature?.rawValue)),
                ("signature_confidence", .str(tunnel.signatureConfidence?.rawValue))
            ])
        }
        fields.append(("tunnel_interfaces", .array(tunnelRows)))
        fields.append(("addressed_tunnel_count", .intOrNull(metrics.addressedTunnels.count)))

        let toolRows: [MCPValue] = metrics.tools.map { status in
            MCPValue.object([
                ("tool", .string(status.tool.rawValue)),
                ("display_name", .string(status.tool.displayName)),
                ("state", .string(status.state.rawValue)),
                ("reason", .string(status.reason)),
                ("attributed_interface", .str(status.attributedInterface)),
                ("app_is_running", .flag(status.isAppRunning)),
                ("installed", .bool(status.bundleURL != nil))
            ])
        }
        fields.append(("tools", .array(toolRows)))

        fields.append(("method", .string(
            "PF_ROUTE RTM_GET against two public addresses in opposite halves of the address "
            + "space. This is the query route(8) makes. No packet is sent to either address — "
            + "they are lookup keys.")))

        let caveats: [MCPValue] = [
            .string("The default route can be a decoy: a split tunnel installs more-specific "
                    + "routes while 0.0.0.0/0 still points at the physical interface. Read "
                    + "carrier.interface, not default_route_interface."),
            .string("IPv4 routes only. If has_global_ipv6 is true, a v6-only tunnel could be "
                    + "carrying traffic this cannot see."),
            .string("A tunnel gateway such as 198.18.0.1 is a fake-ip next hop, not a real peer, "
                    + "and must never be presented as an exit IP."),
            .string("An addressless utun is not evidence of a VPN — macOS keeps several "
                    + "permanently. Only addressed tunnels mean anything."),
            .string("state 'cannotDetermine' is a real answer, not a failure: the tool is "
                    + "installed and the routing evidence does not name it. 'notInstalled' and "
                    + "'installedIdle' are different facts and must not be blurred."),
            .string("No public-IP lookup is performed by this tool and no address is sent "
                    + "anywhere. Only the local routing table is read.")
        ]
        fields.append(("caveats", .array(caveats)))

        var traffic: MCPValue = .null
        if let network = latestSnapshot()?.network {
            let rows: [MCPValue] = network.interfaces.prefix(8).map { interface in
                MCPValue.object([
                    ("name", .string(interface.name)),
                    ("bytes_in_per_sec", .num(interface.bytesInPerSec, 0)),
                    ("bytes_out_per_sec", .num(interface.bytesOutPerSec, 0))
                ])
            }
            traffic = .array(rows)
        }
        fields.append(("interface_traffic", traffic))

        return .object(fields)
    }
}

// MARK: - Entry point

/// `MacPulse --mcp`. Hidden flag, dispatched from main.swift beside the
/// other diagnostic entry points; the shipping app never takes this path
/// and nothing in the UI can reach it.
///
/// Lifetime is the client's: it spawns this process, talks over the pipe,
/// and closes it. On EOF we exit 0. There is no daemon, no port, no
/// registration and nothing left behind.
enum MCPServer {

    static func run(arguments: [String]) -> Never {
        precondition(Thread.isMainThread, "--mcp must be entered from main")

        // ------------------------------------------------------------------
        // 1. TAKE STDOUT AWAY FROM THE REST OF THE PROCESS.
        //
        // fd 1 is the protocol stream and the client is parsing it as JSON.
        // A single print() anywhere in this process — here, in a sampler, in
        // AppKit — would land in the middle of a frame and the client would
        // report a parse error instead of whatever the line said. So: keep a
        // private duplicate of the real stdout for frames, and then point
        // fd 1 at stderr, where a stray line is harmless and still visible.
        //
        // This is why the rule "no print() in this file" is enforceable
        // rather than merely stated: after these two lines it is no longer
        // possible to write to the client's stream by accident.
        // ------------------------------------------------------------------
        fflush(stdout)
        let protocolOut = dup(STDOUT_FILENO)
        guard protocolOut >= 0 else {
            FileHandle.standardError.write(Data("[macpulse-mcp] cannot duplicate stdout\n".utf8))
            exit(70)
        }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stderr, nil, _IONBF, 0)

        // A client that closes the pipe mid-response must give us EPIPE from
        // write(2), not SIGPIPE and a dead process. The writer turns that
        // into a clean exit 0.
        signal(SIGPIPE, SIG_IGN)

        mcpLog("MacPulse MCP server on stdio — read-only, no port, no listener.")

        // ------------------------------------------------------------------
        // 2. PRIVACY, BEFORE ANYTHING STARTS SAMPLING.
        //
        // MetricsEngine.tick() polls ClipboardEngine for the island's
        // clipboard shelf. This process exposes no clipboard tool and never
        // will — but "not exposed" is weaker than "not held", so the engine
        // is paused first. Paused, it still tracks changeCount (so it cannot
        // ingest a backlog) and records NOTHING: no text, no images, no
        // fingerprints, nothing to disk.
        //
        // An --mcp process therefore never holds a single byte of the user's
        // clipboard, which is the only version of this promise that survives
        // someone adding a tool here later without reading the header.
        // ------------------------------------------------------------------
        ClipboardEngine.shared.isPaused = true

        // ------------------------------------------------------------------
        // 3. THE SAMPLERS. Same engine the island runs on — no second
        // measurement path, no reimplementation, no disagreement possible.
        //
        // `.probe` is registered as the detail consumer: it is the engine's
        // existing name for "something is reading every metric", and without
        // it the per-app table, power and temperatures drop to the idle
        // cadence (5-15 s) because nothing on screen can show them. An agent
        // asking what is wrong with the machine is exactly that consumer.
        //
        // COST, MEASURED ON THIS MACHINE: an idle --mcp process with a client
        // attached and no tool calls in flight costs 1.33% of one core over a
        // 30 s window and holds 11 MB RSS. It exists only while the client
        // holds the pipe; on EOF it exits and the cost is zero.
        // ------------------------------------------------------------------
        MetricsEngine.shared.setDetail(.probe, needed: true)
        MetricsEngine.shared.start()

        // The mic/camera rail. The model is a state container only — it is
        // deliberately NOT start()ed, so the printer poller, the calendar,
        // the sound watcher, the clipboard shelf and the pressure notifier
        // never run in this process.
        let model = IslandModel()
        let privacyWatcher = PrivacyWatcher(model: model)
        privacyWatcher.start()

        // ------------------------------------------------------------------
        // 4. The protocol runs on its own thread, because reading stdin is a
        // blocking read(2) and the main thread has to stay free to run the
        // run loop: the metrics engine publishes onto the main queue, and
        // the CoreAudio and CoreMediaIO listeners need a live run loop to
        // deliver property changes. Blocking main on stdin would freeze
        // every measurement this server exists to report.
        // ------------------------------------------------------------------
        let toolbox = MCPToolbox(model: model)
        let session = MCPSession(inputFD: STDIN_FILENO, outputFD: protocolOut, toolbox: toolbox)
        let thread = Thread { session.run() }
        thread.name = "macpulse.mcp.stdio"
        thread.stackSize = 512 * 1024
        thread.start()

        // Never returns: the session thread calls exit() on EOF, on shutdown
        // or when the client's pipe closes. The `until:` form is used rather
        // than a bare run() because a run loop with no attached input source
        // returns immediately, and a server that fell out of its run loop
        // would go silent while still holding the pipe open — the one
        // failure mode worse than crashing.
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(3600))
        }
    }
}
