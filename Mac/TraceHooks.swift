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
    private static var pendingPaint: [(inputId: Int, injectEndMs: Double)] = []

    static func handleTraceStart(sessionId: String, mode: TraceMode,
                                 maxFrames: Int, maxInputs: Int,
                                 clockOffsetMs: Double = 0) {
        let now = Date().timeIntervalSince1970 * 1000
        _ = TraceCollector.shared.start(.init(
            sessionId: sessionId,
            mode: mode,
            maxFrames: maxFrames,
            maxInputs: maxInputs,
            clockOffsetMs: clockOffsetMs,
            startedAtMs: now))
        lock.lock()
        frameSeq = 0
        sckMsByFrame.removeAll()
        encodeSubmitMsByFrame.removeAll()
        sendStartMsByFrame.removeAll()
        lastSendDoneMs = 0
        pendingPaint.removeAll()
        lock.unlock()
        Log.info("[trace] Mac session started id=\(sessionId) mode=\(mode.rawValue) maxFrames=\(maxFrames) maxInputs=\(maxInputs)")
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
        guard TraceCollector.shared.tracesFrames else { return nil }
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

    static func inputWire(inputId: Int, wireStartMs: Double, recvMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        TraceCollector.shared.span(TracePhase.inputWire, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: wireStartMs, endMs: recvMs, side: .mac)
    }

    static func inputDispatch(inputId: Int, recvMs: Double, injectStartMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        TraceCollector.shared.span(TracePhase.inputDispatch, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: recvMs, endMs: injectStartMs, side: .mac)
    }

    static func inputInject(inputId: Int, injectStartMs: Double, injectEndMs: Double,
                            phase: String?) {
        guard TraceCollector.shared.tracesInput else { return }
        TraceCollector.shared.span(TracePhase.inputInject, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: injectStartMs, endMs: injectEndMs,
                                   side: .mac, meta: phase.map { ["phase": $0] })
        lock.lock()
        pendingPaint.append((inputId, injectEndMs))
        lock.unlock()
    }

    /// Close input.paint when ScreenCaptureKit delivers a frame after injection.
    static func tryCompletePaint(captureMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        while true {
            lock.lock()
            guard let head = pendingPaint.first else { lock.unlock(); return }
            guard captureMs >= head.injectEndMs else { lock.unlock(); return }
            let item = pendingPaint.removeFirst()
            lock.unlock()
            let end = min(captureMs, item.injectEndMs + 200)
            TraceCollector.shared.span(TracePhase.inputPaint, rowKind: TraceRowKind.input,
                                       rowId: item.inputId, startMs: item.injectEndMs, endMs: end,
                                       side: .mac, meta: ["leg": "inject_to_sck"])
        }
    }

    static func telemetryPrefix(frameId: Int?, captureMs: Int64, sendMs: Int64) -> String {
        if let frameId, TraceCollector.shared.tracesFrames {
            return "{\"cap\":\(captureMs),\"snd\":\(sendMs),\"fid\":\(frameId)}"
        }
        return "{\"cap\":\(captureMs),\"snd\":\(sendMs)}"
    }
}
#endif
