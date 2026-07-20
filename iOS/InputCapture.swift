// InputCaptureEngine: Apple Pencil + raw finger contacts.
// Installed on VideoView (not a separate overlay) so hit-testing matches
// the pre-port behavior that finger touches relied on.

import UIKit

/// Captures pencil, hover, and finger contact frames. Coordinates are normalized
/// [0,1] in video space (origin top-left) via the host view's normalize closure.
final class InputCaptureEngine: NSObject {
    var onTouches: ((_ contacts: [WireTouchContact], _ osMs: Double, _ captureMs: Double) -> Void)?
    var onPencil: ((_ phase: PencilPhase, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double,
                    _ rotation: Double, _ osMs: Double, _ captureMs: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ eraser: Bool) -> Void)?

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var hoverInRange = false
    private var penStrokes: [UInt64: PenStroke] = [:]
    private let tapMoveThreshold: CGFloat = 8
    private var touchIds: [ObjectIdentifier: Int] = [:]
    private var nextTouchId = 1

    private struct PenStroke {
        var start: CGPoint
        var sentDown: Bool
        var proximitySent: Bool
    }

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        view.addGestureRecognizer(hover)
    }

    private func norm(_ p: CGPoint) -> (Double, Double)? {
        guard let n = normalize?(p) else { return nil }
        return (n.x, n.y)
    }

    private func emitTouches(_ contacts: [WireTouchContact], osDeliveredMs: Double) {
        guard !contacts.isEmpty else { return }
        let captureMs = Date().timeIntervalSince1970 * 1000
        onTouches?(contacts, osDeliveredMs, captureMs)
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

    private func isFinger(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .direct: return true
        default:
            if #available(iOS 17.0, *), touch.type == .indirectPointer { return true }
            return false
        }
    }

    private func touchId(for touch: UITouch) -> Int {
        let key = ObjectIdentifier(touch)
        if let existing = touchIds[key] { return existing }
        let id = nextTouchId
        nextTouchId += 1
        touchIds[key] = id
        return id
    }

    private func releaseTouchId(_ touch: UITouch) {
        touchIds.removeValue(forKey: ObjectIdentifier(touch))
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, phase: String, ended: Bool,
                osDeliveredMs: Double) {
        guard let view = hostView else { return }

        var fingerContacts: [WireTouchContact] = []
        let allFingerTouches = (event?.allTouches ?? touches).filter { isFinger($0) }

        for touch in allFingerTouches {
            let contactPhase: TouchContactPhase
            if touches.contains(touch) {
                if ended {
                    contactPhase = phase == "cancelled" ? .cancelled : .ended
                } else if phase == "began" {
                    contactPhase = .began
                } else {
                    contactPhase = .moved
                }
            } else if touch.phase == .stationary || touch.phase == .began || touch.phase == .moved {
                contactPhase = .moved
            } else {
                continue
            }

            let locations: [CGPoint]
            if touches.contains(touch), phase == "moved", let event {
                locations = (event.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: view) }
            } else {
                locations = [touch.location(in: view)]
            }

            for loc in locations {
                guard let (nx, ny) = norm(loc) else { continue }
                let major = normalizedMajorRadius(touch, in: view)
                fingerContacts.append(WireTouchContact(id: touchId(for: touch),
                                                         phase: contactPhase,
                                                         x: nx, y: ny,
                                                         major: major))
            }

            if contactPhase == .ended || contactPhase == .cancelled {
                releaseTouchId(touch)
            }
        }

        if !fingerContacts.isEmpty {
            logCapture("touches \(fingerContacts.count) contacts")
            emitTouches(fingerContacts, osDeliveredMs: osDeliveredMs)
        }

        for touch in touches {
            switch touch.type {
            case .pencil, .stylus:
                emitPen(touch, event: event, ended: ended, osDeliveredMs: osDeliveredMs)
            default:
                break
            }
        }
    }

    private func normalizedMajorRadius(_ touch: UITouch, in view: UIView) -> Double {
        let radius = touch.majorRadius
        guard radius > 0, view.bounds.width > 0 else { return 0.02 }
        return min(0.15, Double(radius / view.bounds.width))
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
            penStrokes[id] = PenStroke(start: loc, sentDown: false, proximitySent: false)
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
                if !stroke.proximitySent {
                    onProximity?(true, false)
                    stroke.proximitySent = true
                }
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
            if let stroke = penStrokes[id], stroke.proximitySent {
                onProximity?(false, false)
            }
            penStrokes.removeValue(forKey: id)
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

    private func logCapture(_ message: String) {
        Log.info("[input] capture \(message)")
    }

    private func fmt(_ x: Double, _ y: Double) -> String {
        String(format: "%.3f,%.3f", x, y)
    }
}
