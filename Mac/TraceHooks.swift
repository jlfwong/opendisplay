#if os(macOS)
import Foundation

/// Mac-side trace hooks for ScreenCaptureKit → encode → TCP.
/// iPad spans arrive incrementally; Mac checkpoints and writes trace files locally.
enum MacTrace {

    private static var frameSeq = 0
    private static let lock = NSLock()
    private static var sckMsByFrame: [Int: Double] = [:]
    private static var encodeSubmitMsByFrame: [Int: Double] = [:]
    private static var sendStartMsByFrame: [Int: Double] = [:]
    private static var lastSendDoneMs: Double = 0
    private static var pendingPaint: [(inputId: Int, injectEndMs: Double)] = []
    private static var lastCaptureMs: Double = 0
    private static var finalizedSessions: Set<String> = []
    private static var pingSeq = 0
    private static var heartbeatSeq = 0
    private static var finalizeWork: DispatchWorkItem?
    private static let finalizeQueue = DispatchQueue(label: "trace.finalize")
    /// Ingest + disk export — never blocks the input/video queue.
    private static let traceWorkQueue = DispatchQueue(label: "mac.trace.work", qos: .utility)

    static func handleTraceStart(sessionId: String, mode: TraceMode,
                                 maxFrames: Int, maxInputs: Int,
                                 clockOffsetMs: Double = 0) {
        let now = Date().timeIntervalSince1970 * 1000
        UsbmuxLogMonitor.beginSession()
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
        lastCaptureMs = now
        finalizedSessions.remove(sessionId)
        pingSeq = 0
        heartbeatSeq = 0
        pendingWireRecv.removeAll()
        pendingWireSend.removeAll()
        pendingWireFallback.removeAll()
        lock.unlock()
        Log.info("[trace] Mac session started id=\(sessionId) mode=\(mode.rawValue) maxFrames=\(maxFrames) maxInputs=\(maxInputs)")
    }

    static func handleTraceSpan(sessionId: String, seq: Int, spans: [TraceSpan]) {
        guard !finalizedSessions.contains(sessionId) else { return }
        traceWorkQueue.async {
            guard !finalizedSessions.contains(sessionId) else { return }
            _ = TraceCollector.shared.ingestIPadSpans(spans, seq: seq)
        }
    }

    static func handleTraceEnd(sessionId: String, inputRows: Int, spanSeq: Int) {
        traceWorkQueue.async {
            finalize(sessionId: sessionId, reason: "traceEnd rows=\(inputRows) spanSeq=\(spanSeq)")
        }
    }

    /// Legacy bulk upload — still supported.
    static func handleTraceUpload(sessionId: String, spans: [TraceSpan]) {
        traceWorkQueue.async {
            _ = TraceCollector.shared.ingestIPadSpans(spans)
            finalize(sessionId: sessionId, reason: "traceUpload \(spans.count) spans")
        }
    }

    static func pencilPhaseEnded(phase: String?) {
        guard phase == "up", TraceCollector.shared.tracesInput else { return }
        scheduleFinalize(reason: "mac pen up")
    }

    static func noteCaptureMs(_ ms: Double) {
        lock.lock()
        lastCaptureMs = ms
        lock.unlock()
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

    /// Mac recv ping → send pong on :9000 (subset of RTT; see iPad `ping.rtt` for full trip).
    static func recordPingMac(recvMs: Double, pongMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        lock.lock()
        pingSeq += 1
        let id = pingSeq
        lock.unlock()
        TraceCollector.shared.span(TracePhase.pingMac, rowKind: TraceRowKind.ping,
                                   rowId: id, startMs: recvMs, endMs: pongMs, side: .mac)
    }

    /// Round-trip on the dedicated heartbeat usbmux connection (:controlPort+2).
    static func recordHeartbeatRtt(sendMs: Double, recvMs: Double) {
        guard TraceCollector.shared.tracesInput else { return }
        lock.lock()
        heartbeatSeq += 1
        let id = heartbeatSeq
        lock.unlock()
        let rtt = recvMs - sendMs
        TraceCollector.shared.span(TracePhase.heartbeatRtt, rowKind: TraceRowKind.heartbeat,
                                   rowId: id, startMs: sendMs, endMs: recvMs, side: .mac,
                                   meta: ["rtt_ms": String(format: "%.2f", rtt)])
    }

    static func inputWire(inputId: Int, wireStartMs: Double, recvMs: Double,
                          leg: String = "tSend") {
        guard TraceCollector.shared.tracesInput else { return }
        TraceCollector.shared.span(TracePhase.inputWire, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: wireStartMs, endMs: recvMs,
                                   side: .mac, meta: ["leg": leg])
    }

    /// iPad `inpSent` follow-up — contentProcessed time for a prior input message.
    static func noteInputSent(inputId: Int, tSendMs: Double) {
        lock.lock()
        if let recvMs = pendingWireRecv.removeValue(forKey: inputId) {
            pendingWireFallback.removeValue(forKey: inputId)
            lock.unlock()
            inputWire(inputId: inputId, wireStartMs: tSendMs, recvMs: recvMs, leg: "tSend")
            return
        }
        pendingWireSend[inputId] = tSendMs
        lock.unlock()
    }

    /// Recv an input message; finalize `input.wire` when matching `inpSent` arrives.
    static func inputReceived(inputId: Int?, wireFallbackMs: Double?, recvMs: Double) {
        guard TraceCollector.shared.tracesInput, let inputId else { return }
        lock.lock()
        if let tSend = pendingWireSend.removeValue(forKey: inputId) {
            lock.unlock()
            inputWire(inputId: inputId, wireStartMs: tSend, recvMs: recvMs, leg: "tSend")
            return
        }
        pendingWireRecv[inputId] = recvMs
        if let wireFallbackMs { pendingWireFallback[inputId] = wireFallbackMs }
        lock.unlock()
    }

    private static var pendingWireRecv: [Int: Double] = [:]
    private static var pendingWireSend: [Int: Double] = [:]
    private static var pendingWireFallback: [Int: Double] = [:]

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
        noteCaptureMs(captureMs)
        while true {
            lock.lock()
            guard let head = pendingPaint.first else { lock.unlock(); return }
            guard captureMs >= head.injectEndMs else { lock.unlock(); return }
            let item = pendingPaint.removeFirst()
            lock.unlock()
            TraceCollector.shared.span(TracePhase.inputPaint, rowKind: TraceRowKind.input,
                                       rowId: item.inputId, startMs: item.injectEndMs, endMs: captureMs,
                                       side: .mac, meta: ["leg": "inject_to_sck"])
        }
    }

