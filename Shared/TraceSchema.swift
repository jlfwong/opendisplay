// Structured pipeline tracing for Perfetto / chrome://tracing visualization.
// Load exported JSON at https://ui.perfetto.dev

import Foundation

enum WireTrace {
    static let traceStart = "traceStart"
    static let traceStop = "traceStop"
    static let traceUpload = "traceUpload"
    static let traceSpan = "traceSpan"
    static let traceEnd = "traceEnd"
    static let traceReady = "traceReady"
}

/// One timed span in a capture session (frame pipeline, input event, or ping).
struct TraceSpan: Codable, Equatable {
    /// "frame", "input", or "ping"
    let rowKind: String
    /// frame sequence (Mac-assigned), input id (iPad-assigned), or ping sample id
    let rowId: Int
    /// Phase name — e.g. `frame.encode`, `input.wire`, `ping.rtt`
    let phase: String
    /// Unified timeline in milliseconds (Mac clock; iPad converts via offset).
    let startMs: Double
    let endMs: Double
    var meta: [String: String]?

    var durationMs: Double { max(0, endMs - startMs) }
}

/// Complete capture session exported for analysis.
struct TraceSession: Codable, Equatable {
    let sessionId: String
    let startedAtMs: Double
    let endedAtMs: Double?
    let clockOffsetMs: Double
    let maxFrames: Int
    let macSpans: [TraceSpan]
    let ipadSpans: [TraceSpan]
    /// Parsed usbmuxd LogPackets lines (Mac wall-clock ms), merged at export.
    var usbmuxEvents: [UsbmuxLogEvent]?
    let notes: [String]

    var allSpans: [TraceSpan] { macSpans + ipadSpans }
}

enum TraceMode: String, Codable {
    case frame
    case input
}

/// Canonical phase names — keep stable for Perfetto slice filters.
enum TracePhase {
    // Input: iPad OS delivery → Mac compositor paint
    static let inputOs = "input.os"               // UIKit delivery → InputCapture emit
    static let inputQueue = "input.queue"         // emit → receiver queue runs
    static let inputSend = "input.send"           // queue → contentProcessed (iPad)
    static let inputWire = "input.wire"           // tSend (socket ack) → Mac recv
    static let inputDispatch = "input.dispatch"   // recv → inject start
    static let inputInject = "input.inject"       // CGEvent post
    static let inputPaint = "input.paint"         // inject → SCK captures change
    // Legacy aliases (older traces)
    static let inputEmit = "input.emit"

    // Frame: Mac capture → iPad display
    static let frameSck = "frame.sck"           // SCK delivered pixel buffer
    static let frameEncodeWait = "frame.enc_wait" // SCK → encode() submit
    static let frameEncode = "frame.encode"     // VTCompressionSession
    static let frameTcpSend = "frame.tcp_send"    // sendFramed → contentProcessed
    static let frameTcpTransit = "frame.tcp_tx"   // Mac send done → iPad recv start
    static let frameRecv = "frame.recv"         // deframe + Annex B parse
    static let frameDisplay = "frame.display"   // CMSampleBuffer → layer enqueue
    static let framePresent = "frame.present"   // Metal presented (optional)
    static let frameDropped = "frame.dropped"   // skipped before encode

    // Ping/pong on control channel (:9000) — Mac-unified timeline
    static let pingRtt = "ping.rtt"             // iPad ping sent → pong received
    static let pingMac = "ping.mac"             // Mac recv ping → send pong

    // Heartbeat on dedicated usbmux connection (controlPort + 2)
    static let heartbeatRtt = "heartbeat.rtt"   // Mac hb sent → hbPong received
    static let heartbeatMac = "heartbeat.mac"   // Mac recv hbPong processing
}

/// One parsed usbmuxd TCP packet log line (LogPackets pref).
struct UsbmuxLogEvent: Codable, Equatable {
    /// Mac wall-clock ms (same basis as trace spans).
    let timeMs: Double
    /// "in" (device→host) or "out" (host→device)
    let direction: String
    let seq: UInt32?
    let ack: UInt32?
    let win: UInt32?
    let len: Int?
    let sport: Int?
    let dport: Int?
    /// Raw log line (truncated) for debugging.
    let raw: String
}

enum TraceRowKind {
    static let frame = "frame"
    static let input = "input"
    static let ping = "ping"
    static let heartbeat = "heartbeat"
    static let usbmux = "usbmux"
}

// MARK: - Chrome Trace Event Format (Perfetto-compatible)

struct ChromeTraceFile: Codable {
    var traceEvents: [ChromeTraceEvent]
    /// Chrome/Perfetto interpret `ts`/`dur` as microseconds — do not set "ms".
    var metadata: [String: String]?
}

struct ChromeTraceEvent: Codable {
    let name: String
    let cat: String
    let ph: String
    let ts: Double
    var dur: Double?
    let pid: Int
    let tid: Int
    var args: [String: String]?
}

enum TraceExporter {

    /// Single process; Mac-unified timeline. Frames + ping on shared tracks;
    /// each input event gets its own Perfetto row (phases left→right on that row).
    private static let pipelinePid = 1

