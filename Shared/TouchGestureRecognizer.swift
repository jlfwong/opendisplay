// Mac-side gesture recognition: raw finger contacts → semantic input effects.
// Pure Swift (no AppKit/CGEvent) so unit tests can drive it with a recording sink.

import Foundation

// MARK: - Effects (output vocabulary)

enum TouchGesturePhase: String, Equatable {
    case began, changed, ended
}

enum TouchGestureEffect: Equatable {
    case pressLeft(x: Double, y: Double)
    case dragLeft(x: Double, y: Double)
    case releaseLeft(x: Double, y: Double)
    case warpCursor(x: Double, y: Double)
    case magnify(amount: Double, phase: TouchGesturePhase)
    case rotate(degrees: Double, phase: TouchGesturePhase)
    case scroll(dx: Double, dy: Double, phase: TouchGesturePhase)
    case undo
    case redo
}

// MARK: - Input frame

struct TouchGestureContact: Equatable {
    let id: Int
    let phase: TouchContactPhase
    /// Normalized [0, 1], origin top-left (video / display space).
    let x: Double
    let y: Double
}

struct TouchGestureFrame: Equatable {
    var timestamp: TimeInterval
    var displayWidth: Double
    var displayHeight: Double
    var contacts: [TouchGestureContact]
}

// MARK: - Sink + recording helper

protocol TouchGestureSink: AnyObject {
    func emit(_ effect: TouchGestureEffect)
}

/// Test double that records every emitted effect.
final class RecordingTouchGestureSink: TouchGestureSink {
    private(set) var effects: [TouchGestureEffect] = []

    func emit(_ effect: TouchGestureEffect) {
        effects.append(effect)
    }

    func reset() {
        effects.removeAll()
    }
}

// MARK: - Configuration

struct TouchGestureConfig: Equatable {
    /// Minimum inter-finger distance change (display points) per frame to emit pinch.
    var pinchDistanceThreshold: Double = 1.5
    // Deadbands: cumulative movement a two-finger touch must travel before it's
    // read as a manipulation. Larger values keep a two-finger *tap* from being
    // mistaken for a pan/pinch, so tap → undo stays reliable.
    /// Centroid travel (display points) before two-finger pan begins.
    var panStartThreshold: Double = 10
    /// Finger-separation change (display points) before pinch begins.
    var pinchStartThreshold: Double = 10
    /// A two/three-finger touch that lifts within this window — without ever
    /// crossing a manipulation deadband — is a tap (undo / redo).
    var tapMaxDuration: TimeInterval = 0.35
    /// Shared settle window: defers single-finger mouse-down until stable, and
    /// defers two-finger scroll/pinch until finger count stops increasing.
    var gestureSettleDefer: TimeInterval = 0.045
}

// MARK: - Recognizer

final class TouchGestureRecognizer {

    private let config: TouchGestureConfig
    private weak var sink: TouchGestureSink?

    private struct TrackedTouch {
        let id: Int
        var lastX: Double
        var lastY: Double
    }

    /// High-level finger routing — decide mode first, then emit effects.
    private enum FingerMode {
        case idle
        /// One finger down; defer window — warp only, no mouse down yet.
        case singlePending
        /// One finger confirmed — press / drag / release.
        case singleDrawing
        /// Two or more fingers — gestures only, never mouse down.
        case multiTouch
    }

    private var tracked: [Int: TrackedTouch] = [:]
    private var lastTimestamp: TimeInterval?

    private var fingerMode: FingerMode = .idle
    private var singlePendingSince: TimeInterval?
    private var leftDown = false

    private var prevPairDistance: Double?
    private var scrollPrevCentroid: (x: Double, y: Double)?
    private var pinchActive = false
    private var scrollPhaseActive = false

    private var pairStartCentroid: (x: Double, y: Double)?
    private var pairStartDistance: Double?

    private var interactionStart: TimeInterval?
    private var interactionPeakFingers = 0
    private var interactionManipulated = false
    private var lastFingerCount = 0
    /// Timestamp of the last finger-count increase; multi-touch manipulation waits
    /// until gestureSettleDefer elapses with no further increases.
    private var fingerCountStableSince: TimeInterval?

    init(config: TouchGestureConfig, sink: TouchGestureSink) {
        self.config = config
        self.sink = sink
    }

    func reset() {
        tracked.removeAll()
        lastTimestamp = nil
        fingerMode = .idle
        singlePendingSince = nil
        leftDown = false
        interactionStart = nil
        interactionPeakFingers = 0
        interactionManipulated = false
        lastFingerCount = 0
        fingerCountStableSince = nil
        resetMultiGestureState(finalize: true)
    }

