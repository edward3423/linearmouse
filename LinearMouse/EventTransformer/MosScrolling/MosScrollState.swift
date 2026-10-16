// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// The scroll math of Mos' `ScrollPoster` + `ScrollFilter` + `Interpolator.lerp`, ported verbatim.
///
/// Mos keeps a target distance (`buffer`) and the distance travelled so far (`current`). Each wheel
/// event adds `delta * speed * amplification` to the target (or restarts it when the direction
/// flips). Each display frame travels `(buffer - current) * durationTransition`, then runs that
/// frame through a 5-tap curve filter whose output lags one frame behind. Frames at or below the
/// dead zone are not posted. Trackpad simulation (scroll phases) is off, as in Mos' defaults.
///
/// Not thread-safe; `MosScrollPoster` serializes access with a lock.
struct MosScrollState {
    struct Frame: Equatable {
        /// The delta to post, or `nil` when the filtered value is inside the dead zone.
        var output: (y: Double, x: Double)?
        /// Mos stops its display link (and resets) after this frame.
        var shouldStop: Bool

        static func == (lhs: Frame, rhs: Frame) -> Bool {
            lhs.output?.y == rhs.output?.y && lhs.output?.x == rhs.output?.x && lhs.shouldStop == rhs.shouldStop
        }
    }

    // Mos ScrollPoster thresholds.
    static let manualContinuationThreshold: TimeInterval = 0.18
    static let trackingEndAdvance: TimeInterval = 0.04
    static let momentumEndDelay: TimeInterval = 0.13
    static let deadZone = 1.0

    private(set) var current = (y: 0.0, x: 0.0)
    private(set) var buffer = (y: 0.0, x: 0.0)
    private var delta = (y: 0.0, x: 0.0)
    private var duration = Scheme.Scrolling.Mos.durationTransition(for: Scheme.Scrolling.Mos.defaultDuration)
    private var filter = MosScrollFilter()

    var shifting = false

    private var lastManualEventTime: TimeInterval = 0
    private var manualInputEnded = true
    private var momentumActive = false
    private var momentumEndScheduledTime: TimeInterval?
    private var trackingEndScheduledTime: TimeInterval?

    /// `ScrollPoster.update`.
    mutating func update(
        duration: Double,
        y: Double,
        x: Double,
        speed: Double,
        amplification: Double,
        now: TimeInterval
    ) {
        self.duration = duration
        if y * delta.y > 0 {
            buffer.y += y * speed * amplification
        } else {
            buffer.y = y * speed * amplification
            current.y = 0.0
        }
        if x * delta.x > 0 {
            buffer.x += x * speed * amplification
        } else {
            buffer.x = x * speed * amplification
            current.x = 0.0
        }
        delta = (y: y, x: x)
        lastManualEventTime = now
        manualInputEnded = false
        momentumActive = false
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
    }

    /// `ScrollPoster.processing`, one display frame.
    mutating func advance(now: TimeInterval) -> Frame {
        let frame = (
            y: (buffer.y - current.y) * duration,
            x: (buffer.x - current.x) * duration
        )
        current = (y: current.y + frame.y, x: current.x + frame.x)
        let shiftedValue = shift(filter.fill(with: frame))

        if !manualInputEnded, lastManualEventTime > 0, now - lastManualEventTime > Self.manualContinuationThreshold {
            manualInputEnded = true
            if trackingEndScheduledTime == nil {
                trackingEndScheduledTime = now + Self.trackingEndAdvance
            }
        }

        let residualMagnitude = max(abs(buffer.y - current.y), abs(buffer.x - current.x))
        if manualInputEnded, residualMagnitude > Self.deadZone {
            momentumActive = true
            momentumEndScheduledTime = nil
            trackingEndScheduledTime = nil
        } else if momentumActive, residualMagnitude <= Self.deadZone {
            if momentumEndScheduledTime == nil {
                momentumEndScheduledTime = now + Self.momentumEndDelay
            }
        } else {
            momentumEndScheduledTime = nil
            momentumActive = false
        }

        let outputMagnitude = max(abs(shiftedValue.y), abs(shiftedValue.x))
        let output = outputMagnitude > Self.deadZone ? shiftedValue : nil

        var shouldStop = false
        if let scheduled = momentumEndScheduledTime, momentumActive, now >= scheduled {
            momentumEndScheduledTime = nil
            momentumActive = false
            shouldStop = true
        }
        if !shouldStop, manualInputEnded, !momentumActive, residualMagnitude <= Self.deadZone {
            let pendingStop = trackingEndScheduledTime.map { now >= $0 } ?? false
            if pendingStop, outputMagnitude <= Self.deadZone {
                trackingEndScheduledTime = nil
                shouldStop = true
            }
        } else {
            trackingEndScheduledTime = nil
        }

        return Frame(output: output, shouldStop: shouldStop)
    }

    /// `ScrollPoster.brake`.
    mutating func brake() {
        buffer = current
        manualInputEnded = true
        momentumActive = false
        momentumEndScheduledTime = nil
    }

    /// `ScrollPoster.resetUnlocked`.
    mutating func reset() {
        current = (y: 0.0, x: 0.0)
        delta = (y: 0.0, x: 0.0)
        buffer = (y: 0.0, x: 0.0)
        filter.reset()
        manualInputEnded = true
        momentumActive = false
        lastManualEventTime = 0
        momentumEndScheduledTime = nil
        trackingEndScheduledTime = nil
    }

    /// `ScrollPoster.shift`: while the toggle key is held, vertical output becomes horizontal.
    private func shift(_ value: (y: Double, x: Double)) -> (y: Double, x: Double) {
        if shifting, value.y != 0, value.x == 0 {
            return (y: value.x, x: value.y)
        }
        return value
    }
}

/// Mos' `ScrollFilter`: each frame is blended 23% toward the new value, and the value emitted is the
/// one from the previous frame.
struct MosScrollFilter {
    private var windowY = [0.0, 0.0]
    private var windowX = [0.0, 0.0]

    mutating func fill(with nextValue: (y: Double, x: Double)) -> (y: Double, x: Double) {
        windowY = Self.polish(windowY, with: nextValue.y)
        windowX = Self.polish(windowX, with: nextValue.x)
        return (y: windowY[0], x: windowX[0])
    }

    mutating func reset() {
        windowY = [0.0, 0.0]
        windowX = [0.0, 0.0]
    }

    private static func polish(_ array: [Double], with nextValue: Double) -> [Double] {
        let first = array[1]
        let diff = nextValue - first
        return [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, nextValue]
    }
}
