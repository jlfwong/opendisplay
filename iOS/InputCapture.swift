// InputCaptureEngine: Apple Pencil + multi-touch with full fidelity.
// Installed on VideoView (not a separate overlay) so hit-testing matches
// the pre-port behavior that finger touches relied on.

import UIKit

/// Captures pencil, hover, and gesture input. Coordinates are normalized
/// [0,1] in video space (origin top-left) via the host view's normalize closure.
final class InputCaptureEngine: NSObject {
    var onTouch: ((_ phase: String, _ x: Double, _ y: Double,
                     _ osMs: Double, _ captureMs: Double) -> Void)?
    var onPencil: ((_ phase: PencilPhase, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double,
                    _ rotation: Double, _ osMs: Double, _ captureMs: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ eraser: Bool) -> Void)?
    var onGesture: ((_ kind: GestureKind, _ state: GestureState,
                     _ scale: Double?, _ velocity: Double?,
                     _ x: Double?, _ y: Double?, _ fingerCount: Int?) -> Void)?

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var hoverInRange = false
    private var activeFingerTouches: Set<ObjectIdentifier> = []
    private var penStrokes: [UInt64: PenStroke] = [:]
    private let tapMoveThreshold: CGFloat = 8
    private var lastFingerNorm: (x: Double, y: Double)?
    private var sentCancelForBlock = false

