import Foundation

/// One critically damped spring. It is stepped with the real elapsed time, so
/// uneven ticks do not change the path, and a new target keeps the current
/// velocity: reversing mid-flight turns around smoothly instead of restarting.
struct DampedValue: Equatable {
    var value: Double
    var velocity: Double = 0

    mutating func step(toward target: Double, stiffness: Double, dt: Double) {
        guard dt > 0, stiffness > 0 else { return }
        let offset = value - target
        let decay = exp(-stiffness * dt)
        let k = velocity + stiffness * offset
        value = target + (offset + k * dt) * decay
        velocity = (velocity - stiffness * k * dt) * decay
    }
}

/// The panel frame and its content reveal, moved together. Pure arithmetic: the
/// caller supplies elapsed time and applies `frame` and `reveal`.
struct PanelMotion {
    /// A window frame described by its fixed top edge, which is what stays put.
    struct Frame: Equatable {
        var x: Double
        var top: Double
        var width: Double
        var height: Double
    }

    // Nine tenths of the distance is covered in about 3.9 / stiffness and the last
    // third of a point in about 9 / stiffness: opening is mostly done in 0.14s and
    // lands by 0.32s; closing is quicker, since something leaving should not linger.
    static let expandStiffness = 28.0
    static let collapseStiffness = 36.0
    /// A stalled run loop must not turn into one huge jump.
    static let longestStep = 1.0 / 20.0

    private var x: DampedValue
    private var top: DampedValue
    private var width: DampedValue
    private var height: DampedValue
    private var progress: DampedValue
    private(set) var target: Frame
    private(set) var targetReveal: Double
    private var stiffness = PanelMotion.expandStiffness

    init(frame: Frame, reveal: Double) {
        x = DampedValue(value: frame.x)
        top = DampedValue(value: frame.top)
        width = DampedValue(value: frame.width)
        height = DampedValue(value: frame.height)
        progress = DampedValue(value: min(1, max(0, reveal)))
        target = frame
        targetReveal = progress.value
    }

    mutating func retarget(_ frame: Frame, reveal: Double) {
        target = frame
        targetReveal = reveal >= 0.5 ? 1 : 0
        stiffness = targetReveal == 1 ? PanelMotion.expandStiffness : PanelMotion.collapseStiffness
    }

    mutating func step(dt: Double) {
        let dt = min(PanelMotion.longestStep, max(0, dt))
        x.step(toward: target.x, stiffness: stiffness, dt: dt)
        top.step(toward: target.top, stiffness: stiffness, dt: dt)
        width.step(toward: target.width, stiffness: stiffness, dt: dt)
        height.step(toward: target.height, stiffness: stiffness, dt: dt)
        progress.step(toward: targetReveal, stiffness: stiffness, dt: dt)
    }

    /// Current frame on the half-point grid, never smaller than nothing.
    var frame: Frame {
        func grid(_ value: Double) -> Double { (value * 2).rounded() / 2 }
        return Frame(x: grid(x.value), top: grid(top.value),
                     width: max(1, grid(width.value)), height: max(1, grid(height.value)))
    }

    /// 0 collapsed, 1 expanded. Carried velocity can pass an end slightly; the
    /// content must not see that.
    var reveal: Double { min(1, max(0, progress.value)) }

    /// Close enough that snapping to the target is not visible.
    var isSettled: Bool {
        func rests(_ spring: DampedValue, at goal: Double, within distance: Double, speed: Double) -> Bool {
            abs(spring.value - goal) < distance && abs(spring.velocity) < speed
        }
        return rests(x, at: target.x, within: 0.3, speed: 6) && rests(top, at: target.top, within: 0.3, speed: 6) &&
            rests(width, at: target.width, within: 0.3, speed: 6) && rests(height, at: target.height, within: 0.3, speed: 6) &&
            rests(progress, at: targetReveal, within: 0.004, speed: 0.05)
    }
}

/// How the content follows the reveal. The frame leads; content follows it in,
/// and leaves ahead of it on the way out, so nothing is drawn squeezed.
enum PanelReveal {
    static func smoothstep(_ from: Double, _ to: Double, _ value: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
    /// The task list fades in once there is room for it.
    static func bodyOpacity(_ reveal: Double) -> Double { smoothstep(0.25, 0.8, reveal) }
    /// It settles down into place from slightly above.
    static func bodyOffset(_ reveal: Double) -> Double { -8 * (1 - smoothstep(0, 1, reveal)) }
    /// Tab labels open out as the bar widens enough to hold them.
    static func labelAmount(_ reveal: Double) -> Double { smoothstep(0.2, 0.8, reveal) }
    /// Capsule when compact, panel corners when open.
    static func cornerRadius(_ reveal: Double) -> Double { 17 - 5 * min(1, max(0, reveal)) }
}

/// Dragging the docked island off the camera housing. A docked panel is not movable
/// by its background, so the app moves it itself: a press that travels `threshold`
/// points undocks it, and the floating panel then follows the pointer, which sits in
/// the middle of its bar. Anything less is an ordinary click and passes through.
/// Points are in screen coordinates (y up).
struct DockedDrag: Equatable {
    struct Point: Equatable { var x: Double; var y: Double }
    enum Step: Equatable {
        /// Not a drag of the docked island: deliver the event as usual.
        case pass
        /// Undock now; the floating panel's top centre goes here.
        case undock(Point)
        /// The floating panel's top centre follows to here.
        case move(Point)
        /// Let go: apply the drop rule (dock again, centre, or stay).
        case drop
    }
    static let threshold = 6.0
    /// From the pointer up to the floating bar's top edge: half of its 34 points.
    static let grabHeight = 17.0

    private var start: Point?
    private(set) var isDragging = false

    mutating func pressed(at point: Point, docked: Bool) -> Step {
        start = docked ? point : nil
        isDragging = false
        return .pass
    }
    mutating func dragged(to point: Point) -> Step {
        let anchor = Point(x: point.x, y: point.y + Self.grabHeight)
        if isDragging { return .move(anchor) }
        guard let start, ((point.x - start.x) * (point.x - start.x) + (point.y - start.y) * (point.y - start.y)).squareRoot() >= Self.threshold
        else { return .pass }
        isDragging = true
        return .undock(anchor)
    }
    mutating func released() -> Step {
        defer { start = nil; isDragging = false }
        return isDragging ? .drop : .pass
    }
    mutating func cancel() { start = nil; isDragging = false }
}