    /// Process one wire frame of contacts. Returns whether any effect was emitted.
    @discardableResult
    func process(_ frame: TouchGestureFrame) -> Bool {
        guard let sink else { return false }
        let now = frame.timestamp
        defer { lastTimestamp = now }

        let dw = max(frame.displayWidth, 1)
        let dh = max(frame.displayHeight, 1)

        var emitted = false
        func emit(_ effect: TouchGestureEffect) {
            sink.emit(effect)
            emitted = true
        }

        let prevFingerCount = lastFingerCount

        // Unrelated `.began` while other ids are tracked → stale ghost contacts.
        // Reset to idle (release if mid-stroke).
        for contact in frame.contacts where contact.phase == .began {
            guard tracked[contact.id] == nil, !tracked.isEmpty else { continue }
            let liveFrameIds = Set(
                frame.contacts
                    .filter { $0.phase != .ended && $0.phase != .cancelled }
                    .map(\.id)
            )
            if tracked.keys.contains(where: { liveFrameIds.contains($0) }) {
                continue
            }
            resetToIdle(emit: emit)
        }

        if prevFingerCount == 0 && frame.contacts.contains(where: { $0.phase == .began }) {
            resetMultiGestureState(finalize: false)
            interactionStart = now
            interactionPeakFingers = 0
            interactionManipulated = false
        }

        for contact in frame.contacts where contact.phase == .began {
            tracked[contact.id] = TrackedTouch(id: contact.id, lastX: contact.x, lastY: contact.y)
        }

        let active = activeContacts(from: frame.contacts)
        let fingerCount = active.count
        interactionPeakFingers = max(interactionPeakFingers, fingerCount)

        handleSingleFingerEnded(in: frame.contacts, emit: emit)

        updateFingerMode(
            fingerCount: fingerCount,
            prevFingerCount: prevFingerCount,
            now: now,
            active: active,
            emit: emit
        )

        switch fingerMode {
        case .idle:
            break
        case .singlePending:
            if fingerCount == 1 {
                handleSinglePending(active[0], now: now, emit: emit)
            }
        case .singleDrawing:
            if fingerCount == 1 {
                handleSingleDrawing(active[0], emit: emit)
            }
        case .multiTouch:
            if fingerCount >= 2 {
                handleTwo(active, displayWidth: dw, displayHeight: dh, now: now, emit: emit)
            } else if fingerCount == 1 {
                handleRemainingFinger(active[0], emit: emit)
            }
        }

        for contact in frame.contacts where contact.phase == .moved || contact.phase == .began || contact.phase == .ended {
            if tracked[contact.id] == nil,
               contact.phase != .ended && contact.phase != .cancelled {
                tracked[contact.id] = TrackedTouch(id: contact.id, lastX: contact.x, lastY: contact.y)
            }
            guard var t = tracked[contact.id] else { continue }
            t.lastX = contact.x
            t.lastY = contact.y
            tracked[contact.id] = t
        }

        for contact in frame.contacts where contact.phase == .ended || contact.phase == .cancelled {
            tracked.removeValue(forKey: contact.id)
        }

        if fingerCount == 0 && fingerMode != .idle {
            finalizeInteractionEnd(now: now, contacts: frame.contacts, emit: emit)
        }

        lastFingerCount = activeContacts(from: frame.contacts).count

        return emitted
    }

    // MARK: - Mode transitions

    private func updateFingerMode(fingerCount: Int,
                                  prevFingerCount: Int,
                                  now: TimeInterval,
                                  active: [TouchGestureContact],
                                  emit: (TouchGestureEffect) -> Void) {
        if fingerCount > prevFingerCount {
            fingerCountStableSince = now
            if fingerCount >= 2 {
                resetPairBaselines()
            }
        }

        if fingerCount >= 2 {
            if fingerMode == .singleDrawing {
                retractSinglePress(emit: emit)
            }
            if fingerMode != .multiTouch {
                warpToCentroid(active, emit: emit)
            }
            fingerMode = .multiTouch
            singlePendingSince = nil
            return
        }

        if fingerCount == 0 {
            return
        }

        if fingerCount == 1 && prevFingerCount == 0 {
            fingerMode = .singlePending
            singlePendingSince = now
            return
        }

        if fingerCount == 1 && prevFingerCount >= 2 {
            // 2→1: remain in multiTouch; remaining finger warps only.
            fingerMode = .multiTouch
            singlePendingSince = nil
        }
    }

