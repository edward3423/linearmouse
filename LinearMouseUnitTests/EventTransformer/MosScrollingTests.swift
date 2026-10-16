// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class MosScrollingTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ConfigurationState.shared.configuration = .init()
    }

    // MARK: - Scroll math

    /// Frames produced by Mos' own `ScrollFilter.swift` and `Interpolator.swift`, compiled unchanged
    /// and driven the way `ScrollPoster.update` / `processing` drive them (step 33.6, speed 2,
    /// duration 1.00 -> transition 0.561).
    private let mosReferenceFrames = [
        0.000000000000, 8.670816000000, 10.483016544000, 9.742971069216,
        8.235677940314, 15.334334119312, 15.755303736084, 13.864697254575,
        11.436653658872, -34.547856682668, -45.634290765655, -43.493645541234,
        -37.158058151838, -30.221935303268
    ]

    func testFramesMatchMosReferenceImplementation() {
        var state = MosScrollState()
        var frames: [Double] = []
        let transition = Scheme.Scrolling.Mos.durationTransition(for: 1.0)

        func update(_ y: Double, amplification: Double = 1) {
            state.update(duration: transition, y: y, x: 0, speed: 2, amplification: amplification, now: 1)
        }
        func advance(_ count: Int) {
            for _ in 0 ..< count {
                frames.append(state.advance(now: 1).output?.y ?? 0)
            }
        }

        update(33.6)
        advance(4)
        update(33.6)
        advance(4)
        update(-33.6, amplification: MosScrolling.dashAmplification)
        advance(6)

        XCTAssertEqual(frames.count, mosReferenceFrames.count)
        for (frame, expected) in zip(frames, mosReferenceFrames) {
            XCTAssertEqual(frame, expected, accuracy: 1e-9)
        }
    }

    func testDurationTransitionMatchesMos() {
        XCTAssertEqual(Scheme.Scrolling.Mos.durationTransition(for: 1.0), 0.561)
        XCTAssertEqual(Scheme.Scrolling.Mos.durationTransition(for: 4.35), 0.085)
        XCTAssertEqual(Scheme.Scrolling.Mos.durationTransition(for: 0), 1.0)
    }

    func testSingleNotchTravelsSpeedTimesStepAndThenStops() throws {
        // Mos timestamps are absolute times; 0 means "no input yet".
        let start: TimeInterval = 1000
        var state = MosScrollState()
        state.update(duration: 0.561, y: 33.6, x: 0, speed: 2, amplification: 1, now: start)

        var travelled = 0.0
        var stopTime: TimeInterval?
        for frame in 1 ... 240 {
            let now = start + Double(frame) / 120
            let result = state.advance(now: now)
            travelled += result.output?.y ?? 0
            if result.shouldStop {
                stopTime = now
                break
            }
        }

        // Frames inside Mos' 1px dead zone are dropped, so slightly less than 67.2 arrives.
        XCTAssertEqual(travelled, 67.2, accuracy: 4)
        XCTAssertLessThan(travelled, 67.2)
        // Manual input ends after 0.18s, tracking end follows 0.04s later.
        let stop = try XCTUnwrap(stopTime)
        XCTAssertEqual(stop - start, 0.18 + 0.04, accuracy: 2.0 / 120)
    }

    func testDirectionChangeRestartsTarget() {
        var state = MosScrollState()
        state.update(duration: 0.561, y: 33.6, x: 0, speed: 2, amplification: 1, now: 0)
        _ = state.advance(now: 0.01)
        state.update(duration: 0.561, y: -33.6, x: 0, speed: 2, amplification: 1, now: 0.02)

        XCTAssertEqual(state.buffer.y, -67.2, accuracy: 1e-9)
        XCTAssertEqual(state.current.y, 0)
    }

    func testToggleShiftsVerticalOutputToHorizontal() {
        var state = MosScrollState()
        state.shifting = true
        state.update(duration: 0.561, y: 33.6, x: 0, speed: 2, amplification: 1, now: 0)
        _ = state.advance(now: 0)
        let output = state.advance(now: 0).output

        XCTAssertEqual(output?.y, 0)
        XCTAssertEqual(output?.x ?? 0, 8.670816, accuracy: 1e-6)
    }

    // MARK: - Input

    func testUsableValuePrefersPointThenFixedPointThenLines() throws {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ))
        XCTAssertEqual(
            MosScrollingSessionTap.usableValue(of: event, axis: .vertical),
            event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        )
        XCTAssertEqual(MosScrollingSessionTap.usableValue(of: event, axis: .horizontal), 0)
    }

    func testModifierKeysDistinguishLeftAndRight() {
        let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)

        XCTAssertTrue(Scheme.Scrolling.Mos.Key.leftOption.isHeld(in: leftOption))
        XCTAssertFalse(Scheme.Scrolling.Mos.Key.leftOption.isHeld(in: rightOption))
        XCTAssertTrue(Scheme.Scrolling.Mos.Key.option.isHeld(in: rightOption))
        XCTAssertFalse(Scheme.Scrolling.Mos.Key.none.isHeld(in: leftOption))
    }

    // MARK: - Configuration

    func testDefaultsMatchMos() {
        let mos = Scheme.Scrolling.Mos(enabled: true)

        XCTAssertEqual(mos.resolvedStep, 33.6)
        XCTAssertEqual(mos.resolvedSpeed, 2.7)
        XCTAssertEqual(mos.resolvedDuration, 4.35)
        XCTAssertEqual(mos.resolvedDash, .leftOption)
        XCTAssertEqual(mos.resolvedToggle, .leftShift)
        XCTAssertEqual(mos.resolvedBlock, .leftCommand)
        XCTAssertFalse(Scheme.Scrolling.Mos().isEnabled)
    }

    func testDecodesAndMergesLaterSchemesOverEarlierOnes() throws {
        let json = """
        {"schemes": [
          {"scrolling": {"mos": {"enabled": true, "step": 33.6, "speed": 2, "duration": 1, "block": "none"}}},
          {"if": {"app": "tv.parsec.www"}, "scrolling": {"mos": {"enabled": false}}}
        ]}
        """
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        var merged = Scheme.Scrolling()
        for scheme in configuration.schemes {
            scheme.scrolling.merge(into: &merged)
        }

        XCTAssertFalse(merged.mos.isEnabled)
        XCTAssertEqual(merged.mos.resolvedSpeed, 2)
        XCTAssertEqual(merged.mos.resolvedDuration, 1)
        XCTAssertEqual(merged.mos.resolvedBlock, Scheme.Scrolling.Mos.Key.none)
    }

    func testMarkHandsConfigurationToSessionStageOnce() throws {
        let configuration = MosScrolling.Configuration(.init(enabled: true, speed: 2, duration: 1))
        let event = try XCTUnwrap(makeWheelEvent())
        event.timestamp = 123_456_789

        MosScrolling.mark(event, with: configuration)

        // The event itself is not modified, so its one-time user data stays free for the poster.
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 0)
        XCTAssertEqual(MosScrolling.takeConfiguration(for: event), configuration)
        XCTAssertNil(MosScrolling.takeConfiguration(for: event))
    }

    /// Software-posted events have no attached hardware event; their CGEvent timestamp is the key.
    /// (Hardware wheel events are keyed by sender ID + hardware timestamp, because macOS re-stamps
    /// their CGEvent timestamp between the HID and session taps.)
    func testKeyFallsBackToEventTimestampWithoutHardwareEvent() throws {
        let event = try XCTUnwrap(makeWheelEvent())
        event.timestamp = 42
        let key = try XCTUnwrap(MosScrolling.Key(event))

        XCTAssertEqual(key.senderID, 0)
        XCTAssertEqual(key.timestamp, 42)

        event.timestamp = 0
        XCTAssertNil(MosScrolling.Key(event))
    }

    // MARK: - Frames

    /// Regression: `eventSourceUserData` can only be written once per event. Frames must still be
    /// recognizable as our own, or they re-enter the Mos tap as new wheel input and nothing scrolls.
    func testFramesAreMarkedEvenWhenTemplateUserDataIsTaken() throws {
        let clean = try XCTUnwrap(makeWheelEvent())
        clean.location = CGPoint(x: 120, y: 340)
        let taken = try XCTUnwrap(makeWheelEvent())
        taken.location = CGPoint(x: 120, y: 340)
        taken.flags = .maskShift
        taken.setIntegerValueField(.eventSourceUserData, value: 0x7E57)

        for template in [clean, taken] {
            let frame = try XCTUnwrap(MosScrollPoster.makeFrame(from: template, delta: (y: -12, x: 0)))
            XCTAssertTrue(MosScrollPoster.isSyntheticFrame(frame))
            XCTAssertEqual(frame.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), -12)
            XCTAssertEqual(frame.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(frame.location, template.location)
            XCTAssertEqual(frame.flags.contains(.maskShift), template.flags.contains(.maskShift))
        }
    }

    func testSessionTapPassesFramesThrough() throws {
        let template = try XCTUnwrap(makeWheelEvent())
        let frame = try XCTUnwrap(MosScrollPoster.makeFrame(from: template, delta: (y: 8, x: 0)))
        MosScrolling.mark(frame, with: .init(.init(enabled: true)))
        defer { _ = MosScrolling.takeConfiguration(for: frame) }

        XCTAssertTrue(MosScrollingSessionTap.handle(frame) === frame)
    }

    private func makeWheelEvent() -> CGEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0)
    }

    // MARK: - Pipeline

    /// With Mos scrolling on, LinearMouse's line distance still applies first (exactly what Mos saw
    /// when running next to LinearMouse), LinearMouse's own smoothing is skipped, and the event is
    /// tagged for the Mos stage.
    func testPipelineAppliesLineDistanceAndTagsForMos() throws {
        ConfigurationState.shared.configuration = .init(schemes: [
            Scheme(scrolling: .init(
                distance: .init(vertical: .line(3)),
                smoothed: .init(vertical: .init(enabled: true, preset: .smooth)),
                mos: .init(enabled: true, speed: 2, duration: 1)
            ))
        ])
        let manager = EventTransformerManager(warpPointer: { _ in }, postEvent: { _, _ in })
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        // Events only get a timestamp when posted; real wheel events always carry one.
        event.timestamp = mach_absolute_time()

        let transformer = manager.get(
            withCGEvent: event,
            withSourcePid: nil,
            withTargetPid: nil,
            withMouseLocationPid: nil,
            withDisplay: nil
        )
        let transformed = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))

        XCTAssertEqual(ScrollWheelEventView(transformed).deltaY, 3)
        XCTAssertEqual(transformed.getIntegerValueField(.eventSourceUserData), 0)
        XCTAssertEqual(
            MosScrolling.takeConfiguration(for: transformed),
            MosScrolling.Configuration(.init(enabled: true, speed: 2, duration: 1))
        )
    }

    func testPipelineLeavesEventsUntaggedWhenMosIsDisabled() throws {
        ConfigurationState.shared.configuration = .init(schemes: [
            Scheme(scrolling: .init(distance: .init(vertical: .line(3))))
        ])
        let manager = EventTransformerManager(warpPointer: { _ in }, postEvent: { _, _ in })
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        // Events only get a timestamp when posted; real wheel events always carry one.
        event.timestamp = mach_absolute_time()

        let transformer = manager.get(
            withCGEvent: event,
            withSourcePid: nil,
            withTargetPid: nil,
            withMouseLocationPid: nil,
            withDisplay: nil
        )
        let transformed = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))

        XCTAssertNil(MosScrolling.takeConfiguration(for: transformed))
    }
}

