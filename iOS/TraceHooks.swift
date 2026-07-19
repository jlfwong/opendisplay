#if os(iOS)
import Foundation

/// iPad-side trace hooks: input emit + frame recv/display.
/// All state is touched on `PhoneReceiver`'s serial queue; the lock guards
/// against accidental cross-thread access (main-thread pencil vs video recv).
enum IPadTrace {

    private static let lock = NSLock()
    private static var pendingSessionId: String?
    private static var awaitingUpload = false
    private static var displayedFrameIds: Set<Int> = []
    private static var recvStartMsByFrame: [Int: Double] = [:]
    private static var parseDoneMsByFrame: [Int: Double] = [:]
    private static var sendMsByFrame: [Int: Double] = [:]
    private static var inputEmitStartMs: [Int: Double] = [:]

    private static func resetSessionState() {
        displayedFrameIds.removeAll(keepingCapacity: true)
        recvStartMsByFrame.removeAll(keepingCapacity: true)
        parseDoneMsByFrame.removeAll(keepingCapacity: true)
        sendMsByFrame.removeAll(keepingCapacity: true)
        inputEmitStartMs.removeAll(keepingCapacity: true)
    }

    static func beginOnPenDown(clockOffsetMs: Double?, sendStart: (_ msg: [String: Any]) -> Void) {
        guard !TraceCollector.shared.isActive else { return }
        let sessionId = UUID().uuidString
        let maxFrames = 100
        let now = Date().timeIntervalSince1970 * 1000
        let offset = clockOffsetMs ?? 0
        _ = TraceCollector.shared.start(.init(
            sessionId: sessionId,
            maxFrames: maxFrames,
            clockOffsetMs: offset,
            startedAtMs: TraceCollector.shared.ipadUnifiedMs(wallMs: now)))
        lock.lock()
        pendingSessionId = sessionId
        awaitingUpload = true
        resetSessionState()
        lock.unlock()
        var msg = TraceWire.startMessage(sessionId: sessionId, maxFrames: maxFrames)
        if clockOffsetMs != nil { msg["clockOffset"] = offset }
        sendStart(msg)
        Log.info("[trace] iPad session started id=\(sessionId.prefix(8)) — scribble ~\(maxFrames) frames")
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

    static func noteInputEmit(inputId: Int, devWallMs: Double) {
        guard TraceCollector.shared.isActive else { return }
        let unified = TraceCollector.shared.ipadUnifiedMs(wallMs: devWallMs)
        lock.lock()
        inputEmitStartMs[inputId] = unified
        lock.unlock()
        TraceCollector.shared.mark(TracePhase.inputEmit, rowKind: TraceRowKind.input,
                                   rowId: inputId, timeMs: unified, side: .ipad)
    }

    static func noteInputSent(inputId: Int, devWallMs: Double, wireMacMs: Double?) {
        guard TraceCollector.shared.isActive else { return }
        let end = TraceCollector.shared.ipadUnifiedMs(wallMs: devWallMs)
        lock.lock()
        let start = inputEmitStartMs[inputId] ?? end
        inputEmitStartMs.removeValue(forKey: inputId)
        lock.unlock()
        TraceCollector.shared.span(TracePhase.inputEmit, rowKind: TraceRowKind.input,
                                   rowId: inputId, startMs: start, endMs: end, side: .ipad,
                                   meta: ["leg": "capture_to_send"])
        if let wireMacMs {
            TraceCollector.shared.span(TracePhase.inputWire, rowKind: TraceRowKind.input,
                                       rowId: inputId, startMs: wireMacMs, endMs: wireMacMs,
                                       side: .ipad, meta: ["leg": "wire_start_marker"])
        }
    }

    static func noteSendMs(_ frameId: Int, sendMs: Double, clockOffsetMs: Double) {
        lock.lock()
        sendMsByFrame[frameId] = sendMs + clockOffsetMs
        lock.unlock()
    }

    static func frameRecvStarted(_ frameId: Int) {
        guard TraceCollector.shared.isActive else { return }
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
        guard TraceCollector.shared.isActive else { return }
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
        guard TraceCollector.shared.isActive else { return }
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
        lock.lock()
        let displayed = displayedFrameIds.count
        resetSessionState()
        pendingSessionId = nil
        lock.unlock()

        // JSON encode off the hot receive path — large span batches can take tens of ms.
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
            msg["displayedFrames"] = displayed
            send(msg)
            Log.info("[trace] uploaded \(spans.count) iPad spans (\(displayed) frames)")
        }
    }
}
#endif
