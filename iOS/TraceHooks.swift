#if os(iOS)
import Foundation

/// iPad-side trace hooks: input pipeline + frame recv/display.
/// All mutable state is touched on `PhoneReceiver`'s serial queue unless noted.
enum IPadTrace {

    private static let lock = NSLock()
    private static var pendingSessionId: String?
    private static var awaitingUpload = false
    private static var displayedFrameIds: Set<Int> = []
    private static var recvStartMsByFrame: [Int: Double] = [:]
    private static var parseDoneMsByFrame: [Int: Double] = [:]
    private static var sendMsByFrame: [Int: Double] = [:]

    private static func resetSessionState() {
        displayedFrameIds.removeAll(keepingCapacity: true)
        recvStartMsByFrame.removeAll(keepingCapacity: true)
        parseDoneMsByFrame.removeAll(keepingCapacity: true)
        sendMsByFrame.removeAll(keepingCapacity: true)
    }

    /// Pen down → input trace until pen up (one stroke, up to maxInputs events).
    static func beginOnPenDown(clockOffsetMs: Double?, sendStart: (_ msg: [String: Any]) -> Void) {
        guard !TraceCollector.shared.isActive else { return }
        let sessionId = UUID().uuidString
        let maxInputs = 150
        let now = Date().timeIntervalSince1970 * 1000
        let offset = clockOffsetMs ?? 0
        _ = TraceCollector.shared.start(.init(
            sessionId: sessionId,
            mode: .input,
            maxFrames: 0,
            maxInputs: maxInputs,
            clockOffsetMs: offset,
            startedAtMs: TraceCollector.shared.ipadUnifiedMs(wallMs: now)))
        lock.lock()
        pendingSessionId = sessionId
        awaitingUpload = true
        resetSessionState()
        lock.unlock()
        var msg = TraceWire.startMessage(sessionId: sessionId, mode: .input,
                                         maxFrames: 0, maxInputs: maxInputs)
        if clockOffsetMs != nil { msg["clockOffset"] = offset }
        sendStart(msg)
        Log.info("[trace] iPad input session started id=\(sessionId.prefix(8)) — stroke up to \(maxInputs) events")
    }

    static func handleTraceStop(sessionId: String, upload: @escaping (_ msg: [String: Any]) -> Void) {
        lock.lock()
        guard sessionId == pendingSessionId else { lock.unlock(); return }
        lock.unlock()
        finishUpload(send: upload)
    }

    static func setClockOffset(_ ms: Double) {
        TraceCollector.shared.setClockOffset(ms)
    }

    static func nextInputId() -> Int {
        TraceCollector.shared.nextInputRowId()
    }

    /// Record iPad-side non-overlapping input phases on one Perfetto row.
    static func recordInput(inputId: Int, phase: String,
                            osMs: Double, captureMs: Double,
                            queueMs: Double, sendMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        let uOs = TraceCollector.shared.ipadUnifiedMs(wallMs: osMs)
        let uCap = TraceCollector.shared.ipadUnifiedMs(wallMs: captureMs)
        let uQueue = TraceCollector.shared.ipadUnifiedMs(wallMs: queueMs)
        let uSend = TraceCollector.shared.ipadUnifiedMs(wallMs: sendMs)
        let meta = ["phase": phase]
        TraceCollector.shared.span(TracePhase.inputOs, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: uOs, endMs: uCap, side: .ipad, meta: meta)
        TraceCollector.shared.span(TracePhase.inputQueue, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: uCap, endMs: uQueue, side: .ipad, meta: meta)
        TraceCollector.shared.span(TracePhase.inputSend, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: uQueue, endMs: uSend, side: .ipad, meta: meta)
    }

    static func noteSendMs(_ frameId: Int, sendMs: Double, clockOffsetMs: Double) {
        guard TraceCollector.shared.tracesFrames else { return }
        lock.lock()
        sendMsByFrame[frameId] = sendMs + clockOffsetMs
        lock.unlock()
    }

    static func frameRecvStarted(_ frameId: Int) {
        guard TraceCollector.shared.tracesFrames else { return }
        let ms = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        recvStartMsByFrame[frameId] = ms
        let sendMs = sendMsByFrame[frameId]
        lock.unlock()
        if let sendMs {
            TraceCollector.shared.span(TracePhase.frameTcpTransit, rowKind: TraceRowKind.frame,
                                       rowId: frameId, startMs: sendMs, endMs: ms, side: .ipad)
        }
    }

    static func frameParseDone(_ frameId: Int) {
        guard TraceCollector.shared.tracesFrames else { return }
        let mid = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let recv = recvStartMsByFrame[frameId] ?? mid
        parseDoneMsByFrame[frameId] = mid
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameRecv, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: recv, endMs: mid, side: .ipad,
                                   meta: ["leg": "recv_to_sample"])
    }

    static func frameDisplayed(_ frameId: Int) {
        guard TraceCollector.shared.tracesFrames else { return }
        let end = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let start = parseDoneMsByFrame[frameId] ?? recvStartMsByFrame[frameId] ?? end
        recvStartMsByFrame.removeValue(forKey: frameId)
        parseDoneMsByFrame.removeValue(forKey: frameId)
        sendMsByFrame.removeValue(forKey: frameId)
        displayedFrameIds.insert(frameId)
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameDisplay, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: start, endMs: end, side: .ipad,
                                   meta: ["leg": "sample_to_enqueue"])
    }

    static func finishUpload(send: @escaping (_ msg: [String: Any]) -> Void) {
        lock.lock()
        guard awaitingUpload, let sessionId = pendingSessionId else {
            lock.unlock()
            return
        }
        awaitingUpload = false
        lock.unlock()

        TraceCollector.shared.stop(reason: "uploading spans")
        let spans = TraceCollector.shared.ipadSnapshot()
        let inputRows = Set(spans.filter { $0.rowKind == TraceRowKind.input }.map(\.rowId)).count
        lock.lock()
        resetSessionState()
        pendingSessionId = nil
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            guard var msg = TraceWire.uploadMessage(sessionId: sessionId, spans: spans) else {
                Log.info("[trace] upload encode failed (\(spans.count) spans)")
                return
            }
            if let payload = try? JSONSerialization.data(withJSONObject: msg),
               payload.count > 900_000 {
                Log.info("[trace] upload too large (\(payload.count) bytes) — skipping wire upload")
                return
            }
            msg["inputRows"] = inputRows
            send(msg)
            Log.info("[trace] uploaded \(spans.count) iPad spans (\(inputRows) input rows)")
        }
    }
}
#endif
