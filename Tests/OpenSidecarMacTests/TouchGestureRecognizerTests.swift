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
                pinchDistanceThreshold: 1.5,
                gestureSettleDefer: 0.045
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
            .warpCursor(x: 0.3, y: 0.4),
            .warpCursor(x: 0.35, y: 0.45),
            .pressLeft(x: 0.35, y: 0.45),
            .dragLeft(x: 0.35, y: 0.45),
            .releaseLeft(x: 0.35, y: 0.45),
        ])
    }

    func testSingleFingerTapIsPressAndRelease() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.5, y: 0.5)], ts: 0)
        process(contacts: [contact(id: 1, phase: .ended, x: 0.5, y: 0.5)], ts: 0.02)

        XCTAssertEqual(sink.effects, [
            .warpCursor(x: 0.5, y: 0.5),
            .pressLeft(x: 0.5, y: 0.5),
            .releaseLeft(x: 0.5, y: 0.5),
        ])
    }

    func testDeferredSinglePressCommitsAfterDeferWindow() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.2, y: 0.3)], ts: 0)
        sink.reset()

        // Still within defer — warp only.
        process(contacts: [contact(id: 1, phase: .moved, x: 0.21, y: 0.31)], ts: 0.02)
        XCTAssertFalse(sink.effects.contains { effect in
            if case .pressLeft = effect { return true }
            return false
        })
        XCTAssertTrue(sink.effects.contains(.warpCursor(x: 0.21, y: 0.31)))

        sink.reset()
        // Past defer — press commits at current position.
        process(contacts: [contact(id: 1, phase: .moved, x: 0.22, y: 0.32)], ts: 0.05)
        XCTAssertTrue(sink.effects.contains(.pressLeft(x: 0.22, y: 0.32)))
    }

    // MARK: - 1 → 2 finger transition

    func testStaggeredTwoFingerWithinDeferDoesNotDraw() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.2, y: 0.3)], ts: 0)
        process(contacts: [contact(id: 1, phase: .moved, x: 0.22, y: 0.32)], ts: 0.02)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.22, y: 0.32),
            contact(id: 2, phase: .began, x: 0.5, y: 0.5),
        ], ts: 0.03)

        XCTAssertFalse(sink.effects.contains { effect in
            switch effect {
            case .pressLeft, .dragLeft, .releaseLeft:
                return true
            default:
                return false
            }
        })
        XCTAssertTrue(sink.effects.contains { effect in
            if case .warpCursor(let x, let y) = effect {
                return abs(x - 0.36) < 0.001 && abs(y - 0.41) < 0.001
            }
            return false
        })
    }

    func testSecondFingerRetractsFirstPressAfterDefer() {
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
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)

        sink.reset()
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
        // Fingers moved down (+y) — scroll dy should match display-point travel (1:1).
        let changedScroll = scrollEffects.compactMap { effect -> (Double, Double)? in
            if case .scroll(let dx, let dy, let phase) = effect, phase == .changed { return (dx, dy) }
            return nil
        }
        XCTAssertFalse(changedScroll.isEmpty)
        XCTAssertEqual(changedScroll[0].0, 0, accuracy: 0.001)
        XCTAssertEqual(changedScroll[0].1, 80, accuracy: 0.001)

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

    func testPanWithSeparationJitterDoesNotMagnify() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.395, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.605, y: 0.5),
        ], ts: 0.05)

        XCTAssertTrue(sink.effects.contains { effect in
            if case .scroll(_, _, let phase) = effect {
                return phase == .began || phase == .changed
            }
            return false
        })
        XCTAssertFalse(sink.effects.contains { effect in
            if case .magnify = effect { return true }
            return false
        })
    }

    func testCombinedPanAndPinchEmitsBoth() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.35, y: 0.4),
            contact(id: 2, phase: .began, x: 0.65, y: 0.4),
        ], ts: 0)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.30, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.70, y: 0.5),
        ], ts: 0.05)

        let magnifyIndices = sink.effects.enumerated().compactMap { index, effect -> Int? in
            if case .magnify = effect { return index }
            return nil
        }
        let scrollIndices = sink.effects.enumerated().compactMap { index, effect -> Int? in
            if case .scroll = effect { return index }
            return nil
        }

        XCTAssertFalse(magnifyIndices.isEmpty)
        XCTAssertFalse(scrollIndices.isEmpty)
        XCTAssertLessThan(magnifyIndices.max()!, scrollIndices.min()!)

        XCTAssertTrue(sink.effects.contains { effect in
            if case .magnify(_, .changed) = effect { return true }
            return false
        })
        XCTAssertTrue(sink.effects.contains { effect in
            if case .scroll(_, _, .changed) = effect { return true }
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

    // MARK: - Tap → undo / redo

    func testTwoFingerTapEmitsUndo() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.5),
            contact(id: 2, phase: .began, x: 0.6, y: 0.5),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.5),
        ], ts: 0.05)

        XCTAssertTrue(sink.effects.contains(.undo))
        XCTAssertFalse(sink.effects.contains(.redo))
    }

    func testThreeFingerTapEmitsRedo() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.3, y: 0.5),
            contact(id: 2, phase: .began, x: 0.5, y: 0.5),
            contact(id: 3, phase: .began, x: 0.7, y: 0.5),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.3, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.5, y: 0.5),
            contact(id: 3, phase: .ended, x: 0.7, y: 0.5),
        ], ts: 0.05)

        XCTAssertTrue(sink.effects.contains(.redo))
        XCTAssertFalse(sink.effects.contains(.undo))
    }

    func testStaggeredThreeFingerTapEmitsRedoWithoutScroll() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.3, y: 0.5)], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.3, y: 0.5),
            contact(id: 2, phase: .began, x: 0.5, y: 0.5),
        ], ts: 0.02)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.3, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.5, y: 0.5),
            contact(id: 3, phase: .began, x: 0.7, y: 0.5),
        ], ts: 0.04)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.3, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.5, y: 0.5),
            contact(id: 3, phase: .ended, x: 0.7, y: 0.5),
        ], ts: 0.06)

        XCTAssertTrue(sink.effects.contains(.redo))
        XCTAssertFalse(sink.effects.contains(.undo))
        XCTAssertFalse(sink.effects.contains { effect in
            switch effect {
            case .scroll, .magnify, .rotate:
                return true
            default:
                return false
            }
        })
    }

    func testStaggeredThreeFingerViaTwoDoesNotManipulate() {
        process(contacts: [contact(id: 1, phase: .began, x: 0.3, y: 0.5)], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.32, y: 0.52),
            contact(id: 2, phase: .began, x: 0.5, y: 0.5),
        ], ts: 0.02)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.32, y: 0.52),
            contact(id: 2, phase: .moved, x: 0.52, y: 0.52),
            contact(id: 3, phase: .began, x: 0.7, y: 0.5),
        ], ts: 0.04)

        XCTAssertFalse(sink.effects.contains { effect in
            switch effect {
            case .scroll, .magnify, .rotate:
                return true
            default:
                return false
            }
        })
    }

    func testTwoFingerPanStillWorksAfterSettle() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)

        sink.reset()
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.4, y: 0.5),
            contact(id: 2, phase: .moved, x: 0.6, y: 0.5),
        ], ts: 0.05)

        XCTAssertTrue(sink.effects.contains { effect in
            if case .scroll(_, _, let phase) = effect {
                return phase == .began || phase == .changed
            }
            return false
        })
        XCTAssertFalse(sink.effects.contains(.undo))
    }

    func testTwoFingerPanIsNotMistakenForTap() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.4, y: 0.6),
            contact(id: 2, phase: .moved, x: 0.6, y: 0.6),
        ], ts: 0.05)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.6),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.6),
        ], ts: 0.10)

        XCTAssertFalse(sink.effects.contains(.undo))
        XCTAssertFalse(sink.effects.contains(.redo))
    }

    func testSlowTwoFingerHoldIsNotUndo() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.5),
            contact(id: 2, phase: .began, x: 0.6, y: 0.5),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.5),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.5),
        ], ts: 1.0)

        XCTAssertFalse(sink.effects.contains(.undo))
    }

    func testSingleFingerTapWorksAfterTwoFingerGesture() {
        process(contacts: [
            contact(id: 1, phase: .began, x: 0.4, y: 0.4),
            contact(id: 2, phase: .began, x: 0.6, y: 0.4),
        ], ts: 0)
        process(contacts: [
            contact(id: 1, phase: .moved, x: 0.4, y: 0.6),
            contact(id: 2, phase: .moved, x: 0.6, y: 0.6),
        ], ts: 0.05)
        process(contacts: [
            contact(id: 1, phase: .ended, x: 0.4, y: 0.6),
            contact(id: 2, phase: .ended, x: 0.6, y: 0.6),
        ], ts: 0.10)

        sink.reset()
        process(contacts: [contact(id: 3, phase: .began, x: 0.5, y: 0.5)], ts: 1.0)
        process(contacts: [contact(id: 3, phase: .ended, x: 0.5, y: 0.5)], ts: 1.02)

        XCTAssertEqual(sink.effects, [
            .warpCursor(x: 0.5, y: 0.5),
            .pressLeft(x: 0.5, y: 0.5),
            .releaseLeft(x: 0.5, y: 0.5),
        ])
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
