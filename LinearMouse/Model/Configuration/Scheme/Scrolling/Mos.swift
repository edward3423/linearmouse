// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation

extension Scheme.Scrolling {
    /// Smooth scrolling that reproduces Mos (https://github.com/Caldis/Mos) exactly: every wheel
    /// event adds a fixed distance to a target, and each display frame moves a fixed fraction of the
    /// remaining distance, followed by Mos' 5-tap curve filter.
    struct Mos: Codable, Equatable, ImplicitInitable {
        /// A modifier key used for one of Mos' scroll hotkeys.
        enum Key: String, Codable, Equatable, CaseIterable {
            case none
            case option, leftOption, rightOption
            case shift, leftShift, rightShift
            case command, leftCommand, rightCommand
            case control, leftControl, rightControl
        }

        var enabled: Bool?
        var step: Decimal?
        var speed: Decimal?
        var duration: Decimal?
        var dash: Key?
        var toggle: Key?
        var block: Key?

        init() {}

        init(
            enabled: Bool? = nil,
            step: Decimal? = nil,
            speed: Decimal? = nil,
            duration: Decimal? = nil,
            dash: Key? = nil,
            toggle: Key? = nil,
            block: Key? = nil
        ) {
            self.enabled = enabled
            self.step = step
            self.speed = speed
            self.duration = duration
            self.dash = dash
            self.toggle = toggle
            self.block = block
        }
    }
}

extension Scheme.Scrolling.Mos {
    // Defaults and slider ranges match Mos' Scrolling preferences.
    static let defaultStep = 33.6
    static let defaultSpeed = 2.70
    static let defaultDuration = 4.35
    static let stepRange: ClosedRange<Double> = 0.01 ... 100
    static let speedRange: ClosedRange<Double> = 0.01 ... 10
    static let durationRange: ClosedRange<Double> = 0 ... 5

    var isEnabled: Bool {
        enabled ?? false
    }

    var resolvedStep: Double {
        (step?.asTruncatedDouble ?? Self.defaultStep).clamped(to: Self.stepRange)
    }

    var resolvedSpeed: Double {
        (speed?.asTruncatedDouble ?? Self.defaultSpeed).clamped(to: Self.speedRange)
    }

    var resolvedDuration: Double {
        (duration?.asTruncatedDouble ?? Self.defaultDuration).clamped(to: Self.durationRange)
    }

    /// Mos' `OPTIONS_SCROLL_DEFAULT.generateDurationTransition`: the fraction of the remaining
    /// distance travelled per display frame.
    var durationTransition: Double {
        Self.durationTransition(for: resolvedDuration)
    }

    static func durationTransition(for duration: Double) -> Double {
        let upperLimit = 5.0 + 0.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (1000 * value).rounded() / 1000
    }

    // Mos binds its hotkeys to the left-hand modifiers by default.
    var resolvedDash: Key {
        dash ?? .leftOption
    }

    var resolvedToggle: Key {
        toggle ?? .leftShift
    }

    var resolvedBlock: Key {
        block ?? .leftCommand
    }

    func merge(into mos: inout Self) {
        if let enabled {
            mos.enabled = enabled
        }
        if let step {
            mos.step = step
        }
        if let speed {
            mos.speed = speed
        }
        if let duration {
            mos.duration = duration
        }
        if let dash {
            mos.dash = dash
        }
        if let toggle {
            mos.toggle = toggle
        }
        if let block {
            mos.block = block
        }
    }

    func merge(into mos: inout Self?) {
        if mos == nil {
            mos = Self()
        }

        merge(into: &mos!)
    }
}

extension Scheme.Scrolling.Mos.Key {
    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) carried in CGEventFlags.
    private static let leftShiftMask: UInt64 = 0x0000_0002
    private static let rightShiftMask: UInt64 = 0x0000_0004
    private static let leftCommandMask: UInt64 = 0x0000_0008
    private static let rightCommandMask: UInt64 = 0x0000_0010
    private static let leftOptionMask: UInt64 = 0x0000_0020
    private static let rightOptionMask: UInt64 = 0x0000_0040
    private static let leftControlMask: UInt64 = 0x0000_0001
    private static let rightControlMask: UInt64 = 0x0000_2000

    func isHeld(in flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch self {
        case .none:
            return false
        case .option:
            return flags.contains(.maskAlternate)
        case .leftOption:
            return raw & Self.leftOptionMask != 0
        case .rightOption:
            return raw & Self.rightOptionMask != 0
        case .shift:
            return flags.contains(.maskShift)
        case .leftShift:
            return raw & Self.leftShiftMask != 0
        case .rightShift:
            return raw & Self.rightShiftMask != 0
        case .command:
            return flags.contains(.maskCommand)
        case .leftCommand:
            return raw & Self.leftCommandMask != 0
        case .rightCommand:
            return raw & Self.rightCommandMask != 0
        case .control:
            return flags.contains(.maskControl)
        case .leftControl:
            return raw & Self.leftControlMask != 0
        case .rightControl:
            return raw & Self.rightControlMask != 0
        }
    }
}
