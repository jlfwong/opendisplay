import os

/// Points-of-Interest tracing for input control recv gaps on `:9000`.
///
/// Every inter-recv gap (recv-end → next recv-start) is an `InputRecvGap`
/// interval. Gaps over 300ms also emit an `InputRecvGapLarge` event.
enum InputRecvSignpost {
    private static let log = OSLog(subsystem: "com.peetzweg.opensidecar.mac",
                                   category: OSLog.Category.pointsOfInterest)

    private static let largeGapThresholdMs: Double = 300
    private static let tailGraceMs: Double = 250

    private static var openIntervalID: OSSignpostID?
    private static var intervalStartMs: Double = 0
    private static var lastInputRecvMs: Double = 0

    /// Call at the **start** of `handleControl` for latency-sensitive input.
    static func recvStarted(recvMs: Double, type: String, phase: String?, inpId: Int?,
                            penDown: Bool, fingerDown: Bool) {
        VideoQueueThread.markSenderVideo()
        guard countsForRecvGap(type: type, phase: phase) else { return }

        let active = streamActive(penDown: penDown, fingerDown: fingerDown,
                                  recvMs: recvMs, type: type, phase: phase)
        guard let openID = openIntervalID else { return }

        let gapMs = recvMs - intervalStartMs
        os_signpost(.end, log: log, name: "InputRecvGap", signpostID: openID,
                    "gap_ms=%{public}.0f", gapMs)
        openIntervalID = nil

        guard active, gapMs > largeGapThresholdMs else { return }

        let eventID = OSSignpostID(log: log)
        let tid = VideoQueueThread.id
        os_signpost(.event, log: log, name: "InputRecvGapLarge", signpostID: eventID,
                    "gap_ms=%{public}.0f type=%{public}s id=%{public}d tid=%{public}llu",
                    gapMs, type, inpId ?? -1, tid)
        Log.info("[recv-gap] \(Int(gapMs))ms before \(type) \(phase ?? "?") inpId=\(inpId.map(String.init) ?? "-") tid=\(tid)")
    }

    /// Call at the **end** of `handleControl` for latency-sensitive input.
    static func recvEnded(endMs: Double, type: String, phase: String?,
                          penDown: Bool, fingerDown: Bool) {
        guard countsForRecvGap(type: type, phase: phase) else { return }

        let active = streamActive(penDown: penDown, fingerDown: fingerDown,
                                  recvMs: endMs, type: type, phase: phase)
        lastInputRecvMs = endMs

        guard active else {
            closeOpenInterval(at: endMs)
            return
        }

        let id = OSSignpostID(log: log)
        openIntervalID = id
        intervalStartMs = endMs
        os_signpost(.begin, log: log, name: "InputRecvGap", signpostID: id)
    }

    static func endStroke() {
        closeOpenInterval(at: Date().timeIntervalSince1970 * 1000)
        lastInputRecvMs = 0
    }

    private static func closeOpenInterval(at ms: Double) {
        guard let openID = openIntervalID else { return }
        let gapMs = ms - intervalStartMs
        os_signpost(.end, log: log, name: "InputRecvGap", signpostID: openID,
                    "gap_ms=%{public}.0f", gapMs)
        openIntervalID = nil
    }

    private static func streamActive(penDown: Bool, fingerDown: Bool, recvMs: Double,
                                     type: String, phase: String?) -> Bool {
        if penDown || fingerDown { return true }
        if isStrokePhase(type: type, phase: phase) { return true }
        if lastInputRecvMs > 0, recvMs - lastInputRecvMs < tailGraceMs { return true }
        return false
    }

    private static func isStrokePhase(type: String, phase: String?) -> Bool {
        switch type {
        case WireInput.pencil, WireInput.touches:
            guard let phase else { return true }
            return phase == "began" || phase == "moved"
                || phase == "ended" || phase == "cancelled"
        case WireInput.barrelButton:
            return true
        default:
            return false
        }
    }

    private static func countsForRecvGap(type: String, phase: String?) -> Bool {
        switch type {
        case WireInput.pencil:
            guard let phase else { return true }
            return phase != "hover"
        case WireInput.proximity:
            return false
        case WireInput.touches, WireInput.barrelButton:
            return true
        default:
            return false
        }
    }
}
