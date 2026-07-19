#if os(macOS)
import Foundation

/// Mac-side trace hooks for ScreenCaptureKit → encode → TCP.
enum MacTrace {

    private static var frameSeq = 0
    private static let lock = NSLock()
    private static var sckMsByFrame: [Int: Double] = [:]
    private static var encodeSubmitMsByFrame: [Int: Double] = [:]
    private static var sendStartMsByFrame: [Int: Double] = [:]
    private static var lastSendDoneMs: Double = 0

    static func handleTraceStart(sessionId: String, maxFrames: Int, clockOffsetMs: Double = 0) {
        let now = Date().timeIntervalSince1970 * 1000
        _ = TraceCollector.shared.start(.init(
            sessionId: sessionId,
            maxFrames: maxFrames,
            clockOffsetMs: clockOffsetMs,
            startedAtMs: now))
        lock.lock()
        frameSeq = 0
        sckMsByFrame.removeAll()
        encodeSubmitMsByFrame.removeAll()
        sendStartMsByFrame.removeAll()
        lastSendDoneMs = 0
        lock.unlock()
        Log.info("[trace] Mac session started id=\(sessionId) maxFrames=\(maxFrames)")
    }

    static func handleTraceUpload(sessionId: String, spans: [TraceSpan]) {
        let now = Date().timeIntervalSince1970 * 1000
        TraceCollector.shared.ingestIPadSpans(spans)
        let session = TraceCollector.shared.buildPartialSession(endedAtMs: now)
        guard session.sessionId == sessionId else {
            Log.info("[trace] upload session mismatch got=\(sessionId) have=\(session.sessionId)")
            return
        }
        do {
            let urls = try TraceFileWriter.write(session: session)
            Log.info("[trace] wrote Perfetto trace → \(urls.perfetto.path)")
            Log.info("[trace] wrote raw session → \(urls.raw.path)")
            Log.info("[trace] open https://ui.perfetto.dev and Load trace from file")
        } catch {
            Log.info("[trace] export failed: \(error)")
        }
        TraceCollector.shared.stop(reason: "upload merged")
    }

    /// Returns frame id if traced; nil if inactive or budget exhausted (sends traceStop).
    static func frameCaptured(notify: (_ json: String) -> Void) -> Int? {
        guard TraceCollector.shared.isActive else { return nil }
        guard TraceCollector.shared.consumeFrameBudget() else {
            let sid = TraceCollector.shared.currentSessionId
            TraceCollector.shared.stop(reason: "frame budget exhausted on Mac")
            notify("{\"type\":\"\(WireTrace.traceStop)\",\"sessionId\":\"\(sid)\",\"reason\":\"frame_budget\"}")
            Log.info("[trace] Mac frame budget exhausted — sent traceStop")
            return nil
        }
        lock.lock()
        frameSeq += 1
        let id = frameSeq
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        sckMsByFrame[id] = ms
        lock.unlock()
        TraceCollector.shared.mark(TracePhase.frameSck, rowKind: TraceRowKind.frame,
                                   rowId: id, timeMs: ms, side: .mac)
        return id
    }

    static func frameDropped(_ frameId: Int, reason: String) {
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let start = sckMsByFrame[frameId] ?? ms
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameDropped, rowKind: TraceRowKind.frame,
                                 rowId: frameId, startMs: start, endMs: ms, side: .mac,
                                 meta: ["reason": reason])
    }

    static func encodeSubmitted(_ frameId: Int) {
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let sck = sckMsByFrame[frameId] ?? ms
        encodeSubmitMsByFrame[frameId] = ms
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameEncodeWait, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: sck, endMs: ms, side: .mac)
    }

    static func encodeFinished(_ frameId: Int) {
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let submit = encodeSubmitMsByFrame[frameId] ?? ms
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameEncode, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: submit, endMs: ms, side: .mac)
    }

    static func sendStarted(_ frameId: Int) {
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        sendStartMsByFrame[frameId] = ms
        lock.unlock()
    }

    static func sendFinished(_ frameId: Int) {
        let ms = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        lock.lock()
        let start = sendStartMsByFrame[frameId] ?? ms
        lastSendDoneMs = ms
        lock.unlock()
        TraceCollector.shared.span(TracePhase.frameTcpSend, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: start, endMs: ms, side: .mac)
    }

    static func lastSendDoneUnifiedMs() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return lastSendDoneMs
    }

    static func inputReceived(inputId: Int, wireStartMs: Double) {
        let recvMs = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        TraceCollector.shared.span(TracePhase.inputWire, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: wireStartMs, endMs: recvMs, side: .mac,
                                   meta: ["leg": "wire"])
    }

    static func inputInjected(inputId: Int, injectStartMs: Double) {
        let endMs = TraceCollector.shared.macUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        TraceCollector.shared.span(TracePhase.inputInject, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: injectStartMs, endMs: endMs, side: .mac)
    }

    static func telemetryPrefix(frameId: Int?, captureMs: Int64, sendMs: Int64) -> String {
        if let frameId, TraceCollector.shared.isActive {
            return "{\"cap\":\(captureMs),\"snd\":\(sendMs),\"fid\":\(frameId)}"
        }
        return "{\"cap\":\(captureMs),\"snd\":\(sendMs)}"
    }
}
#endif
