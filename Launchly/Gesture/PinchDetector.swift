import CoreGraphics
import Foundation

enum PinchGestureEvent: String {
    case pinchIn
    case pinchOut
}

struct PinchDetector {
    struct Summary {
        let baseline: CGFloat
        let minSpread: CGFloat
        let maxSpread: CGFloat
        let fired: PinchGestureEvent?
    }

    var minFingers = 4
    var ratioIn: CGFloat = 0.88
    var ratioOut: CGFloat = 1.13
    var minAbsDelta: CGFloat = 0.018

    private(set) var active = false
    private var baseline: CGFloat = 0
    private var minSpread: CGFloat = 0
    private var maxSpread: CGFloat = 0
    private var didFire = false
    private var firedEvent: PinchGestureEvent?

    static func thresholds(forSensitivity sensitivity: Double) -> (ratioIn: CGFloat, ratioOut: CGFloat, minAbsDelta: CGFloat) {
        let s = CGFloat(min(max(0.0, sensitivity), 1.0))
        let ratioIn = 0.72 + (0.92 - 0.72) * s
        let ratioOut = 1.28 - (1.28 - 1.09) * s
        let minAbsDelta = 0.035 - (0.035 - 0.014) * s
        return (ratioIn, ratioOut, minAbsDelta)
    }

    mutating func applySensitivity(_ sensitivity: Double) {
        let t = Self.thresholds(forSensitivity: sensitivity)
        ratioIn = t.ratioIn
        ratioOut = t.ratioOut
        minAbsDelta = t.minAbsDelta
    }

    mutating func process(_ points: [CGPoint]) -> (event: PinchGestureEvent?, ended: Summary?) {
        if points.count >= minFingers {
            let current = Self.spread(points)

            if !active {
                active = true
                baseline = current
                minSpread = current
                maxSpread = current
                didFire = false
                firedEvent = nil
                return (nil, nil)
            }

            minSpread = min(minSpread, current)
            maxSpread = max(maxSpread, current)

            if !didFire {
                if current < maxSpread * ratioIn && (maxSpread - current) > minAbsDelta {
                    didFire = true
                    firedEvent = .pinchIn
                    return (.pinchIn, nil)
                } else if current > minSpread * ratioOut && (current - minSpread) > minAbsDelta {
                    didFire = true
                    firedEvent = .pinchOut
                    return (.pinchOut, nil)
                }
            }

            return (nil, nil)
        }

        if points.count == 3 {
            // Ignore transient 3-finger frames while active; 3-point spread isn't comparable to 4-point.
            return (nil, nil)
        }

        if active {
            let summary = Summary(
                baseline: baseline,
                minSpread: minSpread,
                maxSpread: maxSpread,
                fired: firedEvent
            )
            active = false
            baseline = 0
            minSpread = 0
            maxSpread = 0
            didFire = false
            firedEvent = nil
            return (nil, summary)
        }

        return (nil, nil)
    }

    static func spread(_ pts: [CGPoint]) -> CGFloat {
        guard !pts.isEmpty else { return 0 }
        let count = CGFloat(pts.count)
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for p in pts {
            sumX += p.x
            sumY += p.y
        }
        let cx = sumX / count
        let cy = sumY / count
        var total: CGFloat = 0
        for p in pts {
            total += hypot(p.x - cx, p.y - cy)
        }
        return total / count
    }
}
