// Collects TraceSpan rows during a pen-triggered capture session.

import Foundation

final class TraceCollector {

    static let shared = TraceCollector()

    private let lock = NSLock()
    private var active = false
    private var sessionId = ""
    private var startedAtMs: Double = 0
    private var maxFrames = 100
    private var frameBudget = 100
    private var nextInputId = 1
    private var macSpans: [TraceSpan] = []
    private var ipadSpans: [TraceSpan] = []
    private var notes: [String] = []
    private var clockOffsetMs: Double = 0

    /// Per-frame open interval start markers (Mac clock ms).
    private var frameMarks: [Int: [String: Double]] = [:]
    private var inputMarks: [Int: [String: Double]] = [:]

    private init() {}

    // MARK: - Session lifecycle

    struct SessionConfig {
        let sessionId: String
        let maxFrames: Int
        let clockOffsetMs: Double
        let startedAtMs: Double
    }

    @discardableResult
    func start(_ config: SessionConfig) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        active = true
        sessionId = config.sessionId
        maxFrames = config.maxFrames
        frameBudget = config.maxFrames
        clockOffsetMs = config.clockOffsetMs
        startedAtMs = config.startedAtMs
        nextInputId = 1
        macSpans.removeAll(keepingCapacity: true)
        ipadSpans.removeAll(keepingCapacity: true)
        notes.removeAll(keepingCapacity: true)
        frameMarks.removeAll(keepingCapacity: true)
        inputMarks.removeAll(keepingCapacity: true)
        notes.append("session started maxFrames=\(maxFrames)")
        return true
    }

    func stop(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        notes.append("session stopped: \(reason)")
    }

    var currentSessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return sessionId
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    var remainingFrameBudget: Int {
        lock.lock()
        defer { lock.unlock() }
        return frameBudget
    }

    /// Mac: returns false when frame budget exhausted (caller should stop tracing).
    @discardableResult
    func consumeFrameBudget() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, frameBudget > 0 else { return false }
        frameBudget -= 1
        if frameBudget == 0 {
            notes.append("frame budget exhausted")
        }
        return true
    }

    func setClockOffset(_ ms: Double) {
        lock.lock()
        clockOffsetMs = ms
        lock.unlock()
    }

    // MARK: - Span recording

    enum Side { case mac, ipad }

    func mark(_ phase: String, rowKind: String, rowId: Int, timeMs: Double, side: Side) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        var marks = side == .mac ? frameMarks : inputMarks
        if rowKind == TraceRowKind.input { marks = inputMarks }
        else { marks = frameMarks }
        var row = marks[rowId] ?? [:]
        row[phase] = timeMs
        if rowKind == TraceRowKind.input {
            inputMarks[rowId] = row
        } else {
            frameMarks[rowId] = row
        }
    }

    func span(_ phase: String, rowKind: String, rowId: Int,
              startMs: Double, endMs: Double, side: Side,
              meta: [String: String]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let s = TraceSpan(rowKind: rowKind, rowId: rowId, phase: phase,
                          startMs: startMs, endMs: endMs, meta: meta)
        switch side {
        case .mac: macSpans.append(s)
        case .ipad: ipadSpans.append(s)
        }
    }

    /// Close an open mark → now as a span.
    func closeMark(from startPhase: String, to endPhase: String, spanPhase: String,
                   rowKind: String, rowId: Int, endMs: Double, side: Side,
                   meta: [String: String]? = nil) {
        lock.lock()
        let marks = rowKind == TraceRowKind.input ? inputMarks[rowId] : frameMarks[rowId]
        lock.unlock()
        guard let start = marks?[startPhase] else { return }
        span(spanPhase, rowKind: rowKind, rowId: rowId,
             startMs: start, endMs: endMs, side: side, meta: meta)
    }

    func nextInputRowId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextInputId
        nextInputId += 1
        return id
    }

    func macUnifiedMs(wallMs: Double) -> Double { wallMs }

    func ipadUnifiedMs(wallMs: Double) -> Double {
        lock.lock()
        let offset = clockOffsetMs
        lock.unlock()
        return wallMs + offset
    }

    // MARK: - Merge & export

    func macSnapshot() -> [TraceSpan] {
        lock.lock()
        defer { lock.unlock() }
        return macSpans
    }

    func ipadSnapshot() -> [TraceSpan] {
        lock.lock()
        defer { lock.unlock() }
        return ipadSpans
    }

    func merge(ipadSpans uploaded: [TraceSpan], endedAtMs: Double) -> TraceSession {
        lock.lock()
        defer { lock.unlock() }
        active = false
        return TraceSession(
            sessionId: sessionId,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            clockOffsetMs: clockOffsetMs,
            maxFrames: maxFrames,
            macSpans: macSpans,
            ipadSpans: uploaded,
            notes: notes)
    }

    func buildPartialSession(endedAtMs: Double) -> TraceSession {
        lock.lock()
        defer { lock.unlock() }
        return TraceSession(
            sessionId: sessionId,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            clockOffsetMs: clockOffsetMs,
            maxFrames: maxFrames,
            macSpans: macSpans,
            ipadSpans: ipadSpans,
            notes: notes)
    }

    func ingestIPadSpans(_ spans: [TraceSpan]) {
        lock.lock()
        defer { lock.unlock() }
        ipadSpans.append(contentsOf: spans)
    }
}

// MARK: - Wire helpers

enum TraceWire {

    static func startMessage(sessionId: String, maxFrames: Int) -> [String: Any] {
        [
            "type": WireTrace.traceStart,
            "sessionId": sessionId,
            "maxFrames": maxFrames,
            "tDev": Date().timeIntervalSince1970 * 1000,
        ]
    }

    static func uploadMessage(sessionId: String, spans: [TraceSpan]) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(spans),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return [
            "type": WireTrace.traceUpload,
            "sessionId": sessionId,
            "spans": json,
        ]
    }

    static func decodeUpload(_ obj: [String: Any]) -> (sessionId: String, spans: [TraceSpan])? {
        guard let type = obj["type"] as? String, type == WireTrace.traceUpload,
              let sessionId = obj["sessionId"] as? String else { return nil }
        if let json = obj["spans"] as? String,
           let data = json.data(using: .utf8),
           let spans = try? JSONDecoder().decode([TraceSpan].self, from: data) {
            return (sessionId, spans)
        }
        if let arr = obj["spans"] as? [[String: Any]] {
            let data = try? JSONSerialization.data(withJSONObject: arr)
            if let data, let spans = try? JSONDecoder().decode([TraceSpan].self, from: data) {
                return (sessionId, spans)
            }
        }
        return nil
    }
}

enum TraceFileWriter {

    /// Write Perfetto-loadable JSON + raw session JSON under `/tmp`.
    static func write(session: TraceSession) throws -> (perfetto: URL, raw: URL) {
        let stamp = session.sessionId.prefix(8)
        let perfettoURL = URL(fileURLWithPath: "/tmp/opendisplay-trace-\(stamp).perfetto.json")
        let rawURL = URL(fileURLWithPath: "/tmp/opendisplay-trace-\(stamp).session.json")
        try TraceExporter.jsonData(from: session, relativeTimeline: true).write(to: perfettoURL)
        try TraceExporter.sessionJSON(from: session).write(to: rawURL)
        return (perfettoURL, rawURL)
    }
}
