// InputCapture: Apple Pencil + multi-touch with full fidelity, mapped into
// normalized video-space coordinates by the host view.

import UIKit

/// Captures pencil, hover, and gesture input on a transparent overlay.
/// Coordinates are normalized [0,1] in video space (origin top-left).
final class InputCaptureView: UIView {
    var onTouch: ((_ phase: String, _ x: Double, _ y: Double) -> Void)?
    var onPencil: ((_ phase: PencilPhase, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double,
                    _ rotation: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ eraser: Bool) -> Void)?
    var onGesture: ((_ kind: GestureKind, _ state: GestureState,
                     _ scale: Double?, _ velocity: Double?,
                     _ x: Double?, _ y: Double?, _ fingerCount: Int?) -> Void)?
    var onBarrelButton: ((_ down: Bool, _ x: Double, _ y: Double) -> Void)?

    /// Map a point in this view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private var activePens: Set<UInt64> = []
    private var hoverInRange = false
    private var activeFingerTouches: Set<ObjectIdentifier> = []
    private var penStrokes: [UInt64: PenStroke] = [:]
    private let tapMoveThreshold: CGFloat = 8
    private var gestureActive = false

    private struct PenStroke {
        var start: CGPoint
        var sentDown: Bool
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        addGestureRecognizer(hover)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        pinch.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(pinch)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.numberOfTapsRequired = 1
        addGestureRecognizer(threeFingerTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func norm(_ p: CGPoint) -> (Double, Double)? {
        guard let n = normalize?(p) else { return nil }
        return (n.x, n.y)
    }

    private func gestureCentroid(_ gr: UIGestureRecognizer) -> (Double, Double)? {
        guard gr.numberOfTouches > 0 else {
            return norm(gr.location(in: self)).map { ($0.0, $0.1) }
        }
        var sum = CGPoint.zero
        for i in 0..<gr.numberOfTouches {
            sum.x += gr.location(ofTouch: i, in: self).x
            sum.y += gr.location(ofTouch: i, in: self).y
        }
        sum.x /= CGFloat(gr.numberOfTouches)
        sum.y /= CGFloat(gr.numberOfTouches)
        return norm(sum).map { ($0.0, $0.1) }
    }

    // MARK: - Hover (pen in air)

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty else { return }
        guard let (nx, ny) = norm(gr.location(in: self)) else { return }
        switch gr.state {
        case .began, .changed:
            if !hoverInRange {
                onProximity?(true, false)
                hoverInRange = true
            }
            onPencil?(.hover, nx, ny, 0, 0, .pi / 2, 0)
        case .ended, .cancelled, .failed:
            if hoverInRange {
                onProximity?(false, false)
                hoverInRange = false
            }
        default:
            break
        }
    }

    // MARK: - Touch (pen / finger on screen)

    private func trackFingerTouches(_ touches: Set<UITouch>, ended: Bool) {
        for touch in touches where touch.type == .direct {
            let key = ObjectIdentifier(touch)
            if ended { activeFingerTouches.remove(key) }
            else { activeFingerTouches.insert(key) }
        }
    }

    private func handle(_ touches: Set<UITouch>, event: UIEvent?, phase: String, ended: Bool) {
        if gestureActive || (event?.allTouches?.count ?? 1) > 1 {
            if phase != "began", let last = lastFingerNorm {
                onTouch?("cancelled", last.x, last.y)
            }
            return
        }

        trackFingerTouches(touches, ended: ended)

        for touch in touches {
            switch touch.type {
            case .pencil, .stylus:
                emitPen(touch, event: event, ended: ended)
            case .direct:
                guard activeFingerTouches.count <= 1 else { continue }
                emitFinger(touch, event: event, phase: phase)
            default:
                break
            }
        }
    }

    private var lastFingerNorm: (x: Double, y: Double)?

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: self)
        guard let (nx, ny) = norm(loc) else { return }

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: self))
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
                    onPencil?(.down, sx, sy, pressure, azimuth, altitude, rotationDeg)
                }
            }
            onPencil?(.move, nx, ny, pressure, azimuth, altitude, rotationDeg)
            for c in event?.coalescedTouches(for: touch) ?? [] where c !== touch {
                guard let (cx, cy) = norm(c.location(in: self)) else { continue }
                onPencil?(.move, cx, cy,
                           min(Double(c.force), 1.0),
                           Double(c.azimuthAngle(in: self)),
                           Double(c.altitudeAngle),
                           rotationDeg)
            }
            return
        }

        defer {
            activePens.remove(id)
            penStrokes.removeValue(forKey: id)
            onProximity?(false, false)
        }

        if let stroke = penStrokes[id], !stroke.sentDown {
            onBarrelButton?(true, nx, ny)
            onBarrelButton?(false, nx, ny)
            return
        }

        onPencil?(.up, nx, ny, 0, azimuth, altitude, rotationDeg)
    }

    private func emitFinger(_ touch: UITouch, event: UIEvent?, phase: String) {
        if phase == "moved", let event {
            for t in event.coalescedTouches(for: touch) ?? [touch] {
                guard let n = norm(t.location(in: self)) else { continue }
                lastFingerNorm = (x: n.0, y: n.1)
                onTouch?("moved", n.0, n.1)
            }
            if let predicted = event.predictedTouches(for: touch)?.last,
               let n = norm(predicted.location(in: self)) {
                onTouch?("moved", n.0, n.1)
            }
            return
        }
        guard let n = norm(touch.location(in: self)) else { return }
        lastFingerNorm = (x: n.0, y: n.1)
        onTouch?(phase, n.0, n.1)
    }

    // MARK: - Gestures

    @objc private func pinchChanged(_ gr: UIPinchGestureRecognizer) {
        guard let (nx, ny) = gestureCentroid(gr) else { return }
        gestureActive = gr.state == .began || gr.state == .changed
        onGesture?(.pinch, gestureState(gr.state),
                   Double(gr.scale), Double(gr.velocity), nx, ny, nil)
        if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
            gestureActive = false
        }
    }

    @objc private func twoFingerTapped(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended, let (nx, ny) = gestureCentroid(gr) else { return }
        onGesture?(.tap, .ended, nil, nil, nx, ny, 2)
    }

    @objc private func threeFingerTapped(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended, let (nx, ny) = gestureCentroid(gr) else { return }
        onGesture?(.tap, .ended, nil, nil, nx, ny, 3)
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        handle(touches, event: event, phase: "began", ended: false)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        handle(touches, event: event, phase: "moved", ended: false)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        handle(touches, event: event, phase: "ended", ended: true)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handle(touches, event: event, phase: "cancelled", ended: true)
    }
}
