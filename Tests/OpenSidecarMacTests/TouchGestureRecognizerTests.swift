import XCTest

final class TouchGestureRecognizerTests: XCTestCase {

    private let displayW = 1000.0
    private let displayH = 800.0
    private var sink: RecordingTouchGestureSink!
    private var recognizer: TouchGestureRecognizer!

    override func setUp() {
        super.setUp()
        sink = RecordingTouchGestureSink()
        recognizer = TouchGestureRecognizer(
            config: TouchGestureConfig(
                scrollGain: 2.8,
                pinchDistanceThreshold: 1.5,
                rotateMinSeparation: 80,
                rotateAngleThreshold: 0.01
            ),
            sink: sink
        )
    }

    // MARK: - Single finger direct touch

    func testSingleFingerPressDragRelease() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.3, y: 0.4),
        ], ts: 0)

        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.35, y: 0.45),
        ], ts: 0.05)

        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.35, y: 0.45),
        ], ts: 0.10)

        XCTAssertEqual(sink.effects, [
            .pressLeft(x: 0.3, y: 0.4),
            .dragLeft(x: 0.35, y: 0.45),
            .releaseLeft(x: 0.35, y: 0.45),
        ])
    }

    func testSingleFingerTapIsPressAndRelease() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.5, y: 0.5)], ts: 0)
        process(contacts: [contact(id: 1, phase: .ended, x: 0.5, y: 0.5)], ts: 0.05)

        XCTAssertEqual(sink.effects, [
            .pressLeft(x: 0.5, y: 0.5),
            .releaseLeft(x: 0.5, y: 0.5),
        ])
    }

    // MARK: - 1 → 2 finger transition

    func testSecondFingerRetractsFirstPress() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.2, y: 0.3)], ts: 0)
        process(contacts: [contact(id: 1, phase: .moved, x: 0.22, y: 0.32)], ts: 0.05)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.22, y: 0.32),
            contact(id: 2, phase: .began, x: 0.5, y: 0.5),
        ], ts: 0.10)

        XCTAssertTrue(sink.effects.contains(.releaseLeft(x: 0.22, y: 0.32)))
        XCTAssertTrue(sink.effects.contains { effect in
            if case .warpCursor(let x, let y) = effect {
                return abs(x - 0.36) < 0.001 && abs(y - 0.41) < 0.001
            }
            return false
        })
    }

    // MARK: - Two-finger scroll

    func testTwoFingerScrollEmitsPhasedScroll() {
        // Start with two fingers down.
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)

        sink.reset()
        // Move centroid down (increase y) — should scroll.
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.4, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.6, y: 0.5),
        ], ts: 0.05)

        let scrollEffects = sink.effects.compactMap { effect -> TouchGestureEffect? in
            if case .scroll = effect { return effect }
            return nil
        }
        XCTAssertFalse(scrollEffects.isEmpty)
        XCTAssertTrue(scrollEffects.contains { effect in
            if case .scroll(_, let dy, let phase) = effect {
                return phase == .began || (phase == .changed && dy != 0)
            }
            return false
        })

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.5),
        ], ts: 0.10)

        XCTAssertTrue(sink.effects.contains(.scroll(dx: 0, dy: 0, phase: .ended)))
    }

    // MARK: - Two-finger pinch

    func testTwoFingerPinchEmitsMagnify() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.35, y: 0.5),
            contact(id: 2, phase: .began, x: 0.65, y: 0.5),
        ], ts: 0)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.30, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.70, y: 0.5),
        ], ts: 0.05)

        XCTAssertTrue(sink.effects.contains(.magnify(amount: 0, phase: .began)))
        XCTAssertTrue(sink.effects.contains { effect in
            if case .magnify(let amount, .changed) = effect { return amount > 0 }
            return false
        })
    }

    // MARK: - Two-finger tap (iPad-style: no trackpad secondary click)

    func testTwoFingerTapDoesNotRightClick() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.5),
            contact(id: 2, phase: .began, x: 0.6, y: 0.5),
        ], ts: 0)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.5),
        ], ts: 0.05)

        XCTAssertFalse(sink.effects.contains { effect in
            switch effect {
            case .pressLeft, .dragLeft, .releaseLeft, .magnify, .rotate:
                return true
            default:
                return false
            }
        })
    }

    // MARK: - After gesture, remaining finger warps only

    func testRemainingFingerAfterTwoFingerGestureDoesNotPress() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.3, y: 0.5),
            contact(id: 2, phase: .began, x: 0.7, y: 0.5),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.3, y: 0.6),
            contact(id: 2, phase: .moved, x: 0.7, y: 0.6),
        ], ts: 0.05)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.3, y: 0.62),
            contact(id: 2, phase: .ended, x: 0.7, y: 0.6),
        ], ts: 0.10)

        XCTAssertFalse(sink.effects.contains { effect in
            if case .pressLeft = effect { return true }
            return false
        })
        XCTAssertTrue(sink.effects.contains { effect in
            if case .warpCursor = effect { return true }
            return false
        })
    }

    // MARK: - Helpers

    private func contact(id: Int, phase: TouchContactPhase, x: Double, y: Double) -> TouchGestureContact {
        TouchGestureContact(id: id, phase: phase, x: x, y: y)
    }

    private func process(contacts: [TouchGestureContact], ts: TimeInterval) {
        recognizer.process(TouchGestureFrame(
            timestamp: ts,
            displayWidth: displayW,
            displayHeight: displayH,
            contacts: contacts
        ))
    }
}