    private struct PenStroke {
        var start: CGPoint
        var sentDown: Bool
    }

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        view.addGestureRecognizer(hover)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(threeFingerTap)
    }

    private func norm(_ p: CGPoint) -> (Double, Double)? {
        guard let n = normalize?(p) else { return nil }
        return (n.x, n.y)
    }

    private func gestureCentroid(_ gr: UIGestureRecognizer) -> (Double, Double)? {
        guard let view = hostView else { return nil }
        guard gr.numberOfTouches > 0 else {
            return norm(gr.location(in: view)).map { ($0.0, $0.1) }
        }
        var sum = CGPoint.zero
        for i in 0..<gr.numberOfTouches {
            sum.x += gr.location(ofTouch: i, in: view).x
            sum.y += gr.location(ofTouch: i, in: view).y
        }
        sum.x /= CGFloat(gr.numberOfTouches)
        sum.y /= CGFloat(gr.numberOfTouches)
        return norm(sum).map { ($0.0, $0.1) }
    }

    private func emitTouch(phase: String, x: Double, y: Double, osDeliveredMs: Double) {
        let captureMs = Date().timeIntervalSince1970 * 1000
        onTouch?(phase, x, y, osDeliveredMs, captureMs)
    }

    private func emitPencil(_ phase: PencilPhase, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double,
                            rotation: Double, osDeliveredMs: Double) {
        let captureMs = Date().timeIntervalSince1970 * 1000
        onPencil?(phase, x, y, pressure, azimuth, altitude, rotation, osDeliveredMs, captureMs)
    }

    // MARK: - Hover (pen in air)

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty, let view = hostView else { return }
        guard let (nx, ny) = norm(gr.location(in: view)) else { return }
        let osMs = Date().timeIntervalSince1970 * 1000
        switch gr.state {
        case .began, .changed:
            if !hoverInRange {
                onProximity?(true, false)
                hoverInRange = true
                logCapture("hover enter")
            }
            emitPencil(.hover, x: nx, y: ny, pressure: 0, azimuth: 0, altitude: .pi / 2, rotation: 0, osDeliveredMs: osMs)
        case .ended, .cancelled, .failed:
            if hoverInRange {
                onProximity?(false, false)
                hoverInRange = false
                logCapture("hover exit")
            }
        default:
            break
        }
    }

    // MARK: - Touch (pen / finger on screen)

    private func trackFingerTouches(_ touches: Set<UITouch>, ended: Bool) {
        for touch in touches where isFinger(touch) {
            let key = ObjectIdentifier(touch)
            if ended { activeFingerTouches.remove(key) }
            else { activeFingerTouches.insert(key) }
        }
    }

    private func isFinger(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .direct: return true
        default:
            if #available(iOS 17.0, *), touch.type == .indirectPointer { return true }
            return false
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, phase: String, ended: Bool,
                osDeliveredMs: Double) {
        trackFingerTouches(touches, ended: ended)
        let blockFinger = activeFingerTouches.count > 1
        if blockFinger {
            if !sentCancelForBlock, let last = lastFingerNorm {
                logCapture("block finger phase=\(phase) activeFingers=\(activeFingerTouches.count) — cancel once")
                emitTouch(phase: "cancelled", x: last.x, y: last.y, osDeliveredMs: osDeliveredMs)
                sentCancelForBlock = true
            }
        } else {
            sentCancelForBlock = false
        }

        for touch in touches {
            switch touch.type {
            case .pencil, .stylus:
                emitPen(touch, event: event, ended: ended, osDeliveredMs: osDeliveredMs)
            default:
                guard isFinger(touch) else { continue }
                guard !blockFinger, activeFingerTouches.count <= 1 else { continue }
                emitFinger(touch, event: event, phase: phase, osDeliveredMs: osDeliveredMs)
            }
        }
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool, osDeliveredMs: Double) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let (nx, ny) = norm(loc) else { return }

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        var rotationDeg: Double = 0
        if #available(iOS 17.5, *) {
            rotationDeg = Double(touch.rollAngle) * 180.0 / .pi
        }

        if hoverInRange {
            onProximity?(false, false)
            hoverInRange = false
        }

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            onProximity?(true, false)
            penStrokes[id] = PenStroke(start: loc, sentDown: false)
            logCapture("pen contact began (waiting for move/tap)")
            return
        }

        if !ended {
            guard var stroke = penStrokes[id] else { return }
            let dx = loc.x - stroke.start.x
            let dy = loc.y - stroke.start.y
            let moved = sqrt(dx * dx + dy * dy)
            if !stroke.sentDown {
                guard moved > tapMoveThreshold else { return }
                stroke.sentDown = true
                penStrokes[id] = stroke
                if let (sx, sy) = norm(stroke.start) {
                    logCapture("pen stroke down @ \(fmt(sx, sy))")
                    emitPencil(.down, x: sx, y: sy, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
                }
            }
            emitPencil(.move, x: nx, y: ny, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            for c in event?.coalescedTouches(for: touch) ?? [] where c !== touch {
                guard let (cx, cy) = norm(c.location(in: view)) else { continue }
                emitPencil(.move, x: cx, y: cy,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle),
                           rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            }
            return
        }

        defer {
            activePens.remove(id)
            penStrokes.removeValue(forKey: id)
            onProximity?(false, false)
        }

        if let stroke = penStrokes[id], !stroke.sentDown {
            logCapture("pen tap → down+up @ \(fmt(nx, ny))")
            emitPencil(.down, x: nx, y: ny, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            emitPencil(.up, x: nx, y: ny, pressure: 0, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            return
        }

        logCapture("pen up @ \(fmt(nx, ny))")
        emitPencil(.up, x: nx, y: ny, pressure: 0, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
    }

    private func emitFinger(_ touch: UITouch, event: UIEvent?, phase: String,
                            osDeliveredMs: Double) {
        guard let view = hostView else { return }
        if phase == "moved", let event {
            for t in event.coalescedTouches(for: touch) ?? [touch] {
                guard let n = norm(t.location(in: view)) else { continue }
                lastFingerNorm = (x: n.0, y: n.1)
                emitTouch(phase: "moved", x: n.0, y: n.1, osDeliveredMs: osDeliveredMs)
            }
            if let predicted = event.predictedTouches(for: touch)?.last,
               let n = norm(predicted.location(in: view)) {
                emitTouch(phase: "moved", x: n.0, y: n.1, osDeliveredMs: osDeliveredMs)
            }
            return
        }
        guard let n = norm(touch.location(in: view)) else {
            logCapture("finger \(phase) DROPPED (normalize nil)")
            return
        }
        lastFingerNorm = (x: n.0, y: n.1)
        if phase != "moved" { logCapture("finger \(phase) @ \(fmt(n.0, n.1))") }
        emitTouch(phase: phase, x: n.0, y: n.1, osDeliveredMs: osDeliveredMs)
    }

    @objc private func twoFingerTapped(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended, let (nx, ny) = gestureCentroid(gr) else { return }
        logCapture("two-finger tap @ \(fmt(nx, ny))")
        onGesture?(.tap, .ended, nil, nil, nx, ny, 2)
    }

    @objc private func threeFingerTapped(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended, let (nx, ny) = gestureCentroid(gr) else { return }
        logCapture("three-finger tap @ \(fmt(nx, ny))")
        onGesture?(.tap, .ended, nil, nil, nx, ny, 3)
    }

    private func logCapture(_ message: String) {
        Log.info("[input] capture \(message)")
    }

    private func fmt(_ x: Double, _ y: Double) -> String {
        String(format: "%.3f,%.3f", x, y)
    }

    private func gestureState(_ s: UIGestureRecognizer.State) -> GestureState {
        switch s {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled: return .cancelled
        default: return .changed
        }
    }
}
