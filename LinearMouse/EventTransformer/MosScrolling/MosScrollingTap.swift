// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Foundation
import os

/// Mos scrolling runs in two stages, mirroring a LinearMouse + Mos setup:
///
/// 1. `MosScrollingMarkTransformer` runs last in the HID-level transformer chain. It knows the scheme
///    for the device and app, and records which Mos configuration applies to the (already reversed /
///    line-adjusted) wheel event.
/// 2. `MosScrollingSessionTap` sits where Mos does (tail of the annotated session tap, where macOS has
///    resolved the target process). It runs Mos' `ScrollCore` logic on marked events and hands them
///    to `MosScrollPoster`.
///
/// The hand-off is keyed by the hardware event macOS attaches to the wheel event (its sender ID and
/// timestamp), which survives between the two taps; the CGEvent timestamp does not (macOS re-stamps
/// hardware events on their way to the session). The event itself is left untouched:
/// `eventSourceUserData` can only be written once per event, and the poster needs that write to mark
/// the frames it posts, exactly as Mos does.
enum MosScrolling {
    struct Configuration: Equatable {
        var step: Double
        var speed: Double
        var durationTransition: Double
        var dash: Scheme.Scrolling.Mos.Key
        var toggle: Scheme.Scrolling.Mos.Key
        var block: Scheme.Scrolling.Mos.Key
        var blockLines: Int?

        init(_ mos: Scheme.Scrolling.Mos) {
            step = mos.resolvedStep
            speed = mos.resolvedSpeed
            durationTransition = mos.durationTransition
            dash = mos.resolvedDash
            toggle = mos.resolvedToggle
            block = mos.resolvedBlock
            blockLines = mos.resolvedBlockLines
        }
    }

    /// Mos' dash key multiplies the scroll distance by 5.
    static let dashAmplification = 5.0

    // Events reach the session tap within microseconds of the HID tap, so a short ring is plenty.
    private static let pendingCapacity = 64
    private static var pending: [(key: Key, configuration: Configuration)] = []
    private static var pendingLock = os_unfair_lock_s()

    struct Key: Equatable {
        var senderID: UInt64
        var timestamp: UInt64

        /// The attached hardware event identifies a wheel event across taps. Events without one
        /// (posted by software) keep their CGEvent timestamp, so fall back to that.
        init?(_ event: CGEvent) {
            if let hidEvent = CGEventCopyIOHIDEvent(event) {
                senderID = IOHIDEventGetSenderID(hidEvent)
                timestamp = IOHIDEventGetTimeStamp(hidEvent)
            } else {
                senderID = 0
                timestamp = event.timestamp
            }
            guard timestamp != 0 else {
                return nil
            }
        }
    }

    static func mark(_ event: CGEvent, with configuration: Configuration) {
        guard let key = Key(event) else {
            return
        }
        os_unfair_lock_lock(&pendingLock)
        defer { os_unfair_lock_unlock(&pendingLock) }
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending[index].configuration = configuration
            return
        }
        if pending.count >= pendingCapacity {
            pending.removeFirst()
        }
        pending.append((key, configuration))
    }

    static func takeConfiguration(for event: CGEvent) -> Configuration? {
        guard let key = Key(event) else {
            return nil
        }
        os_unfair_lock_lock(&pendingLock)
        defer { os_unfair_lock_unlock(&pendingLock) }
        guard let index = pending.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        return pending.remove(at: index).configuration
    }
}

final class MosScrollingMarkTransformer: EventTransformer {
    var handlesPointerMotion: Bool {
        false
    }

    private let configuration: MosScrolling.Configuration

    init(mos: Scheme.Scrolling.Mos) {
        configuration = .init(mos)
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        if event.type == .scrollWheel, !event.isLinearMouseSyntheticEvent {
            MosScrolling.mark(event, with: configuration)
        }
        return event
    }
}