final class MosScrollPosterTests: XCTestCase {
    /// Drives the real display link: one wheel event must animate over many frames and then stop.
    func testDisplayLinkAnimatesWheelEventToCompletion() throws {
        let poster = MosScrollPoster.shared
        poster.activate()
        defer { poster.deactivate() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        ))
        // Post to ourselves; nothing listens for scroll events in the test host.
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))

        let processedBefore = poster.processedFrameCount
        let postedBefore = poster.postedFrameCount
        poster.update(event: event, duration: 0.561, y: 33.6, x: 0, speed: 2, amplification: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let processed = poster.processedFrameCount - processedBefore
        let posted = poster.postedFrameCount - postedBefore
        // Mos stops ~0.22s after the last wheel event; at 60-120Hz that is well over 10 frames.
        XCTAssertGreaterThan(processed, 10, "display link stalled after \(processed) frames")
        XCTAssertGreaterThan(posted, 4, "only \(posted) frames were posted")
    }

    /// Same path as the live tap: tagged wheel events arriving rapidly on a background thread.
    func testRapidWheelEventsFromTapThreadKeepAnimating() throws {
        let poster = MosScrollPoster.shared
        poster.activate()
        defer { poster.deactivate() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let configuration = MosScrolling.Configuration(.init(enabled: true, speed: 2, duration: 1))
        let processedBefore = poster.processedFrameCount
        let postedBefore = poster.postedFrameCount
        let done = expectation(description: "events delivered")
        let tapThread = Thread {
            for _ in 0 ..< 30 {
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: 3,
                    wheel2: 0,
                    wheel3: 0
                ) else {
                    continue
                }
                event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
                event.timestamp = mach_absolute_time()
                MosScrolling.mark(event, with: configuration)
                _ = MosScrollingSessionTap.handle(event)
                Thread.sleep(forTimeInterval: 0.016)
            }
            done.fulfill()
        }
        tapThread.start()
        wait(for: [done], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let processed = poster.processedFrameCount - processedBefore
        let posted = poster.postedFrameCount - postedBefore
        XCTAssertGreaterThan(processed, 40, "display link stalled after \(processed) frames")
        XCTAssertGreaterThan(posted, 30, "only \(posted) frames were posted")
    }
}