    private enum Track {
        static let frames = 1
        static let ping = 2
        static let heartbeat = 3
        static let usbmux = 4
        /// One tid per input id — avoids stacking thousands of slices on one lane.
        static let inputBase = 1_000_000

        static func tid(for span: TraceSpan) -> Int {
            switch span.rowKind {
            case TraceRowKind.frame: return frames
            case TraceRowKind.ping: return ping
            case TraceRowKind.heartbeat: return heartbeat
            case TraceRowKind.input: return inputBase + span.rowId
            default: return 0
            }
        }

        static func label(for span: TraceSpan) -> String {
            switch span.rowKind {
            case TraceRowKind.frame: return "frames"
            case TraceRowKind.ping: return "ping / pong"
            case TraceRowKind.heartbeat: return "heartbeat (:+2)"
            case TraceRowKind.input: return "input_\(span.rowId)"
            default: return span.rowKind
            }
        }
    }

    /// Phase order within an input row (capture → glass on that event).
    private static let inputPhaseOrder: [String: Int] = [
        TracePhase.inputOs: 0,
        TracePhase.inputEmit: 0,
        TracePhase.inputQueue: 10,
        TracePhase.inputSend: 20,
        TracePhase.inputWire: 30,
        TracePhase.inputDispatch: 40,
        TracePhase.inputInject: 50,
        TracePhase.inputPaint: 60,
    ]

    /// Convert a merged session to Chrome Trace JSON for ui.perfetto.dev.
    static func chromeTrace(from session: TraceSession) -> ChromeTraceFile {
        chromeTraceRelative(from: session)
    }

    static func chromeTraceRelative(from session: TraceSession) -> ChromeTraceFile {
        var spans = session.allSpans
        spans.append(contentsOf: synthesizeMissingTransitSpans(in: spans))
        let origin = minOriginMs(spans: spans, session: session)
        var events: [ChromeTraceEvent] = []
        events.append(ChromeTraceEvent(
            name: "session_start",
            cat: "meta",
            ph: "i",
            ts: 0,
            dur: nil,
            pid: 0,
            tid: 0,
            args: ["sessionId": session.sessionId]))

        events.append(contentsOf: threadNames(for: spans))
        events.append(ChromeTraceEvent(
            name: "thread_name", cat: "__metadata", ph: "M", ts: 0, dur: nil,
            pid: pipelinePid, tid: Track.usbmux, args: ["name": "usbmuxd LogPackets"]))

        let ordered = spans.sorted {
            if $0.rowKind == TraceRowKind.input, $1.rowKind == TraceRowKind.input,
               $0.rowId == $1.rowId {
                let lo = inputPhaseOrder[$0.phase] ?? 999
                let ro = inputPhaseOrder[$1.phase] ?? 999
                if lo != ro { return lo < ro }
            }
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.rowKind != $1.rowKind { return $0.rowKind < $1.rowKind }
            if $0.rowId != $1.rowId { return $0.rowId < $1.rowId }
            return $0.phase < $1.phase
        }
        for span in ordered {
            events.append(relativeSlice(span, origin: origin))
        }
        events.append(contentsOf: usbmuxInstantEvents(session.usbmuxEvents ?? [], origin: origin))

        let inputIds = Set(spans.filter { $0.rowKind == TraceRowKind.input }.map(\.rowId))
        let frameIds = Set(spans.filter { $0.rowKind == TraceRowKind.frame }.map(\.rowId))
        let pingIds = Set(spans.filter { $0.rowKind == TraceRowKind.ping }.map(\.rowId))
        let hbIds = Set(spans.filter { $0.rowKind == TraceRowKind.heartbeat }.map(\.rowId))
        let usbmuxCount = session.usbmuxEvents?.count ?? 0
        var metadata: [String: String] = [
            "opendisplay_session": session.sessionId,
            "origin_ms": String(origin),
            "time_base": "mac_unified_ms",
            "layout": "frames_ping_heartbeat_usbmux + per_input",
        ]
        if !inputIds.isEmpty { metadata["input_events"] = String(inputIds.count) }
        if !frameIds.isEmpty { metadata["frame_events"] = String(frameIds.count) }
        if !pingIds.isEmpty { metadata["ping_samples"] = String(pingIds.count) }
        if !hbIds.isEmpty { metadata["heartbeat_samples"] = String(hbIds.count) }
        if usbmuxCount > 0 { metadata["usbmux_events"] = String(usbmuxCount) }
        return ChromeTraceFile(traceEvents: events, metadata: metadata)
    }

    private static func minOriginMs(spans: [TraceSpan], session: TraceSession) -> Double {
        var candidates = spans.map(\.startMs)
        candidates.append(session.startedAtMs)
        if let usbmux = session.usbmuxEvents, let first = usbmux.map(\.timeMs).min() {
            candidates.append(first)
        }
        return candidates.min() ?? session.startedAtMs
    }

