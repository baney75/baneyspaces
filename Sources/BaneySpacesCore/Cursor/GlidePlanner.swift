import CoreGraphics
import Foundation

/// The spring behind the agent cursor's glide: `animation.cursor.glide` in spec/config.md. `response` is the
/// period of the undamped spring in seconds (SwiftUI's meaning), `damping` the damping ratio (1 = no overshoot).
public struct GlideSpring: Equatable, Codable, Sendable {
    public var response: Double
    public var damping: Double

    public init(response: Double, damping: Double) { self.response = response; self.damping = damping }

    /// The `baneyspaces` preset: about 150 ms to reach an element from across the screen, no visible overshoot.
    public static let baneyspaces = GlideSpring(response: 0.13, damping: 0.85)
    public static let responseRange: ClosedRange<Double> = 0.04...0.6
    public static let dampingRange: ClosedRange<Double> = 0.3...2.0

    /// The spring of an `animation.preset`; nil for a name that is no preset. `off` is instant.
    public static func preset(_ name: String) -> GlideSpring? {
        switch name {
        case "baneyspaces": return .baneyspaces
        case "omarchy": return GlideSpring(response: 0.2, damping: 1.0)
        case "snappy": return GlideSpring(response: 0.08, damping: 1.0)
        case "smooth": return GlideSpring(response: 0.17, damping: 0.8)
        case "off": return .instant
        default: return nil
        }
    }

    /// No glide at all: the cursor lands where it is going.
    public static let instant = GlideSpring(response: 0, damping: 1)
    public var isInstant: Bool { response <= 0 }

    public var clamped: GlideSpring {
        isInstant ? self : GlideSpring(response: min(Self.responseRange.upperBound, max(Self.responseRange.lowerBound, response)),
                                       damping: min(Self.dampingRange.upperBound, max(Self.dampingRange.lowerBound, damping)))
    }
}

/// Where the cursor is and how fast it moves (points and points per second).
public struct GlideState: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public init(position: CGPoint, velocity: CGVector = .zero) { self.position = position; self.velocity = velocity }
}

/// One timed point of a glide, for the layer's keyframes.
public struct GlideSample: Equatable, Sendable {
    public var time: TimeInterval
    public var position: CGPoint
}

/// A glide from a state to a target: the closed-form solution of a damped spring on each axis, so any moment's
/// position and velocity are exact. A new target mid-glide is `retarget(at:to:)`: the next plan starts at the
/// current position with the current velocity, so nothing jumps and nothing restarts (spec/config.md, quality bar 4).
public struct GlidePlan: Equatable, Sendable {
    public let from: GlideState
    public let target: CGPoint
    public let spring: GlideSpring
    /// When the cursor has settled: within `settleDistance` of the target and slower than `settleSpeed`.
    public let duration: TimeInterval
    /// When it first comes within `arrivalDistance` of the target: the moment to show a ripple.
    public let arrival: TimeInterval

    public static let settleDistance = 0.25
    public static let settleSpeed = 8.0
    public static let arrivalDistance = 1.5
    /// No glide runs longer than this (config.md refuses animations over 1000 ms).
    public static let maxDuration: TimeInterval = 1.0
    private static let scanStep: TimeInterval = 1.0 / 480

    public init(from: GlideState, target: CGPoint, spring: GlideSpring) {
        let s = spring.clamped
        self.from = from; self.target = target; self.spring = s
        let dx = from.position.x - target.x, dy = from.position.y - target.y
        if s.isInstant || (hypot(dx, dy) <= Self.settleDistance && hypot(from.velocity.dx, from.velocity.dy) <= Self.settleSpeed) {
            duration = 0; arrival = 0
            return
        }
        var settled = 0.0, arrived: Double?
        var t = 0.0
        let probe = GlidePlan(unscanned: from, target: target, spring: s)
        while t <= Self.maxDuration {
            let st = probe.state(at: t)
            let dist = hypot(st.position.x - target.x, st.position.y - target.y)
            let speed = hypot(st.velocity.dx, st.velocity.dy)
            if arrived == nil, dist <= Self.arrivalDistance { arrived = t }
            if dist > Self.settleDistance || speed > Self.settleSpeed { settled = t + Self.scanStep }
            t += Self.scanStep
        }
        duration = min(settled, Self.maxDuration)
        arrival = min(arrived ?? duration, duration)
    }

    private init(unscanned from: GlideState, target: CGPoint, spring: GlideSpring) {
        self.from = from; self.target = target; self.spring = spring; duration = Self.maxDuration; arrival = 0
    }

    /// Position and velocity `t` seconds in; the target at rest once settled.
    public func state(at t: TimeInterval) -> GlideState {
        if t <= 0 { return from }
        if t >= duration { return GlideState(position: target) }
        let (x, vx) = Self.axis(d0: from.position.x - target.x, v0: from.velocity.dx, t: t, spring: spring)
        let (y, vy) = Self.axis(d0: from.position.y - target.y, v0: from.velocity.dy, t: t, spring: spring)
        return GlideState(position: CGPoint(x: target.x + x, y: target.y + y), velocity: CGVector(dx: vx, dy: vy))
    }

    /// A new plan toward `newTarget` that starts where this one is at `t`, at the speed it has then.
    public func retarget(at t: TimeInterval, to newTarget: CGPoint) -> GlidePlan {
        GlidePlan(from: state(at: t), target: newTarget, spring: spring)
    }

    /// Positions for a keyframe animation, `step` apart, from 0 to the settle time. The compositor runs it;
    /// nothing on the main thread runs per frame. Four milliseconds between samples is finer than a 240 Hz display.
    public func samples(step: TimeInterval = 1.0 / 240) -> [GlideSample] {
        guard duration > 0 else { return [GlideSample(time: 0, position: target)] }
        var out: [GlideSample] = []
        var t = 0.0
        while t < duration { out.append(GlideSample(time: t, position: state(at: t).position)); t += step }
        out.append(GlideSample(time: duration, position: target))
        return out
    }

    /// One axis of a damped spring: displacement from the target and its rate, in closed form.
    static func axis(d0: Double, v0: Double, t: Double, spring: GlideSpring) -> (d: Double, v: Double) {
        let w = 2 * Double.pi / spring.response, z = spring.damping
        if z < 0.999 {
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * t), c = cos(wd * t), s = sin(wd * t)
            let b = (v0 + z * w * d0) / wd
            let d = e * (d0 * c + b * s)
            let v = e * (-z * w * (d0 * c + b * s) + (-d0 * wd * s + b * wd * c))
            return (d, v)
        }
        if z <= 1.001 {
            let e = exp(-w * t), c = v0 + w * d0
            return (e * (d0 + c * t), e * (v0 - w * c * t))
        }
        let q = (z * z - 1).squareRoot()
        let r1 = -w * (z - q), r2 = -w * (z + q)
        let c2 = (v0 - r1 * d0) / (r2 - r1), c1 = d0 - c2
        return (c1 * exp(r1 * t) + c2 * exp(r2 * t), c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t))
    }
}
