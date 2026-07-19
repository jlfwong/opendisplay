#if os(iOS)
import Foundation

/// iPad-side trace hooks: input pipeline + frame recv/display.
/// Spans stream to the Mac incrementally (timestamped); Mac writes trace files.
enum IPadTrace {

    private static let lock = NSLock()
    private static var pendingSessionId: String?
    private static var awaitingUpload = false
    private static var sendTrace: ((_ msg: [String: Any]) -> Void)?
    private static var streamBuffer: [TraceSpan] = []
    private static var streamSeq = 0
    private static var pingSeq = 0
    private static var clockOffsetMs: Double = 0
    private static var displayedFrameIds: Set<Int> = []
    private static var recvStartMsByFrame: [Int: Double] = [:]
    private static var parseDoneMsByFrame: [Int: Double] = [:]
    private static var sendMsByFrame: [Int: Double] = [:]

    private static func resetSessionState() {
        displayedFrameIds.removeAll(keepingCapacity: true)
        recvStartMsByFrame.removeAll(keepingCapacity: true)
        parseDoneMsByFrame.removeAll(keepingCapacity: true)
        sendMsByFrame.removeAll(keepingCapacity: true)
        streamBuffer.removeAll(keepingCapacity: true)
        streamSeq = 0
        pingSeq = 0
        sendTrace = nil
    }

    /// Pen down → input trace until pen up — spans stream to Mac as they are recorded.
    static func beginOnPenDown(clockOffsetMs: Double?, sendTrace startTrace: @escaping (_ msg: [String: Any]) -> Void) {
        guard !TraceCollector.shared.isActive else { return }
        let sessionId = UUID().uuidString
        let now = Date().timeIntervalSince1970 * 1000
        let offset = clockOffsetMs ?? 0
        _ = TraceCollector.shared.start(.init(
            sessionId: sessionId,
            mode: .input,
            maxFrames: 0,
            maxInputs: 0,
            clockOffsetMs: offset,
            startedAtMs: TraceCollector.shared.ipadUnifiedMs(wallMs: now)))
        lock.lock()
        pendingSessionId = sessionId
        awaitingUpload = true
        self.clockOffsetMs = offset
        resetSessionState()
        sendTrace = startTrace
        lock.unlock()
        var msg = TraceWire.startMessage(sessionId: sessionId, mode: .input,
                                         maxFrames: 0, maxInputs: 0,
                                         tDev: now,
                                         tMac: TraceCollector.shared.ipadUnifiedMs(wallMs: now))
        msg["clockOffset"] = offset
        startTrace(msg)
        Log.info("[trace] iPad input session started id=\(sessionId.prefix(8)) — trace on dedicated port")
    }

    static func handleTraceStop(sessionId: String, upload: @escaping (_ msg: [String: Any]) -> Void) {
        lock.lock()
        guard sessionId == pendingSessionId else { lock.unlock(); return }
        lock.unlock()
        finishUpload(send: upload)
    }

    static func setClockOffset(_ ms: Double) {
        TraceCollector.shared.setClockOffset(ms)
        lock.lock()
        clockOffsetMs = ms
        lock.unlock()
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
        let spans = [
            TraceSpan(rowKind: TraceRowKind.input, rowId: inputId, phase: TracePhase.inputOs,
                      startMs: uOs, endMs: uCap, meta: meta),
            TraceSpan(rowKind: TraceRowKind.input, rowId: inputId, phase: TracePhase.inputQueue,
                      startMs: uCap, endMs: uQueue, meta: meta),
            TraceSpan(rowKind: TraceRowKind.input, rowId: inputId, phase: TracePhase.inputSend,
                      startMs: uQueue, endMs: uSend, meta: meta),
        ]
        for span in spans {
            TraceCollector.shared.span(span.phase, rowKind: span.rowKind, rowId: span.rowId,
                                       startMs: span.startMs, endMs: span.endMs,
                                       side: .ipad, meta: span.meta)
        }
        enqueueStream(spans)
    }

    private static func enqueueStream(_ spans: [TraceSpan]) {
        lock.lock()
        streamBuffer.append(contentsOf: spans)
        let shouldFlush = streamBuffer.count >= 6
        lock.unlock()
        if shouldFlush { flushStreamBuffer() }
    }