    static func telemetryPrefix(frameId: Int?, captureMs: Int64, sendMs: Int64) -> String {
        if let frameId, TraceCollector.shared.tracesFrames {
            return "{\"cap\":\(captureMs),\"snd\":\(sendMs),\"fid\":\(frameId)}"
        }
        return "{\"cap\":\(captureMs),\"snd\":\(sendMs)}"
    }

    // MARK: - Finalize

    private static func scheduleFinalize(reason: String) {
        finalizeWork?.cancel()
        let sessionId = TraceCollector.shared.currentSessionId
        let work = DispatchWorkItem {
            traceWorkQueue.async {
                finalize(sessionId: sessionId, reason: reason)
            }
        }
        finalizeWork = work
        finalizeQueue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func finalize(sessionId: String, reason: String) {
        lock.lock()
        if finalizedSessions.contains(sessionId) {
            lock.unlock()
            return
        }
        finalizedSessions.insert(sessionId)
        lock.unlock()

        guard TraceCollector.shared.isActive,
              TraceCollector.shared.currentSessionId == sessionId else { return }

        flushPendingPaint(until: paintFlushDeadline())
        flushPendingWire()
        let now = Date().timeIntervalSince1970 * 1000
        let startedAt = TraceCollector.shared.sessionStartedAtMs
        attachUsbmuxLogs(sessionStartedMs: startedAt, endedAtMs: now)
        TraceCollector.shared.appendNote("mac finalized: \(reason)")
        let session = TraceCollector.shared.buildPartialSession(endedAtMs: now)
        do {
            let urls = try TraceFileWriter.write(session: session)
            Log.info("[trace] wrote Perfetto trace → \(urls.perfetto.path)")
            Log.info("[trace] wrote raw session → \(urls.raw.path)")
            Log.info("[trace] open https://ui.perfetto.dev and Load trace from file")
        } catch {
            Log.info("[trace] export failed: \(error)")
        }
        TraceCollector.shared.stop(reason: reason)
    }

    private static func paintFlushDeadline() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970 * 1000
        return max(lastCaptureMs, now)
    }

    private static func flushPendingWire() {
        lock.lock()
        let pending = pendingWireRecv
        let fallbacks = pendingWireFallback
        pendingWireRecv.removeAll()
        pendingWireSend.removeAll()
        pendingWireFallback.removeAll()
        lock.unlock()
        for (inputId, recvMs) in pending {
            guard let start = fallbacks[inputId] else { continue }
            inputWire(inputId: inputId, wireStartMs: start, recvMs: recvMs, leg: "tHandoff")
        }
    }

    private static func attachUsbmuxLogs(sessionStartedMs: Double, endedAtMs: Double) {
        let buffered = UsbmuxLogMonitor.bufferedEventCount()
        let extra = UsbmuxLogMonitor.snapshot(from: sessionStartedMs - 500, to: endedAtMs + 500)
        if !extra.isEmpty {
            TraceCollector.shared.ingestUsbmuxEvents(extra)
            TraceCollector.shared.appendNote("usbmux LogPackets: \(extra.count)/\(buffered) events in session window")
        } else if UsbmuxLogMonitor.logPacketsEnabled {
            TraceCollector.shared.appendNote("usbmux LogPackets enabled but 0/\(buffered) events in session window")
        } else {
            TraceCollector.shared.appendNote("usbmux LogPackets not enabled (scripts/enable-usbmux-logpackets.sh)")
        }
    }

    /// Close any input.paint spans still waiting for SCK at session end.
    private static func flushPendingPaint(until endMs: Double) {
        while true {
            lock.lock()
            guard let item = pendingPaint.first else { lock.unlock(); return }
            pendingPaint.removeFirst()
            lock.unlock()
            TraceCollector.shared.span(TracePhase.inputPaint, rowKind: TraceRowKind.input,
                                       rowId: item.inputId, startMs: item.injectEndMs, endMs: endMs,
                                       side: .mac, meta: ["leg": "inject_to_sck_flush"])
        }
    }
}
#endif
