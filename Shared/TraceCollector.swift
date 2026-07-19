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
    private var mode: TraceMode = .frame
    private var maxInputs = 0
    private var inputBudget = 0
    private var nextInputId = 1
    private var macSpans: [TraceSpan] = []
    private var ipadSpans: [TraceSpan] = []
    private var notes: [String] = []
    private var clockOffsetMs: Double = 0
    private let maxSpans = 100_000

    /// Per-frame open interval start markers (Mac clock ms).
    private var frameMarks: [Int: [String: Double]] = [:]
    private var inputMarks: [Int: [String: Double]] = [:]

    private init() {}

    // MARK: - Session lifecycle

    struct SessionConfig {
        let sessionId: String
        let mode: TraceMode
        let maxFrames: Int
        let maxInputs: Int
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
        mode = config.mode
        maxFrames = config.maxFrames
        frameBudget = config.maxFrames
        maxInputs = config.maxInputs
        inputBudget = config.maxInputs
        clockOffsetMs = config.clockOffsetMs
        startedAtMs = config.startedAtMs
        nextInputId = 1
        macSpans.removeAll(keepingCapacity: true)
        ipadSpans.removeAll(keepingCapacity: true)
        notes.removeAll(keepingCapacity: true)
        frameMarks.removeAll(keepingCapacity: true)
        inputMarks.removeAll(keepingCapacity: true)
        lastIngestSeq = 0
        ipadSpanKeys.removeAll(keepingCapacity: true)
        notes.append("session started mode=\(mode.rawValue) maxFrames=\(maxFrames) maxInputs=\(maxInputs)")
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

    var tracesFrames: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        // Input sessions (pen down→up) also capture the video pipeline on the frames track.
        if mode == .input { return true }
        return mode == .frame && frameBudget > 0
    }

    var tracesInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && mode == .input
    }

    var traceMode: TraceMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    @discardableResult
    func consumeInputBudget() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, mode == .input, inputBudget > 0 else { return false }
        inputBudget -= 1
        if inputBudget == 0 {
            notes.append("input budget exhausted")
        }
        return true
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
        guard active else { return false }
        if mode == .input { return true }
        guard mode == .frame, frameBudget > 0 else { return false }
        frameBudget -= 1
        if frameBudget == 0 {
            notes.append("frame budget exhausted")
        }
        return true
    }

    func inputRowCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(macSpans.filter { $0.rowKind == TraceRowKind.input }.map(\.rowId))
        let ids2 = Set(ipadSpans.filter { $0.rowKind == TraceRowKind.input }.map(\.rowId))
        return ids.union(ids2).count
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
        guard macSpans.count + ipadSpans.count < maxSpans else { return }
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

    func ingestIPadSpans(_ spans: [TraceSpan], seq: Int = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard active, !spans.isEmpty else { return 0 }
        if seq > 0, seq <= lastIngestSeq { return 0 }
        if seq > 0 { lastIngestSeq = seq }
        var added = 0
        for span in spans {
            guard macSpans.count + ipadSpans.count < maxSpans else { break }
            let key = spanKey(span)
            if ipadSpanKeys.contains(key) { continue }
            ipadSpanKeys.insert(key)
            ipadSpans.append(span)
            added += 1
        }
        return added
    }

    func appendNote(_ note: String) {
        lock.lock()
        notes.append(note)
        lock.unlock()
    }

    private var lastIngestSeq = 0
    private var ipadSpanKeys: Set<String> = []

    private func spanKey(_ span: TraceSpan) -> String {
        "\(span.rowKind)|\(span.rowId)|\(span.phase)"
    }
}

// MARK: - Wire helpers

enum TraceWire {

    static func startMessage(sessionId: String, mode: TraceMode,
                             maxFrames: Int, maxInputs: Int,
                             tDev: Double? = nil, tMac: Double? = nil) -> [String: Any] {
        var msg: [String: Any] = [
            "type": WireTrace.traceStart,
            "sessionId": sessionId,
            "mode": mode.rawValue,
            "maxFrames": maxFrames,
            "maxInputs": maxInputs,
            "tDev": tDev ?? Date().timeIntervalSince1970 * 1000,
        ]
        if let tMac { msg["t"] = tMac }
        return msg
    }

    /// Incremental iPad span batch — Mac persists as spans arrive.
    static func spanBatchMessage(sessionId: String, seq: Int, spans: [TraceSpan],
                                 tDev: Double, tMac: Double?) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(spans),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var msg: [String: Any] = [
            "type": WireTrace.traceSpan,
            "sessionId": sessionId,
            "seq": seq,
            "spans": json,
            "tDev": tDev,
        ]
        if let tMac { msg["t"] = tMac }
        return msg
    }

    static func endMessage(sessionId: String, tDev: Double, tMac: Double?,
                           inputRows: Int, spanSeq: Int) -> [String: Any] {
        var msg: [String: Any] = [
            "type": WireTrace.traceEnd,
            "sessionId": sessionId,
            "tDev": tDev,
            "inputRows": inputRows,
            "spanSeq": spanSeq,
        ]
        if let tMac { msg["t"] = tMac }
        return msg
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

    static func decodeSpanBatch(_ obj: [String: Any]) -> (sessionId: String, seq: Int, spans: [TraceSpan])? {
        guard let type = obj["type"] as? String, type == WireTrace.traceSpan,
              let sessionId = obj["sessionId"] as? String,
              let seq = obj["seq"] as? Int else { return nil }
        if let json = obj["spans"] as? String,
           let data = json.data(using: .utf8),
           let spans = try? JSONDecoder().decode([TraceSpan].self, from: data) {
            return (sessionId, seq, spans)
        }
        if let arr = obj["spans"] as? [[String: Any]] {
            let data = try? JSONSerialization.data(withJSONObject: arr)
            if let data, let spans = try? JSONDecoder().decode([TraceSpan].self, from: data) {
                return (sessionId, seq, spans)
            }
        }
        return nil
    }

    static func decodeEnd(_ obj: [String: Any]) -> (sessionId: String, inputRows: Int, spanSeq: Int)? {
        guard let type = obj["type"] as? String, type == WireTrace.traceEnd,
              let sessionId = obj["sessionId"] as? String else { return nil }
        let inputRows = obj["inputRows"] as? Int ?? 0
        let spanSeq = obj["spanSeq"] as? Int ?? 0
        return (sessionId, inputRows, spanSeq)
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

    /// Write Perfetto-loadable JSON + raw session JSON under `/tmp` (pen up only).
    static func write(session: TraceSession) throws -> (perfetto: URL, raw: URL) {
        let stamp = session.sessionId.prefix(8)
        let perfettoURL = URL(fileURLWithPath: "/tmp/opendisplay-trace-\(stamp).perfetto.json")
        let rawURL = URL(fileURLWithPath: "/tmp/opendisplay-trace-\(stamp).session.json")
        try TraceExporter.jsonData(from: session, relativeTimeline: true).write(to: perfettoURL)
        try TraceExporter.sessionJSON(from: session).write(to: rawURL)
        return (perfettoURL, rawURL)
    }
}