    private static func flushStreamBuffer(force: Bool = false) {
        lock.lock()
        guard let sessionId = pendingSessionId, let send = sendTrace else {
            lock.unlock()
            return
        }
        guard force || streamBuffer.count >= 6 else { lock.unlock(); return }
        let batch = streamBuffer
        streamBuffer.removeAll(keepingCapacity: true)
        streamSeq += 1
        let seq = streamSeq
        let offset = clockOffsetMs
        lock.unlock()

        guard !batch.isEmpty else { return }
        let tDev = Date().timeIntervalSince1970 * 1000
        let tMac = tDev + offset
        guard let msg = TraceWire.spanBatchMessage(sessionId: sessionId, seq: seq, spans: batch,
                                                   tDev: tDev, tMac: tMac) else {
            Log.info("[trace] span batch encode failed (\(batch.count) spans)")
            return
        }
        send(msg)
    }

    /// Full control-channel RTT (iPad ping sent → pong received), Mac-unified clock.
    static func recordPong(pingTDev: Double, pongTDev: Double, rttMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        lock.lock()
        pingSeq += 1
        let id = pingSeq
        lock.unlock()
        let start = TraceCollector.shared.ipadUnifiedMs(wallMs: pingTDev)
        let end = TraceCollector.shared.ipadUnifiedMs(wallMs: pongTDev)
        let span = TraceSpan(rowKind: TraceRowKind.ping, rowId: id, phase: TracePhase.pingRtt,
                               startMs: start, endMs: end,
                               meta: ["rtt_ms": String(format: "%.2f", rttMs)])
        TraceCollector.shared.span(TracePhase.pingRtt, rowKind: TraceRowKind.ping,
                                   rowId: id, startMs: start, endMs: end,
                                   side: .ipad, meta: span.meta)
        enqueueStream([span])
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
            let span = TraceSpan(rowKind: TraceRowKind.frame, rowId: frameId,
                                 phase: TracePhase.frameTcpTransit,
                                 startMs: sendMs, endMs: ms, meta: nil)
            TraceCollector.shared.span(TracePhase.frameTcpTransit, rowKind: TraceRowKind.frame,
                                       rowId: frameId, startMs: sendMs, endMs: ms, side: .ipad)
            if TraceCollector.shared.tracesInput { enqueueStream([span]) }
        }
    }

    static func frameParseDone(_ frameId: Int) {
        guard TraceCollector.shared.tracesFrames else { return }
        let mid = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let recv = recvStartMsByFrame[frameId] ?? mid
        parseDoneMsByFrame[frameId] = mid
        lock.unlock()
        let span = TraceSpan(rowKind: TraceRowKind.frame, rowId: frameId, phase: TracePhase.frameRecv,
                             startMs: recv, endMs: mid, meta: ["leg": "recv_to_sample"])
        TraceCollector.shared.span(TracePhase.frameRecv, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: recv, endMs: mid, side: .ipad,
                                   meta: span.meta)
        if TraceCollector.shared.tracesInput { enqueueStream([span]) }
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
        let span = TraceSpan(rowKind: TraceRowKind.frame, rowId: frameId, phase: TracePhase.frameDisplay,
                             startMs: start, endMs: end, meta: ["leg": "sample_to_enqueue"])
        TraceCollector.shared.span(TracePhase.frameDisplay, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: start, endMs: end, side: .ipad,
                                   meta: span.meta)
        if TraceCollector.shared.tracesInput { enqueueStream([span]) }
    }

    static func finishUpload(send: @escaping (_ msg: [String: Any]) -> Void) {
        lock.lock()
        guard awaitingUpload, let sessionId = pendingSessionId else {
            lock.unlock()
            return
        }
        awaitingUpload = false
        sendTrace = send
        lock.unlock()

        flushStreamBuffer(force: true)

        let inputRows = TraceCollector.shared.inputRowCount()
        let spanSeq = streamSeq
        let tDev = Date().timeIntervalSince1970 * 1000
        let tMac = TraceCollector.shared.ipadUnifiedMs(wallMs: tDev)
        let endMsg = TraceWire.endMessage(sessionId: sessionId, tDev: tDev, tMac: tMac,
                                          inputRows: inputRows, spanSeq: spanSeq)
        send(endMsg)

        TraceCollector.shared.stop(reason: "traceEnd sent")
        lock.lock()
        resetSessionState()
        pendingSessionId = nil
        lock.unlock()
        Log.info("[trace] sent traceEnd (\(inputRows) input rows, spanSeq=\(spanSeq))")
    }
}
#endif
