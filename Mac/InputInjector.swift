import CoreGraphics
import AppKit

/// Turns normalized input from the phone into mouse / tablet events on the
/// target display. Pencil events use Core Graphics tablet proximity + tablet
/// point mouse subtypes; fingers use left-button mouse events.
final class InputInjector {

    private let displayID: CGDirectDisplayID
    private let source: CGEventSource
    private var inRange = false
    private var penDown = false
    private var fingerDown = false
    private var eraser = false

    private let deviceID: Int64 = 1
    private let vendorID: Int64 = 0x056A
    private let capabilityMask: Int64 = 0x00FE

    private var lastPenEvent = Date.distantPast
    private let idleTimeoutSeconds: TimeInterval = 0.15
    private var idleTimer: DispatchSourceTimer?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        if let s = CGEventSource(stateID: .hidSystemState) {
            source = s
        } else if let s = CGEventSource(stateID: .combinedSessionState) {
            source = s
        } else {
            fatalError("Could not create CGEventSource")
        }
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    // MARK: - JSON dispatch (phone → Mac control channel)

    func handleControl(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        logRecv(type, obj)
        switch type {
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                handleTouch(phase: phase, x: x, y: y)
            }
        case WireInput.pencil:
            handlePencil(obj)
        case WireInput.proximity:
            if let entering = obj["entering"] as? Bool {
                handleProximity(entering: entering, eraser: obj["eraser"] as? Bool ?? false)
            }
        case WireInput.gesture:
            handleGesture(obj)
        case WireInput.barrelButton:
            if let down = obj["down"] as? Bool {
                handleBarrelButton(down: down,
                                   x: obj["x"] as? Double,
                                   y: obj["y"] as? Double)
            }
        case "scroll":
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                handleScroll(dx: dx, dy: dy)
            }
        default:
            break
        }
    }

    // MARK: - Proximity

    private func handleProximity(entering: Bool, eraser: Bool) {
        if entering {
            if !inRange || eraser != self.eraser {
                postProximity(entering: true, eraser: eraser)
                self.eraser = eraser
                inRange = true
                logState("prox enter")
            }
        } else {
            if penDown {
                logState("prox exit while penDown — forcing up")
                postTabletPoint(phase: .up, x: nil, y: nil, pressure: 0,
                                tiltX: 0, tiltY: 0, rotation: 0)
                penDown = false
            }
            postProximity(entering: false, eraser: self.eraser)
            inRange = false
            logState("prox exit")
        }
    }

    // MARK: - Pen

    private func handlePencil(_ obj: [String: Any]) {
        guard let phaseStr = obj["phase"] as? String,
              let phase = PencilPhase(rawValue: phaseStr),
              let x = obj["x"] as? Double,
              let y = obj["y"] as? Double else { return }

        let pressure = obj["pressure"] as? Double ?? 0
        let azimuth = obj["azimuth"] as? Double ?? 0
        let altitude = obj["altitude"] as? Double ?? (.pi / 2)
        let rotation = obj["rotation"] as? Double ?? 0
        let (tiltX, tiltY) = deriveTilt(azimuth: azimuth, altitude: altitude)

        if !inRange {
            postProximity(entering: true, eraser: false)
            inRange = true
            eraser = false
        }

        switch phase {
        case .down:
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            penDown = true
            logState("pencil down p=\(String(format: "%.2f", pressure))")
        case .move:
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            }
        case .up:
            postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            penDown = false
            logState("pencil up")
        case .hover:
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: rotation)
        }

        lastPenEvent = Date()
        if penDown && idleTimer == nil { startIdleTimer() }
    }

    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = max(0, Double.pi / 2 - altitude)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    // MARK: - Touch (single-finger mouse)

    func handleTouch(phase: String, x: Double, y: Double) {
        let p = screenPoint(nx: x, ny: y)
        let type: CGEventType
        switch phase {
        case "began":
            type = .leftMouseDown
            fingerDown = true
            logState("finger began @ \(fmt(p))")
        case "moved":
            type = fingerDown ? .leftMouseDragged : .mouseMoved
        case "ended", "cancelled":
            guard fingerDown else {
                logState("finger \(phase) IGNORED (not down) @ \(fmt(p))")
                return
            }
            type = .leftMouseUp
            fingerDown = false
            logState("finger \(phase) @ \(fmt(p))")
        default:
            logState("finger unknown phase \(phase)")
            return
        }
        postMouse(type: type, at: p, button: .left)
    }

    // MARK: - Gestures

    private func handleGesture(_ obj: [String: Any]) {
        guard let kindStr = obj["kind"] as? String,
              let kind = GestureKind(rawValue: kindStr),
              let stateStr = obj["state"] as? String,
              let state = GestureState(rawValue: stateStr) else { return }

        switch kind {
        case .tap:
            handleTapGesture(state: state, fingerCount: obj["fingerCount"] as? Int)
        case .pinch:
            logState("pinch gesture ignored (disabled)")
        case .rotate, .pan, .longPress, .swipe:
            break
        }
    }

    private func handleTapGesture(state: GestureState, fingerCount: Int?) {
        guard state == .ended else { return }
        switch fingerCount {
        case 2:
            logState("gesture undo (Cmd+Z)")
            postKeyCommand(keyCode: 0x06, flags: .command)
        case 3:
            logState("gesture redo (Cmd+Shift+Z)")
            postKeyCommand(keyCode: 0x06, flags: [.command, .shift])
        default:
            break
        }
    }

    private func handleBarrelButton(down: Bool, x: Double?, y: Double?) {
        logState("barrelButton down=\(down) x=\(x ?? -1) y=\(y ?? -1)")
        postRightClick(down: down, x: x, y: y)
    }

    /// dx/dy in display pixels, natural-scrolling sign from the phone.
    func handleScroll(dx: Double, dy: Double) {
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? Double(CGDisplayPixelsWide(displayID)) / bounds.width : 2
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((dy / scale).rounded()),
                                  wheel2: Int32((dx / scale).rounded()),
                                  wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Idle-timeout safety net

    private func startIdleTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.checkIdle() }
        t.activate()
        idleTimer = t
    }

    private func checkIdle() {
        guard penDown else { return }
        if Date().timeIntervalSince(lastPenEvent) > idleTimeoutSeconds {
            logState("idle timeout — forcing pen up")
            postTabletPoint(phase: .up, x: nil, y: nil, pressure: 0,
                            tiltX: 0, tiltY: 0, rotation: 0)
            penDown = false
        }
    }

    // MARK: - CGEvent posting

    private enum PointPhase { case down, drag, up, hover }

    private func postProximity(entering: Bool, eraser: Bool) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: eraser ? 3 : 1)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        ev.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 1)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        logPost("tabletProximity entering=\(entering) eraser=\(eraser)", flags: ev.flags)
        ev.post(tap: .cghidEventTap)
    }

    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        if phase == .down || phase == .up {
            ev.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        if phase == .down || phase == .up {
            logPost("tablet \(phase) p=\(String(format: "%.2f", pressure))", at: p, button: .left,
                     subtype: "tabletPoint", flags: ev.flags)
        }
        ev.post(tap: .cghidEventTap)
    }

    private func postMouse(type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        let isMove = type == .leftMouseDragged || type == .mouseMoved
        if !isMove || button == .right {
            logPost("mouse \(type.rawValue)", at: p, button: button, flags: ev.flags)
        }
        ev.post(tap: .cghidEventTap)
    }

    private func postRightClick(down: Bool, x: Double?, y: Double?) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }
        let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
        postMouse(type: type, at: p, button: .right)
    }

    private func postKeyCommand(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode),
                                 keyDown: true) else { return }
        down.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        logPost("keyDown vk=\(keyCode)", flags: down.flags)
        down.post(tap: .cghidEventTap)

        guard let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode),
                               keyDown: false) else { return }
        up.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        logPost("keyUp vk=\(keyCode)", flags: up.flags)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Coordinate mapping

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    private func currentCursor() -> CGPoint {
        CGEvent(source: source)?.location ?? .zero
    }

    // MARK: - Input debug logging

    private func logRecv(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double, let y = obj["y"] as? Double {
                if phase != "moved" {
                    Log.info("[input] recv touch \(phase) @ \(fmtPt(x, y)) | \(stateLine())")
                }
            }
        case WireInput.pencil:
            let phase = obj["phase"] as? String ?? "?"
            if phase != "move" && phase != "hover" {
                let x = obj["x"] as? Double ?? 0, y = obj["y"] as? Double ?? 0
                let p = obj["pressure"] as? Double ?? 0
                Log.info("[input] recv pencil \(phase) @ \(fmtPt(x, y)) p=\(String(format: "%.2f", p)) | \(stateLine())")
            }
        case WireInput.proximity:
            Log.info("[input] recv proximity entering=\(obj["entering"] ?? "?") eraser=\(obj["eraser"] ?? "?") | \(stateLine())")
        case WireInput.gesture:
            Log.info("[input] recv gesture \(obj["kind"] ?? "?") \(obj["state"] ?? "?") fingers=\(obj["fingerCount"] ?? "-") | \(stateLine())")
        case WireInput.barrelButton:
            Log.info("[input] recv barrelButton down=\(obj["down"] ?? "?") | \(stateLine())")
        default:
            break
        }
    }

    private func logState(_ note: String) {
        Log.info("[input] \(note) | \(stateLine())")
    }

    private func stateLine() -> String {
        "state penDown=\(penDown) fingerDown=\(fingerDown) inRange=\(inRange)"
    }

    private func fmt(_ p: CGPoint) -> String {
        "\(Int(p.x)),\(Int(p.y))"
    }

    private func fmtPt(_ x: Double, _ y: Double) -> String {
        let p = screenPoint(nx: x, ny: y)
        return fmt(p)
    }

    private func logPost(_ label: String, at p: CGPoint? = nil, button: CGMouseButton? = nil,
                         subtype: String? = nil, flags: CGEventFlags = []) {
        var parts = [label]
        if let p { parts.append("@ \(fmt(p))") }
        if let button { parts.append("btn=\(button.rawValue)") }
        if let subtype { parts.append("sub=\(subtype)") }
        if !flags.isEmpty { parts.append("flags=0x\(String(flags.rawValue, radix: 16))") }
        parts.append("| \(stateLine())")
        Log.info("[input] post " + parts.joined(separator: " "))
    }
}
