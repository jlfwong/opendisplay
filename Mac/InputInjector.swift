import CoreGraphics
import AppKit

/// Turns normalized input from the phone into mouse / tablet events on the
/// target display. Pencil events use Core Graphics tablet proximity + tablet
/// point mouse subtypes; fingers use left-button mouse events.
final class InputInjector {

    /// Wall-clock ms when the last touch/pencil event was injected (Mac clock).
    private(set) var lastInjectMs: Double = 0
    var isPenDown: Bool { penDown }
    var isFingerDown: Bool { fingerDown }

    private let displayID: CGDirectDisplayID
    private let source: CGEventSource
    private var inRange = false
    private var penDown = false
    private var fingerDown = false
    private var touchLeftDown = false
    private var eraser = false
    /// True when the current pen contact is a zero-pressure tap (mouse, not tablet).
    private var pencilTapMode = false

    private let touchRecognizer: TouchGestureRecognizer
    private let touchSink: InputInjectorTouchSink

    private let deviceID: Int64 = 1

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        if let s = CGEventSource(stateID: .hidSystemState) {
            source = s
        } else if let s = CGEventSource(stateID: .combinedSessionState) {
            source = s
        } else {
            fatalError("Could not create CGEventSource")
        }
        let sink = InputInjectorTouchSink()
        self.touchSink = sink
        touchRecognizer = TouchGestureRecognizer(config: TouchGestureConfig(), sink: sink)
        sink.injector = self
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
        case WireInput.touches:
            handleTouches(obj)
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
        // Track pen-in-range internally. Posting tabletProximity CGEvents causes
        // macOS to interpret rapid enter/exit as system gestures (Show Desktop).
        if entering {
            if !inRange || eraser != self.eraser {
                self.eraser = eraser
                inRange = true
                logState("prox enter (wire)")
            }
        } else {
            guard inRange else { return }
            inRange = false
            logState("prox exit (wire)")
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

        switch phase {
        case .down:
            if pressure < 0.01 {
                pencilTapMode = true
                postMouse(type: .leftMouseDown, at: screenPoint(nx: x, ny: y), button: .left)
            } else {
                pencilTapMode = false
                postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            }
            penDown = true
            logState("pencil down p=\(String(format: "%.2f", pressure)) tap=\(pencilTapMode)")
        case .move:
            pencilTapMode = false
            if penDown {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            } else {
                postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y), button: .left)
            }
        case .up:
            if pencilTapMode {
                postMouse(type: .leftMouseUp, at: screenPoint(nx: x, ny: y), button: .left)
                pencilTapMode = false
            } else {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: rotation)
            }
            penDown = false
            logState("pencil up")
        case .hover:
            postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y), button: .left)
        }

        markInjected()
    }

    private func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = max(0, Double.pi / 2 - altitude)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    // MARK: - Multi-touch (gesture recognizer)

    private func handleTouches(_ obj: [String: Any]) {
        guard let arr = obj["contacts"] as? [[String: Any]], !arr.isEmpty else { return }

        var contacts: [TouchGestureContact] = []
        var anyActive = false
        for c in arr {
            guard let id = c["id"] as? Int,
                  let phaseStr = c["phase"] as? String,
                  let phase = TouchContactPhase(rawValue: phaseStr),
                  let x = c["x"] as? Double,
                  let y = c["y"] as? Double else { continue }
            contacts.append(TouchGestureContact(id: id, phase: phase, x: x, y: y))
            if phase == .began || phase == .moved { anyActive = true }
        }
        guard !contacts.isEmpty else { return }

        let bounds = CGDisplayBounds(displayID)
        let emitted = touchRecognizer.process(TouchGestureFrame(
            timestamp: Date().timeIntervalSince1970,
            displayWidth: Double(bounds.width),
            displayHeight: Double(bounds.height),
            contacts: contacts
        ))

        fingerDown = anyActive || touchLeftDown

        if contacts.contains(where: { $0.phase == .began }) {
            logState("touches began (\(contacts.count) contacts)")
        } else if !anyActive {
            logState("touches ended (\(contacts.count) contacts)")
        }
        if emitted { markInjected() }
    }

    // MARK: - Touch gesture effects (called by InputInjectorTouchSink)

    fileprivate func applyTouchEffect(_ effect: TouchGestureEffect) {
        switch effect {
        case .pressLeft(let x, let y):
            touchLeftDown = true
            postMouse(type: .leftMouseDown, at: screenPoint(nx: x, ny: y), button: .left)
        case .dragLeft(let x, let y):
            postMouse(type: .leftMouseDragged, at: screenPoint(nx: x, ny: y), button: .left)
        case .releaseLeft(let x, let y):
            touchLeftDown = false
            postMouse(type: .leftMouseUp, at: screenPoint(nx: x, ny: y), button: .left)
        case .warpCursor(let x, let y):
            postMouse(type: .mouseMoved, at: screenPoint(nx: x, ny: y), button: .left)
        case .magnify(let amount, let phase):
            postMagnify(amount: amount, phase: phase)
        case .rotate(let degrees, let phase):
            postRotate(degrees: degrees, phase: phase)
        case .scroll(let dx, let dy, let phase):
            postScrollPhased(dx: dx, dy: dy, phase: phase)
        case .undo:
            logState("two-finger tap → undo (Cmd+Z)")
            postKeyCommand(keyCode: 0x06, flags: .command)
        case .redo:
            logState("three-finger tap → redo (Cmd+Shift+Z)")
            postKeyCommand(keyCode: 0x06, flags: [.command, .shift])
        }
    }

    // MARK: - Touch (single-finger mouse, legacy wire)

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
        markInjected()
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
        postScrollPhased(dx: dx, dy: dy, phase: .changed)
    }

    private enum GestureEventField: Int {
        case subtype = 110
        case phase = 132
        case value = 113
    }

    private enum GestureSubtype: Int64 {
        case rotate = 5
        case magnify = 8
    }

    private static let gestureEventType = CGEventType(rawValue: 29)!

    private func gestureField(_ raw: Int) -> CGEventField {
        CGEventField(rawValue: UInt32(raw))!
    }

    private func nsPhase(_ phase: TouchGesturePhase) -> Int64 {
        switch phase {
        case .began: return 1
        case .changed: return 4
        case .ended: return 8
        }
    }

    private func postMagnify(amount: Double, phase: TouchGesturePhase) {
        guard let event = CGEvent(source: source) else { return }
        event.type = Self.gestureEventType
        event.setIntegerValueField(gestureField(GestureEventField.subtype.rawValue),
                                   value: GestureSubtype.magnify.rawValue)
        event.setIntegerValueField(gestureField(GestureEventField.phase.rawValue),
                                   value: nsPhase(phase))
        event.setDoubleValueField(gestureField(GestureEventField.value.rawValue), value: amount)
        event.post(tap: .cghidEventTap)
    }

    private func postRotate(degrees: Double, phase: TouchGesturePhase) {
        guard let event = CGEvent(source: source) else { return }
        event.type = Self.gestureEventType
        event.setIntegerValueField(gestureField(GestureEventField.subtype.rawValue),
                                   value: GestureSubtype.rotate.rawValue)
        event.setIntegerValueField(gestureField(GestureEventField.phase.rawValue),
                                   value: nsPhase(phase))
        event.setDoubleValueField(gestureField(GestureEventField.value.rawValue), value: degrees)
        event.post(tap: .cghidEventTap)
    }

    private func postScrollPhased(dx: Double, dy: Double, phase: TouchGesturePhase) {
        let scrollPhase: CGScrollPhase
        switch phase {
        case .began: scrollPhase = .began
        case .changed: scrollPhase = .changed
        case .ended: scrollPhase = .ended
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy.rounded()),
                                  wheel2: Int32(dx.rounded()),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase.rawValue))
        let fixed1 = Int64((dy * 65536.0).rounded())
        let fixed2 = Int64((dx * 65536.0).rounded())
        if let axis1 = CGEventField(rawValue: 93) { event.setIntegerValueField(axis1, value: fixed1) }
        if let axis2 = CGEventField(rawValue: 94) { event.setIntegerValueField(axis2, value: fixed2) }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - CGEvent posting

    private enum PointPhase { case down, drag, up, hover }

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
        ev.flags = .maskNonCoalesced
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
        // Don't inherit stale modifier / secondary-button state from the event source.
        ev.flags = .maskNonCoalesced
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

    private func markInjected() {
        lastInjectMs = Date().timeIntervalSince1970 * 1000
    }

    // MARK: - Coordinate mapping

    /// Map video-normalized coords (origin top-left on the iPad) to global
    /// screen points on the virtual display. This pipeline's captured frame
    /// and touch normalization share the same top-down Y axis, so no flip.
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
        case WireInput.touches:
            if let contacts = obj["contacts"] as? [[String: Any]] {
                let wirePhase = obj["phase"] as? String ?? "?"
                if wirePhase != "moved" {
                    Log.info("[input] recv touches \(wirePhase) n=\(contacts.count) | \(stateLine())")
                }
            }
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

// MARK: - Touch gesture sink

private final class InputInjectorTouchSink: TouchGestureSink {
    weak var injector: InputInjector?

    func emit(_ effect: TouchGestureEffect) {
        injector?.applyTouchEffect(effect)
    }
}