/// Port of Mos' `ScrollCore` event callbacks.
enum MosScrollingSessionTap {
    /// The configuration of the most recent tagged wheel event, used to track the toggle key the way
    /// Mos tracks hotkeys for the current app.
    private static var lastConfiguration: MosScrolling.Configuration?

    static let eventTypes: [CGEventType] = [.scrollWheel, .leftMouseDown, .flagsChanged]

    static func handle(_ event: CGEvent) -> CGEvent? {
        switch event.type {
        case .leftMouseDown:
            // Mos: clicking stops the current scroll animation.
            MosScrollPoster.shared.stop()
            return event
        case .flagsChanged:
            if let configuration = lastConfiguration {
                MosScrollPoster.shared.updateShifting(enable: configuration.toggle.isHeld(in: event.flags))
            }
            return event
        case .scrollWheel:
            return handleScrollWheel(event)
        default:
            return event
        }
    }

    static func handleTapRestart() {
        MosScrollPoster.shared.stop()
    }

    private static func handleScrollWheel(_ event: CGEvent) -> CGEvent? {
        if MosScrollPoster.isSyntheticFrame(event) {
            return event
        }
        guard let configuration = MosScrolling.takeConfiguration(for: event) else {
            return event
        }
        lastConfiguration = configuration

        let flags = event.flags
        let blockSmooth = configuration.block.isHeld(in: flags)
        let amplification = configuration.dash.isHeld(in: flags) ? MosScrolling.dashAmplification : 1.0
        MosScrollPoster.shared.updateShifting(enable: configuration.toggle.isHeld(in: flags))

        var y = Self.usableValue(of: event, axis: .vertical)
        var x = Self.usableValue(of: event, axis: .horizontal)
        let hasVerticalDelta = y != 0
        let hasHorizontalDelta = x != 0

        guard hasVerticalDelta || hasHorizontalDelta else {
            return event
        }

        // Mos' "block" key turns smoothing off. The wheel event passes through, optionally scrolling
        // a fixed number of lines per notch (as DiscreteScroll does) instead of accelerating.
        if blockSmooth {
            if let lines = configuration.blockLines {
                Self.scrollByLines(event, lines: lines, vertical: y, horizontal: x)
            }
            return event
        }

        if abs(y) < configuration.step, hasVerticalDelta {
            y = y > 0 ? configuration.step : -configuration.step
        }
        if abs(x) < configuration.step, hasHorizontalDelta {
            x = x > 0 ? configuration.step : -configuration.step
        }

        MosScrollPoster.shared.update(
            event: event,
            duration: configuration.durationTransition,
            y: y,
            x: x,
            speed: configuration.speed,
            amplification: amplification
        )

        return MosScrollPoster.shared.isAvailable ? nil : event
    }

    enum Axis {
        case vertical, horizontal
    }

    /// DiscreteScroll: replace the line delta of a notched wheel event with a fixed count in the same
    /// direction. Setting the line delta makes macOS recompute the point deltas.
    static func scrollByLines(_ event: CGEvent, lines: Int, vertical: Double, horizontal: Double) {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return
        }
        if vertical != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: vertical > 0 ? Int64(lines) : -Int64(lines))
        }
        if horizontal != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: horizontal > 0 ? Int64(lines) : -Int64(lines))
        }
    }

    /// Mos' `ScrollEvent.initEvent`: prefer the point delta, then the fixed-point delta, then lines.
    static func usableValue(of event: CGEvent, axis: Axis) -> Double {
        let (fix, point, fixedPoint): (CGEventField, CGEventField, CGEventField) = switch axis {
        case .vertical:
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1)
        case .horizontal:
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)
        }
        let scrollPt = event.getDoubleValueField(point)
        if scrollPt != 0 {
            return scrollPt
        }
        let scrollFixPt = event.getDoubleValueField(fixedPoint)
        if scrollFixPt != 0 {
            return scrollFixPt
        }
        return Double(event.getIntegerValueField(fix))
    }
}
