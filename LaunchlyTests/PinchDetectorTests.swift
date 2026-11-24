import CoreGraphics
import XCTest

final class PinchDetectorTests: XCTestCase {
    private func squarePoints(spread s: CGFloat, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> [CGPoint] {
        [
            CGPoint(x: center.x - s, y: center.y),
            CGPoint(x: center.x + s, y: center.y),
            CGPoint(x: center.x, y: center.y - s),
            CGPoint(x: center.x, y: center.y + s)
        ]
    }

    func testPinchOutAfterMergedStartFiresOnce() {
        var detector = PinchDetector()
        var events: [PinchGestureEvent] = []

        // 3 frames of 3 merged points before 4th finger registers
        let merged = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 3)
        for _ in 0..<3 {
            let res = detector.process(merged)
            XCTAssertNil(res.event)
            XCTAssertNil(res.ended)
        }

        // 4 points growing from 0.03 to 0.12 over 10 frames
        for step in 0..<10 {
            let spread = 0.03 + (0.09 * CGFloat(step) / 9.0)
            let res = detector.process(squarePoints(spread: spread))
            if let event = res.event {
                events.append(event)
            }
        }

        XCTAssertEqual(events, [.pinchOut])
    }

    func testPinchInFiresOnce() {
        var detector = PinchDetector()
        var events: [PinchGestureEvent] = []

        for step in 0..<10 {
            let spread = 0.15 - (0.10 * CGFloat(step) / 9.0)
            let res = detector.process(squarePoints(spread: spread))
            if let event = res.event {
                events.append(event)
            }
        }

        XCTAssertEqual(events, [.pinchIn])
    }

    func testSlightPinchInAndOutFireQuickly() {
        var detector = PinchDetector()
        var inEvents: [PinchGestureEvent] = []
        // Real resting trackpad pinch: 0.27 -> 0.23 (~15% contraction)
        for step in 0..<6 {
            let spread = 0.27 - (0.04 * CGFloat(step) / 5.0)
            if let e = detector.process(squarePoints(spread: spread)).event {
                inEvents.append(e)
            }
        }
        XCTAssertEqual(inEvents, [.pinchIn])

        _ = detector.process([])

        var outEvents: [PinchGestureEvent] = []
        // Slight outward spread: 0.18 -> 0.21 (~16% expansion)
        for step in 0..<6 {
            let spread = 0.18 + (0.03 * CGFloat(step) / 5.0)
            if let e = detector.process(squarePoints(spread: spread)).event {
                outEvents.append(e)
            }
        }
        XCTAssertEqual(outEvents, [.pinchOut])
    }

    func testJitterDoesNotTriggerEvent() {
        var detector = PinchDetector()
        let offsets: [CGFloat] = [0.0, 0.005, -0.005, 0.004, -0.004, 0.005, -0.005, 0.0]

        for offset in offsets {
            let res = detector.process(squarePoints(spread: 0.10 + offset))
            XCTAssertNil(res.event)
        }
    }

    func testLiftReturnsSummaryAndAllowsNextGesture() {
        var detector = PinchDetector()

        // First gesture: pinch in
        var firedFirst = false
        for step in 0..<8 {
            let spread = 0.15 - (0.10 * CGFloat(step) / 7.0)
            if detector.process(squarePoints(spread: spread)).event == .pinchIn {
                firedFirst = true
            }
        }
        XCTAssertTrue(firedFirst)

        // Lift fingers -> summary returned
        let lifted = detector.process([])
        XCTAssertNil(lifted.event)
        XCTAssertNotNil(lifted.ended)
        XCTAssertEqual(lifted.ended?.fired, .pinchIn)
        XCTAssertFalse(detector.active)

        // Second gesture: pinch out
        var firedSecond = false
        for step in 0..<8 {
            let spread = 0.03 + (0.10 * CGFloat(step) / 7.0)
            if detector.process(squarePoints(spread: spread)).event == .pinchOut {
                firedSecond = true
            }
        }
        XCTAssertTrue(firedSecond)
    }
}
