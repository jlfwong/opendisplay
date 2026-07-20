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

    init(config: TouchGestureConfig, sink: TouchGestureSink) {
        self.config = config
        self.sink = sink
    }

    func reset() {
        tracked.removeAll()
        lastTimestamp = nil
        leftDown = false
        suppressSinglePress = false
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

        let prevActiveCount = activeContactCount()

        for contact in frame.contacts where contact.phase == .began {
            tracked[contact.id] = TrackedTouch(id: contact.id, lastX: contact.x, lastY: contact.y)
        }

        let active = activeContacts(from: frame.contacts)
        let fingerCount = active.count

        if prevActiveCount == 1 && fingerCount >= 2 {
            retractSinglePress(emit: emit)
            suppressSinglePress = true
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
            suppressSinglePress = false
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
            guard var t = tracked[contact.id] else { continue }
            t.lastX = contact.x
            t.lastY = contact.y
            tracked[contact.id] = t
        }

        for contact in frame.contacts where contact.phase == .ended || contact.phase == .cancelled {
            tracked.removeValue(forKey: contact.id)
        }

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

        if let prevDist = prevPairDistance {
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
            } else {
                kind = classifyGesture(
                    distDelta: distDelta,
                    centDelta: centDelta,
                    angleDelta: prevPairAngle.map { angle - $0 },
                    separation: distance
                )
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
                        emit(.scroll(dx: -dxRaw, dy: dyRaw, phase: .changed))
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

    private func retractSinglePress(emit: (TouchGestureEffect) -> Void) {
        guard leftDown, let t = tracked.values.first else { return }
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

    private func resetMultiGestureState(finalize: Bool) {
        if finalize {
            // Caller already finalized via emit.
        }
        prevPairDistance = nil
        prevPairAngle = nil
        scrollPrevCentroid = nil
        pinchActive = false
        rotateActive = false
        scrollPhaseActive = false
        lockedGesture = nil
    }
}
