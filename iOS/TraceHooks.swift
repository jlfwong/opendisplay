#if os(iOS)
import Foundation

/// iPad-side trace hooks: input emit + frame recv/display.
enum IPadTrace {

    private static var pendingSessionId: String?
    private static var awaitingUpload = false
    private static var displayedFrameIds: Set<Int> = []
    private static var recvStartMsByFrame: [Int: Double] = [:]
    private static var parseDoneMsByFrame: [Int: Double] = [:]
    private static var sendMsByFrame: [Int: Double] = [:]
    private static var inputEmitStartMs: [Int: Double] = [:]

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
        pendingSessionId = sessionId
        awaitingUpload = true
        displayedFrameIds.removeAll()
        recvStartMsByFrame.removeAll()
        sendMsByFrame.removeAll()
        inputEmitStartMs.removeAll()
        var msg = TraceWire.startMessage(sessionId: sessionId, maxFrames: maxFrames)
        if clockOffsetMs != nil { msg["clockOffset"] = offset }
        sendStart(msg)
        Log.info("[trace] iPad session started id=\(sessionId.prefix(8)) — scribble ~\(maxFrames) frames")
    }

    static func handleTraceStop(sessionId: String, upload: (_ msg: [String: Any]) -> Void) {
        guard sessionId == pendingSessionId else { return }
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
        inputEmitStartMs[inputId] = unified
        TraceCollector.shared.mark(TracePhase.inputEmit, rowKind: TraceRowKind.input,
                                   rowId: inputId, timeMs: unified, side: .ipad)
    }

    static func noteInputSent(inputId: Int, devWallMs: Double, wireMacMs: Double?) {
        guard TraceCollector.shared.isActive else { return }
        let end = TraceCollector.shared.ipadUnifiedMs(wallMs: devWallMs)
        let start = inputEmitStartMs[inputId] ?? end
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
        sendMsByFrame[frameId] = sendMs + clockOffsetMs
    }

    static func frameRecvStarted(_ frameId: Int) {
        guard TraceCollector.shared.isActive else { return }
        let ms = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        recvStartMsByFrame[frameId] = ms
        if let sendMs = sendMsByFrame[frameId] {
            TraceCollector.shared.span(TracePhase.frameTcpTransit, rowKind: TraceRowKind.frame,
                                       rowId: frameId, startMs: sendMs, endMs: ms, side: .ipad)
        }
    }

    static func frameParseDone(_ frameId: Int) {
        guard TraceCollector.shared.isActive else { return }
        let mid = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        let recv = recvStartMsByFrame[frameId] ?? mid
        parseDoneMsByFrame[frameId] = mid
        TraceCollector.shared.span(TracePhase.frameRecv, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: recv, endMs: mid, side: .ipad,
                                   meta: ["leg": "recv_to_sample"])
    }

    static func frameDisplayed(_ frameId: Int) {
        guard TraceCollector.shared.isActive else { return }
        let end = TraceCollector.shared.ipadUnifiedMs(wallMs: Date().timeIntervalSince1970 * 1000)
        let start = parseDoneMsByFrame[frameId] ?? recvStartMsByFrame[frameId] ?? end
        TraceCollector.shared.span(TracePhase.frameDisplay, rowKind: TraceRowKind.frame,
                                   rowId: frameId, startMs: start, endMs: end, side: .ipad,
                                   meta: ["leg": "sample_to_enqueue"])
        recvStartMsByFrame.removeValue(forKey: frameId)
        parseDoneMsByFrame.removeValue(forKey: frameId)
        displayedFrameIds.insert(frameId)
        if displayedFrameIds.count >= 100 {
            // Mac may stop slightly earlier; upload once we have a full batch.
        }
    }

    static func finishUpload(send: (_ msg: [String: Any]) -> Void) {
        guard awaitingUpload, let sessionId = pendingSessionId else { return }
        awaitingUpload = false
        TraceCollector.shared.stop(reason: "uploading spans")
        let spans = TraceCollector.shared.ipadSnapshot()
        guard var msg = TraceWire.uploadMessage(sessionId: sessionId, spans: spans) else { return }
        msg["displayedFrames"] = displayedFrameIds.count
        send(msg)
        Log.info("[trace] uploaded \(spans.count) iPad spans (\(displayedFrameIds.count) frames)")
        pendingSessionId = nil
    }
}
#endif