    private func handleSingleFingerEnded(in contacts: [TouchGestureContact],
                                         emit: (TouchGestureEffect) -> Void) {
        guard let ended = contacts.first(where: { $0.phase == .ended || $0.phase == .cancelled }),
              contacts.filter({ $0.phase != .ended && $0.phase != .cancelled }).count <= 1 else {
            return
        }

        switch fingerMode {
        case .singlePending:
            emit(.pressLeft(x: ended.x, y: ended.y))
            emit(.releaseLeft(x: ended.x, y: ended.y))
            fingerMode = .idle
            singlePendingSince = nil
        case .singleDrawing:
            if leftDown {
                emit(.releaseLeft(x: ended.x, y: ended.y))
                leftDown = false
            }
            fingerMode = .idle
            singlePendingSince = nil
        default:
            break
        }
    }

    private func finalizeInteractionEnd(now: TimeInterval,
                                        contacts: [TouchGestureContact],
                                        emit: (TouchGestureEffect) -> Void) {
        if fingerMode == .multiTouch {
            finalizeMultiGesture(emit: emit)
        }
        if leftDown, let t = primaryTrackedTouch() {
            emit(.releaseLeft(x: t.lastX, y: t.lastY))
            leftDown = false
        }
        emitTapIfNeeded(now: now, emit: emit)
        fingerMode = .idle
        singlePendingSince = nil
        fingerCountStableSince = nil
        interactionStart = nil
        interactionPeakFingers = 0
        interactionManipulated = false
    }

    private func resetToIdle(emit: (TouchGestureEffect) -> Void) {
        if leftDown, let t = primaryTrackedTouch() {
            emit(.releaseLeft(x: t.lastX, y: t.lastY))
        }
        leftDown = false
        tracked.removeAll()
        fingerMode = .idle
        singlePendingSince = nil
        fingerCountStableSince = nil
        resetMultiGestureState(finalize: false)
        interactionManipulated = false
    }

    // MARK: - Single finger

    private func handleSinglePending(_ contact: TouchGestureContact,
                                     now: TimeInterval,
                                     emit: (TouchGestureEffect) -> Void) {
        let x = contact.x
        let y = contact.y

        switch contact.phase {
        case .began, .moved:
            emit(.warpCursor(x: x, y: y))
            tryCommitSinglePending(x: x, y: y, now: now, emit: emit)
            if fingerMode == .singleDrawing && contact.phase == .moved {
                emit(.dragLeft(x: x, y: y))
            }
        case .ended, .cancelled:
            break
        }
    }

    private func tryCommitSinglePending(x: Double, y: Double, now: TimeInterval,
                                        emit: (TouchGestureEffect) -> Void) {
        guard fingerMode == .singlePending,
              let since = singlePendingSince,
              now - since >= config.gestureSettleDefer else { return }
        emit(.pressLeft(x: x, y: y))
        leftDown = true
        fingerMode = .singleDrawing
        singlePendingSince = nil
    }

    private func handleSingleDrawing(_ contact: TouchGestureContact,
                                     emit: (TouchGestureEffect) -> Void) {
        let x = contact.x
        let y = contact.y

        switch contact.phase {
        case .began:
            emit(.warpCursor(x: x, y: y))
        case .moved:
            if leftDown {
                emit(.dragLeft(x: x, y: y))
            } else {
                emit(.warpCursor(x: x, y: y))
            }
        case .ended, .cancelled:
            break
        }
    }

    /// After a multi-touch gesture, the surviving finger only moves the cursor.
    private func handleRemainingFinger(_ contact: TouchGestureContact,
                                       emit: (TouchGestureEffect) -> Void) {
        emit(.warpCursor(x: contact.x, y: contact.y))
    }

    // MARK: - Two fingers

