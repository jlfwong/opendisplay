// Structured pipeline tracing for Perfetto / chrome://tracing visualization.
// Load exported JSON at https://ui.perfetto.dev

import Foundation

enum WireTrace {
    static let traceStart = "traceStart"
    static let traceStop = "traceStop"
    static let traceUpload = "traceUpload"
    static let traceReady = "traceReady"
}

/// One horizontal span on a single row (frame lifecycle or input event).
struct TraceSpan: Codable, Equatable {
    /// "frame" or "input"
    let rowKind: String
    /// frame sequence (Mac-assigned) or input sequence (iPad-assigned)
    let rowId: Int
    /// Phase name — non-overlapping spans within a row share the same rowId.
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
    let notes: [String]

    var allSpans: [TraceSpan] { macSpans + ipadSpans }
}

/// Canonical phase names — keep stable for Perfetto slice filters.
enum TracePhase {
    // Input row (iPad → Mac)
    static let inputEmit = "input.emit"           // iPad: touch/pencil captured
    static let inputWire = "input.wire"           // iPad send → Mac recv complete
    static let inputInject = "input.inject"     // Mac: CGEvent posted

    // Frame row (Mac capture → iPad display)
    static let frameSck = "frame.sck"           // SCK delivered pixel buffer
    static let frameEncodeWait = "frame.enc_wait" // SCK → encode() submit
    static let frameEncode = "frame.encode"     // VTCompressionSession
    static let frameTcpSend = "frame.tcp_send"    // sendFramed → contentProcessed
    static let frameTcpTransit = "frame.tcp_tx"   // Mac send done → iPad recv start
    static let frameRecv = "frame.recv"         // deframe + Annex B parse
    static let frameDisplay = "frame.display"   // CMSampleBuffer → layer enqueue
    static let framePresent = "frame.present"   // Metal presented (optional)
    static let frameDropped = "frame.dropped"   // skipped before encode
}

enum TraceRowKind {
    static let frame = "frame"
    static let input = "input"
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

    /// Convert a merged session to Chrome Trace JSON for ui.perfetto.dev.
    static func chromeTrace(from session: TraceSession) -> ChromeTraceFile {
        chromeTraceRelative(from: session)
    }

    static func chromeTraceRelative(from session: TraceSession) -> ChromeTraceFile {
        let origin = session.allSpans.map(\.startMs).min() ?? session.startedAtMs
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

        for span in session.macSpans {
            events.append(relativeSlice(span, pid: 1, side: "mac", origin: origin))
        }
        for span in session.ipadSpans {
            events.append(relativeSlice(span, pid: 2, side: "ipad", origin: origin))
        }
        events.append(contentsOf: threadNameEvents(session: session))
        return ChromeTraceFile(traceEvents: events, metadata: [
            "opendisplay_session": session.sessionId,
            "origin_ms": String(origin),
        ])
    }

    /// Row → Perfetto thread id. One tid per frame / per input event.
    static func rowThreadId(kind: String, rowId: Int) -> Int {
        switch kind {
        case TraceRowKind.input: return 1_000_000 + rowId
        default: return rowId
        }
    }

    private static func threadNameEvents(session: TraceSession) -> [ChromeTraceEvent] {
        var names = Set<String>()
        var out: [ChromeTraceEvent] = []
        func nameEvent(pid: Int, tid: Int, label: String) {
            let key = "\(pid):\(tid)"
            guard !names.contains(key) else { return }
            names.insert(key)
            out.append(ChromeTraceEvent(
                name: "thread_name", cat: "__metadata", ph: "M", ts: 0, dur: nil,
                pid: pid, tid: tid, args: ["name": label]))
        }
        for span in session.macSpans {
            let label = span.rowKind == TraceRowKind.input
                ? "input_\(span.rowId)" : "frame_\(span.rowId)"
            nameEvent(pid: 1, tid: rowThreadId(kind: span.rowKind, rowId: span.rowId), label: label)
        }
        for span in session.ipadSpans {
            let label = span.rowKind == TraceRowKind.input
                ? "input_\(span.rowId)" : "frame_\(span.rowId)"
            nameEvent(pid: 2, tid: rowThreadId(kind: span.rowKind, rowId: span.rowId), label: label)
        }
        nameEvent(pid: 1, tid: 0, label: "Mac (OpenDisplay)")
        nameEvent(pid: 2, tid: 0, label: "iPad (OpenDisplay)")
        return out
    }

    private static func relativeSlice(_ span: TraceSpan, pid: Int, side: String,
                                      origin: Double) -> ChromeTraceEvent {
        var args = span.meta ?? [:]
        args["side"] = side
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
            pid: pid,
            tid: rowThreadId(kind: span.rowKind, rowId: span.rowId),
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
