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

    /// Single process, one row per frame/input — full Mac→iPad pipeline on each row.
    private static let pipelinePid = 1

    /// Canonical phase order so merged rows read left→right as capture→glass.
    private static let phaseOrder: [String: Int] = [
        TracePhase.frameSck: 0,
        TracePhase.frameEncodeWait: 10,
        TracePhase.frameEncode: 20,
        TracePhase.frameTcpSend: 30,
        TracePhase.frameTcpTransit: 40,
        TracePhase.frameRecv: 50,
        TracePhase.frameDisplay: 60,
        TracePhase.framePresent: 70,
        TracePhase.frameDropped: 90,
        TracePhase.inputEmit: 0,
        TracePhase.inputWire: 10,
        TracePhase.inputInject: 20,
    ]

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

        // Merge Mac + iPad spans onto one row per frame / input id.
        var rows: [String: [TraceSpan]] = [:]
        for span in session.allSpans {
            let key = "\(span.rowKind):\(span.rowId)"
            rows[key, default: []].append(span)
        }
        let sortedKeys = rows.keys.sorted { a, b in
            let ap = a.split(separator: ":", maxSplits: 1)
            let bp = b.split(separator: ":", maxSplits: 1)
            guard ap.count == 2, bp.count == 2 else { return a < b }
            if ap[0] != bp[0] { return ap[0] < bp[0] }
            let aid = Int(ap[1]) ?? 0
            let bid = Int(bp[1]) ?? 0
            return aid < bid
        }
        for key in sortedKeys {
            guard var spans = rows[key] else { continue }
            if key.hasPrefix("\(TraceRowKind.frame):") {
                let rowId = Int(key.split(separator: ":").last ?? "") ?? 0
                if let synthetic = synthesizeTransitSpan(rowId: rowId, spans: spans) {
                    spans.append(synthetic)
                }
            }
            let ordered = spans.sorted {
                let lo = phaseOrder[$0.phase] ?? 999
                let ro = phaseOrder[$1.phase] ?? 999
                if lo != ro { return lo < ro }
                return $0.startMs < $1.startMs
            }
            for span in ordered {
                events.append(relativeSlice(span, origin: origin))
            }
        }
        events.append(contentsOf: pipelineThreadNames(session: session))
        return ChromeTraceFile(traceEvents: events, metadata: [
            "opendisplay_session": session.sessionId,
            "origin_ms": String(origin),
            "layout": "pipeline_merged",
        ])
    }

    /// Row → Perfetto thread id. One tid per frame / per input event.
    static func rowThreadId(kind: String, rowId: Int) -> Int {
        switch kind {
        case TraceRowKind.input: return 1_000_000 + rowId
        default: return rowId
        }
    }

    /// When `frame.tcp_tx` was missing (legacy ordering bug), infer from send→recv.
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

    private static func side(for phase: String) -> String {
        switch phase {
        case TracePhase.frameSck, TracePhase.frameEncodeWait, TracePhase.frameEncode,
             TracePhase.frameTcpSend, TracePhase.frameDropped, TracePhase.inputInject:
            return "mac"
        case TracePhase.frameTcpTransit, TracePhase.frameRecv, TracePhase.frameDisplay,
             TracePhase.framePresent, TracePhase.inputEmit:
            return "ipad"
        default:
            return "wire"
        }
    }

    private static func pipelineThreadNames(session: TraceSession) -> [ChromeTraceEvent] {
        var names = Set<String>()
        var out: [ChromeTraceEvent] = []
        func nameEvent(tid: Int, label: String) {
            let key = "\(tid)"
            guard !names.contains(key) else { return }
            names.insert(key)
            out.append(ChromeTraceEvent(
                name: "thread_name", cat: "__metadata", ph: "M", ts: 0, dur: nil,
                pid: pipelinePid, tid: tid, args: ["name": label]))
        }
        var frameIds = Set<Int>()
        var inputIds = Set<Int>()
        for span in session.allSpans {
            if span.rowKind == TraceRowKind.input {
                inputIds.insert(span.rowId)
            } else {
                frameIds.insert(span.rowId)
            }
        }
        for id in frameIds.sorted() {
            nameEvent(tid: rowThreadId(kind: TraceRowKind.frame, rowId: id),
                      label: "frame_\(id)")
        }
        for id in inputIds.sorted() {
            nameEvent(tid: rowThreadId(kind: TraceRowKind.input, rowId: id),
                      label: "input_\(id)")
        }
        nameEvent(tid: 0, label: "OpenDisplay pipeline")
        return out
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