    /// Instant events on the usbmuxd track — wall-clock aligned via the same origin.
    private static func usbmuxInstantEvents(_ events: [UsbmuxLogEvent], origin: Double) -> [ChromeTraceEvent] {
        events.map { ev in
            var args: [String: String] = [
                "dir": ev.direction,
                "raw": String(ev.raw.prefix(120)),
            ]
            if let seq = ev.seq { args["seq"] = String(seq) }
            if let ack = ev.ack { args["ack"] = String(ack) }
            if let win = ev.win { args["win"] = String(win) }
            if let len = ev.len { args["len"] = String(len) }
            if let sport = ev.sport { args["sport"] = String(sport) }
            if let dport = ev.dport { args["dport"] = String(dport) }
            let label = ev.len.map { "usbmux.\(ev.direction) \($0)B" } ?? "usbmux.\(ev.direction)"
            return ChromeTraceEvent(
                name: label,
                cat: TraceRowKind.usbmux,
                ph: "i",
                ts: (ev.timeMs - origin) * 1000,
                dur: nil,
                pid: pipelinePid,
                tid: Track.usbmux,
                args: args)
        }
    }

    /// When `frame.tcp_tx` was missing (legacy ordering bug), infer from send→recv.
    private static func synthesizeMissingTransitSpans(in spans: [TraceSpan]) -> [TraceSpan] {
        var byFrame: [Int: [TraceSpan]] = [:]
        for span in spans where span.rowKind == TraceRowKind.frame {
            byFrame[span.rowId, default: []].append(span)
        }
        var out: [TraceSpan] = []
        for (rowId, group) in byFrame {
            if let synthetic = synthesizeTransitSpan(rowId: rowId, spans: group) {
                out.append(synthetic)
            }
        }
        return out
    }

    private static func synthesizeTransitSpan(rowId: Int, spans: [TraceSpan]) -> TraceSpan? {
        guard !spans.contains(where: { $0.phase == TracePhase.frameTcpTransit }) else { return nil }
        guard let send = spans.first(where: { $0.phase == TracePhase.frameTcpSend }),
              let recv = spans.first(where: { $0.phase == TracePhase.frameRecv }) else { return nil }
        let start = send.endMs
        let end = recv.startMs
        guard end >= start else { return nil }
        return TraceSpan(rowKind: TraceRowKind.frame, rowId: rowId, phase: TracePhase.frameTcpTransit,
                         startMs: start, endMs: end, meta: ["leg": "synthesized"])
    }

    private static func threadNames(for spans: [TraceSpan]) -> [ChromeTraceEvent] {
        var seen = Set<Int>()
        var out: [ChromeTraceEvent] = []
        func name(_ tid: Int, _ label: String) {
            guard !seen.contains(tid) else { return }
            seen.insert(tid)
            out.append(ChromeTraceEvent(
                name: "thread_name", cat: "__metadata", ph: "M", ts: 0, dur: nil,
                pid: pipelinePid, tid: tid, args: ["name": label]))
        }
        name(Track.frames, "frames")
        name(Track.ping, "ping / pong")
        name(Track.heartbeat, "heartbeat (:+2)")
        for id in Set(spans.filter { $0.rowKind == TraceRowKind.input }.map(\.rowId)).sorted() {
            name(Track.inputBase + id, "input_\(id)")
        }
        return out
    }

    private static func side(for phase: String) -> String {
        switch phase {
        case TracePhase.frameSck, TracePhase.frameEncodeWait, TracePhase.frameEncode,
             TracePhase.frameTcpSend, TracePhase.frameDropped,
             TracePhase.inputDispatch, TracePhase.inputInject, TracePhase.inputPaint,
             TracePhase.pingMac:
            return "mac"
        case TracePhase.frameTcpTransit, TracePhase.frameRecv, TracePhase.frameDisplay,
             TracePhase.framePresent,
             TracePhase.inputOs, TracePhase.inputEmit, TracePhase.inputQueue, TracePhase.inputSend,
             TracePhase.pingRtt:
            return "ipad"
        case TracePhase.inputWire:
            return "wire"
        case TracePhase.heartbeatRtt:
            return "mac"
        default:
            return "wire"
        }
    }

    private static func relativeSlice(_ span: TraceSpan, origin: Double) -> ChromeTraceEvent {
        var args = span.meta ?? [:]
        args["side"] = side(for: span.phase)
        args["rowId"] = String(span.rowId)
        args["duration_ms"] = String(format: "%.3f", span.durationMs)
        // Chrome trace `ts`/`dur` are microseconds; our spans are recorded in ms.
        let tsUs = (span.startMs - origin) * 1000
        let durUs = span.durationMs * 1000
        return ChromeTraceEvent(
            name: span.phase,
            cat: span.rowKind,
            ph: "X",
            ts: tsUs,
            dur: durUs,
            pid: pipelinePid,
            tid: Track.tid(for: span),
            args: args)
    }

    static func jsonData(from session: TraceSession, relativeTimeline: Bool = true) throws -> Data {
        let file = relativeTimeline ? chromeTraceRelative(from: session) : chromeTrace(from: session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func sessionJSON(from session: TraceSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }
}
