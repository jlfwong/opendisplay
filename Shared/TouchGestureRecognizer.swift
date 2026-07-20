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
    var scrollGain: Double = 2.8
    /// Minimum inter-finger distance change (display points) to start pinch.
    var pinchDistanceThreshold: Double = 1.5
    /// Minimum finger separation (display points) before rotation is considered.
    var rotateMinSeparation: Double = 80
    /// Minimum angle delta (radians) per frame for rotation.
    var rotateAngleThreshold: Double = 0.01
    // Deadbands: cumulative movement a two-finger touch must travel before it's
    // read as a manipulation. Larger values keep a two-finger *tap* from being
    // mistaken for a pan/pinch, so tap → undo stays reliable.
    /// Centroid travel (display points) before two-finger pan begins.
    var panStartThreshold: Double = 10
    /// Finger-separation change (display points) before pinch begins.
    var pinchStartThreshold: Double = 10
    /// Rotation (radians) before rotate begins.
    var rotateStartThreshold: Double = 0.18
    /// A two/three-finger touch that lifts within this window — without ever
    /// crossing a manipulation deadband — is a tap (undo / redo).
    var tapMaxDuration: TimeInterval = 0.35
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

    private enum ActiveGesture {
        case pinch, rotate, scroll
    }

    private var tracked: [Int: TrackedTouch] = [:]
    private var lastTimestamp: TimeInterval?

    private var leftDown = false
    private var suppressSinglePress = false

    private var prevPairDistance: Double?
    private var prevPairAngle: Double?
    private var scrollPrevCentroid: (x: Double, y: Double)?
    private var pinchActive = false
    private var rotateActive = false
    private var scrollPhaseActive = false
    private var lockedGesture: ActiveGesture?

    // Reference values captured when the current finger pair is first seen —
    // used to measure cumulative travel against the deadbands.
    private var pairStartCentroid: (x: Double, y: Double)?
    private var pairStartDistance: Double?
    private var pairStartAngle: Double?

    // Whole-interaction (first finger down → last finger up) tracking for taps.
    private var interactionStart: TimeInterval?
    private var interactionPeakFingers = 0
    private var interactionManipulated = false
    /// Finger count at end of the previous frame (for 1→2 transition detection).
    private var lastFingerCount = 0

    init(config: TouchGestureConfig, sink: TouchGestureSink) {
        self.config = config
        self.sink = sink
    }

    func reset() {
        tracked.removeAll()
        lastTimestamp = nil
        leftDown = false
        suppressSinglePress = false
        interactionStart = nil
        interactionPeakFingers = 0
        interactionManipulated = false
        lastFingerCount = 0
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

        let prevActiveCount = lastFingerCount

        // A new `.began` for an id we weren't tracking means a fresh touch
        // sequence — purge stale contacts that would otherwise make this look
        // like a two-finger gesture (the #1 cause of single-finger taps doing
        // nothing: pressLeft never fires, only warpCursor / scroll / magnify).
        // Do NOT purge when a second finger joins an active touch: the existing
        // tracked id(s) are still present in this frame.
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
            if leftDown, let t = tracked.values.first {
                emit(.releaseLeft(x: t.lastX, y: t.lastY))
            }
            leftDown = false
            tracked.removeAll()
            suppressSinglePress = false
            resetMultiGestureState(finalize: false)
            interactionManipulated = false
        }

        // Start of a fresh touch sequence: clear any state a previous (possibly
        // messy) interaction left behind, so a plain single-finger tap always
        // begins clean instead of inheriting a stuck `suppressSinglePress`.
        if prevActiveCount == 0 && frame.contacts.contains(where: { $0.phase == .began }) {
            suppressSinglePress = false
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

        if prevActiveCount == 1 && fingerCount >= 2 {
            retractSinglePress(emit: emit)
            suppressSinglePress = true
            // Second finger landing inflates cumulative separation vs travel;
            // reset pair baselines so pan/pinch lock reflects movement, not pose.
            resetPairBaselines()
            let cx = active.reduce(0.0) { $0 + $1.x } / Double(active.count)
            let cy = active.reduce(0.0) { $0 + $1.y } / Double(active.count)
            emit(.warpCursor(x: cx, y: cy))
        }

        switch fingerCount {
        case 0:
            finalizeMultiGesture(emit: emit)
            if leftDown {
                let x = tracked.values.first?.lastX ?? 0.5
                let y = tracked.values.first?.lastY ?? 0.5
                emit(.releaseLeft(x: x, y: y))
                leftDown = false
            }
            emitTapIfNeeded(now: now, emit: emit)
            suppressSinglePress = false
            interactionStart = nil
            interactionPeakFingers = 0
            interactionManipulated = false
        case 1:
            handleSingle(active[0], displayWidth: dw, displayHeight: dh, emit: emit)
            if fingerCount < prevActiveCount {
                finalizeMultiGesture(emit: emit)
                suppressSinglePress = true
            } else {
                resetMultiGestureState(finalize: false)
            }
        case 2:
            handleTwo(active, displayWidth: dw, displayHeight: dh, emit: emit)
        default:
            finalizeMultiGesture(emit: emit)
            suppressSinglePress = true
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

        lastFingerCount = activeContacts(from: frame.contacts).count

        return emitted
    }

    // MARK: - Single finger (direct touch)

    private func handleSingle(_ contact: TouchGestureContact,
                              displayWidth: Double,
                              displayHeight: Double,
                              emit: (TouchGestureEffect) -> Void) {
        let x = contact.x
        let y = contact.y

        switch contact.phase {
        case .began:
            if suppressSinglePress {
                emit(.warpCursor(x: x, y: y))
            } else {
                emit(.pressLeft(x: x, y: y))
                leftDown = true
            }
        case .moved:
            if leftDown {
                emit(.dragLeft(x: x, y: y))
            } else {
                emit(.warpCursor(x: x, y: y))
            }
        case .ended, .cancelled:
            if leftDown {
                emit(.releaseLeft(x: x, y: y))
                leftDown = false
            } else if suppressSinglePress {
                emit(.warpCursor(x: x, y: y))
            }
        }

        _ = displayWidth
        _ = displayHeight
    }

    // MARK: - Two fingers

    private func handleTwo(_ contacts: [TouchGestureContact],
                           displayWidth: Double,
                           displayHeight: Double,
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
        let angle = atan2(by - ay, bx - ax)

        emit(.warpCursor(x: centroidX, y: centroidY))

        if pairStartCentroid == nil { pairStartCentroid = (centroidX, centroidY) }
        if pairStartDistance == nil { pairStartDistance = distance }
        if pairStartAngle == nil { pairStartAngle = angle }

        // Cumulative movement since the pair was first seen, measured against
        // the deadbands so an incidental tap doesn't register as a manipulation.
        let startCentroid = pairStartCentroid ?? (centroidX, centroidY)
        let travel = hypot((centroidX - startCentroid.x) * displayWidth,
                           (centroidY - startCentroid.y) * displayHeight)
        let separationChange = abs(distance - (pairStartDistance ?? distance))
        let rotationSoFar = abs(angle - (pairStartAngle ?? angle))
        let deadbandCrossed = scrollPhaseActive || pinchActive || rotateActive
            || travel > config.panStartThreshold
            || separationChange > config.pinchStartThreshold
            || (rotationSoFar > config.rotateStartThreshold && distance > config.rotateMinSeparation)

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

            let kind: ClassifiedGesture
            if let locked = lockedGesture {
                switch locked {
                case .pinch: kind = .pinch
                case .rotate: kind = .rotate
                case .scroll: kind = .scroll
                }
            } else if travel >= separationChange {
                lockedGesture = .scroll
                kind = .scroll
            } else if separationChange > travel {
                lockedGesture = .pinch
                kind = .pinch
            } else {
                kind = classifyGesture(
                    distDelta: distDelta,
                    centDelta: centDelta,
                    angleDelta: prevPairAngle.map { angle - $0 },
                    separation: distance
                )
                switch kind {
                case .pinch: lockedGesture = .pinch
                case .rotate: lockedGesture = .rotate
                case .scroll: lockedGesture = .scroll
                case .none: break
                }
            }

            switch kind {
            case .pinch:
                if !pinchActive {
                    emit(.magnify(amount: 0, phase: .began))
                    pinchActive = true
                    lockedGesture = .pinch
                }
                let amount = distDelta / 200.0
                emit(.magnify(amount: amount, phase: .changed))
            case .rotate:
                if !rotateActive, let prevAngle = prevPairAngle {
                    emit(.rotate(degrees: 0, phase: .began))
                    rotateActive = true
                    lockedGesture = .rotate
                    let degrees = (angle - prevAngle) * 180 / .pi
                    emit(.rotate(degrees: degrees, phase: .changed))
                } else if rotateActive, let prevAngle = prevPairAngle {
                    let degrees = (angle - prevAngle) * 180 / .pi
                    emit(.rotate(degrees: degrees, phase: .changed))
                }
            case .scroll:
                if let prev = scrollPrevCentroid {
                    let dxRaw = (centroidX - prev.x) * displayWidth * config.scrollGain
                    let dyRaw = (centroidY - prev.y) * displayHeight * config.scrollGain
                    if dxRaw != 0 || dyRaw != 0 {
                        if !scrollPhaseActive {
                            emit(.scroll(dx: 0, dy: 0, phase: .began))
                            scrollPhaseActive = true
                            lockedGesture = .scroll
                        }
                        // Natural direction: content follows the fingers on both axes.
                        emit(.scroll(dx: dxRaw, dy: -dyRaw, phase: .changed))
                    }
                }
            case .none:
                break
            }
        }

        prevPairDistance = distance
        prevPairAngle = angle
        scrollPrevCentroid = (centroidX, centroidY)
    }

    private enum ClassifiedGesture {
        case pinch, rotate, scroll, none
    }

    private func classifyGesture(distDelta: Double,
                               centDelta: Double,
                               angleDelta: Double?,
                               separation: Double) -> ClassifiedGesture {
        if centDelta > 0 && centDelta >= abs(distDelta) {
            return .scroll
        }
        if abs(distDelta) > config.pinchDistanceThreshold
            && abs(distDelta) > centDelta * 0.6 {
            return .pinch
        }
        if let delta = angleDelta,
           abs(delta) > config.rotateAngleThreshold,
           separation > config.rotateMinSeparation {
            return .rotate
        }
        if centDelta > 0 {
            return .scroll
        }
        return .none
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

    private func activeContactCount() -> Int {
        tracked.count
    }

    /// A two/three-finger touch that lifted quickly without manipulating is a
    /// tap: two fingers → undo, three fingers → redo.
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
        guard leftDown, let t = tracked.values.min(by: { $0.id < $1.id }) else { return }
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
        if rotateActive {
            emit(.rotate(degrees: 0, phase: .ended))
        }
        resetMultiGestureState(finalize: false)
    }

    private func resetPairBaselines() {
        prevPairDistance = nil
        prevPairAngle = nil
        scrollPrevCentroid = nil
        pairStartCentroid = nil
        pairStartDistance = nil
        pairStartAngle = nil
    }

    private func resetMultiGestureState(finalize: Bool) {
        if finalize {
            // Caller already finalized via emit.
        }
        prevPairDistance = nil
        prevPairAngle = nil
        scrollPrevCentroid = nil
        pairStartCentroid = nil
        pairStartDistance = nil
        pairStartAngle = nil
        pinchActive = false
        rotateActive = false
        scrollPhaseActive = false
        lockedGesture = nil
    }
}