    private func handleTwo(_ contacts: [TouchGestureContact],
                           displayWidth: Double,
                           displayHeight: Double,
                           now: TimeInterval,
                           emit: (TouchGestureEffect) -> Void) {
        guard contacts.count >= 2 else { return }
        let a = contacts[0]
        let b = contacts[1]

        let ax = a.x * displayWidth
        let ay = a.y * displayHeight
        let bx = b.x * displayWidth
        let by = b.y * displayHeight

        let centroidX = (a.x + b.x) / 2
        let centroidY = (a.y + b.y) / 2
        let distance = hypot(ax - bx, ay - by)

        if contacts.count >= 3 {
            warpToCentroid(contacts, emit: emit)
        } else {
            emit(.warpCursor(x: centroidX, y: centroidY))
        }

        if pairStartCentroid == nil { pairStartCentroid = (centroidX, centroidY) }
        if pairStartDistance == nil { pairStartDistance = distance }

        guard multiTouchManipulationAllowed(fingerCount: contacts.count, now: now) else {
            prevPairDistance = distance
            scrollPrevCentroid = (centroidX, centroidY)
            return
        }

        let startCentroid = pairStartCentroid ?? (centroidX, centroidY)
        let travel = hypot((centroidX - startCentroid.x) * displayWidth,
                           (centroidY - startCentroid.y) * displayHeight)
        let separationChange = abs(distance - (pairStartDistance ?? distance))
        let deadbandCrossed = scrollPhaseActive || pinchActive
            || travel > config.panStartThreshold
            || separationChange > config.pinchStartThreshold

        if deadbandCrossed, let prevDist = prevPairDistance {
            interactionManipulated = true
            let distDelta = distance - prevDist
            let centDelta: Double
            if let prev = scrollPrevCentroid {
                let pdx = (centroidX - prev.x) * displayWidth
                let pdy = (centroidY - prev.y) * displayHeight
                centDelta = hypot(pdx, pdy)
            } else {
                centDelta = 0
            }

            // Magnify before scroll — zoom anchors at warpCursor centroid.
            let pinchEligible = pinchActive || separationChange > config.pinchStartThreshold
            if pinchEligible,
               abs(distDelta) > config.pinchDistanceThreshold,
               abs(distDelta) > centDelta * 0.6 {
                if !pinchActive {
                    emit(.magnify(amount: 0, phase: .began))
                    pinchActive = true
                }
                let amount = distDelta / 200.0
                emit(.magnify(amount: amount, phase: .changed))
            }

            let panEligible = scrollPhaseActive || travel > config.panStartThreshold
            if panEligible, let prev = scrollPrevCentroid {
                let dxRaw = (centroidX - prev.x) * displayWidth
                let dyRaw = (centroidY - prev.y) * displayHeight
                if dxRaw != 0 || dyRaw != 0 {
                    if !scrollPhaseActive {
                        emit(.scroll(dx: 0, dy: 0, phase: .began))
                        scrollPhaseActive = true
                    }
                    emit(.scroll(dx: dxRaw, dy: dyRaw, phase: .changed))
                }
            }
        }

        prevPairDistance = distance
        scrollPrevCentroid = (centroidX, centroidY)
    }

    // MARK: - Helpers

    private func activeContacts(from contacts: [TouchGestureContact]) -> [TouchGestureContact] {
        let endedThisFrame = Set(
            contacts.filter { $0.phase == .ended || $0.phase == .cancelled }.map(\.id)
        )
        var byID: [Int: TouchGestureContact] = [:]
        for c in contacts where c.phase != .ended && c.phase != .cancelled {
            byID[c.id] = c
        }
        for id in tracked.keys where byID[id] == nil && !endedThisFrame.contains(id) {
            if let t = tracked[id] {
                byID[id] = TouchGestureContact(id: id, phase: .moved, x: t.lastX, y: t.lastY)
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    private func primaryTrackedTouch() -> TrackedTouch? {
        tracked.values.min(by: { $0.id < $1.id })
    }

    private func warpToCentroid(_ active: [TouchGestureContact],
                                emit: (TouchGestureEffect) -> Void) {
        guard !active.isEmpty else { return }
        let cx = active.reduce(0.0) { $0 + $1.x } / Double(active.count)
        let cy = active.reduce(0.0) { $0 + $1.y } / Double(active.count)
        emit(.warpCursor(x: cx, y: cy))
    }

    private func multiTouchManipulationAllowed(fingerCount: Int, now: TimeInterval) -> Bool {
        guard fingerCount == 2,
              interactionPeakFingers < 3,
              let since = fingerCountStableSince,
              now - since >= config.gestureSettleDefer else { return false }
        return true
    }

    private func emitTapIfNeeded(now: TimeInterval, emit: (TouchGestureEffect) -> Void) {
        guard !interactionManipulated,
              let start = interactionStart,
              now - start <= config.tapMaxDuration else { return }
        switch interactionPeakFingers {
        case 2: emit(.undo)
        case 3: emit(.redo)
        default: break
        }
    }

    private func retractSinglePress(emit: (TouchGestureEffect) -> Void) {
        guard leftDown, let t = primaryTrackedTouch() else { return }
        emit(.releaseLeft(x: t.lastX, y: t.lastY))
        leftDown = false
    }

    private func finalizeMultiGesture(emit: (TouchGestureEffect) -> Void) {
        if scrollPhaseActive {
            emit(.scroll(dx: 0, dy: 0, phase: .ended))
        }
        if pinchActive {
            emit(.magnify(amount: 0, phase: .ended))
        }
        resetMultiGestureState(finalize: false)
    }

    private func resetPairBaselines() {
        prevPairDistance = nil
        scrollPrevCentroid = nil
        pairStartCentroid = nil
        pairStartDistance = nil
    }

    private func resetMultiGestureState(finalize: Bool) {
        _ = finalize
        prevPairDistance = nil
        scrollPrevCentroid = nil
        pairStartCentroid = nil
        pairStartDistance = nil
        pinchActive = false
        scrollPhaseActive = false
    }
}
