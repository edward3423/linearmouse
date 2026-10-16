// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import CoreVideo
import os

/// Port of Mos' `ScrollPoster` + `ScrollDispatchContext`: drives `MosScrollState` from a
/// `CVDisplayLink` (one step per display frame) and posts each frame directly to the target process
/// as a copy of the last real wheel event.
final class MosScrollPoster {
    static let shared = MosScrollPoster()

    /// `eventSourceUserData` on frames this poster creates, so the Mos tap lets them through.
    static let syntheticEventUserData: Int64 = 0x4C4D_4D6F_7353 // "LMMosS"

    static func isSyntheticFrame(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserData
    }

    /// Mos' `ScrollPoster.post`: a copy of the last real wheel event carrying the frame delta.
    ///
    /// `eventSourceUserData` can only be written once per event. If something already wrote it on
    /// the original wheel event, the copy cannot be marked, would re-enter the Mos tap as new input
    /// and loop; build the frame from a fresh event with the same location and modifiers instead.
    static func makeFrame(from template: CGEvent, delta: (y: Double, x: Double)) -> CGEvent? {
        var frame = template.copy()
        frame?.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        if frame.map(isSyntheticFrame) != true {
            frame = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
            )
            frame?.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
            frame?.location = template.location
            frame?.flags = template.flags
        }
        guard let frame, isSyntheticFrame(frame) else {
            return nil
        }
        frame.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta.y)
        frame.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta.x)
        frame.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
        return frame
    }

    private var state = MosScrollState()
    private var stateLock = os_unfair_lock_s()

    private var poster: CVDisplayLink?
    private var keeper: Timer?
    private var lastCallbackTime: CFTimeInterval = 0
    private var lastRecreateAttempt: CFTimeInterval = 0
    private let recreateCooldown: CFTimeInterval = 3.0
    private var rateVerifyTimer: Timer?
    private var rateVerifyAttemptsLeft = 0
    private var isVerifying = false
    private let rateVerifyDelays: [TimeInterval] = [2.0, 4.0, 8.0]
    private let rateVerifyRatio = 0.7

    // Dispatch context: the event template and target of the current scroll session.
    private var eventTemplate: CGEvent?
    private var targetPID: pid_t = 0
    private var generation: UInt64 = 0
    private var templateCapturedAt: CFTimeInterval = 0
    private var dispatchLock = os_unfair_lock_s()
    private let postQueue = DispatchQueue(label: "com.linearmouse.mos-scroll.post", qos: .userInteractive)
    private let eventTTL: CFTimeInterval = 5.0

    /// Diagnostics: display frames processed and frames handed to the post queue.
    private(set) var processedFrameCount = 0
    private(set) var postedFrameCount = 0

    private init() {}

    var isAvailable: Bool {
        poster != nil
    }

    // MARK: Lifecycle (main thread)

    func activate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.activate() }
            return
        }
        guard poster == nil else {
            return
        }
        create()
        keeper?.invalidate()
        keeper = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
    }

    func deactivate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deactivate() }
            return
        }
        stop()
        keeper?.invalidate()
        keeper = nil
        rateVerifyTimer?.invalidate()
        rateVerifyTimer = nil
        rateVerifyAttemptsLeft = 0
        if let poster, CVDisplayLinkIsRunning(poster) {
            CVDisplayLinkStop(poster)
        }
        poster = nil
    }

    // MARK: Input (event tap thread)

    func updateShifting(enable: Bool) {
        os_unfair_lock_lock(&stateLock)
        state.shifting = enable
        os_unfair_lock_unlock(&stateLock)
    }

    /// `ScrollPoster.update(...).tryStart()`.
    func update(event: CGEvent, duration: Double, y: Double, x: Double, speed: Double, amplification: Double) {
        guard capture(event: event) else {
            return
        }
        os_unfair_lock_lock(&stateLock)
        state.update(
            duration: duration,
            y: y,
            x: x,
            speed: speed,
            amplification: amplification,
            now: CFAbsoluteTimeGetCurrent()
        )
        os_unfair_lock_unlock(&stateLock)
        tryStart()
    }

    /// `ScrollPoster.stop`: stop the display link and reset. Chrome gets an explicit scroll-ended
    /// event, as in Mos.
    func stop() {
        if let poster {
            CVDisplayLinkStop(poster)
        }
        advanceGeneration()
        os_unfair_lock_lock(&stateLock)
        if let snapshot = preparePostingSnapshot(),
           NSRunningApplication(processIdentifier: snapshot.targetPID)?.bundleIdentifier == "com.google.Chrome" {
            // Mos PhaseValueMapping[.TrackingEnd]: scroll phase 4 (ended), momentum phase 0.
            post(snapshot, (y: 0.0, x: 0.0), phase: (scroll: 4.0, momentum: 0.0))
        }
        state.reset()
        clearContext()
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: Display link

    private func create() {
        if let old = poster {
            if CVDisplayLinkIsRunning(old) {
                CVDisplayLinkStop(old)
            }
            poster = nil
        }
        var newPoster: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&newPoster)
        guard result == kCVReturnSuccess, let newPoster else {
            os_log("Mos scrolling: CVDisplayLink creation failed (%d)", type: .error, result)
            return
        }
        CVDisplayLinkSetOutputCallback(newPoster, { _, _, _, _, _, _ in
            MosScrollPoster.shared.processing()
            return kCVReturnSuccess
        }, nil)
        poster = newPoster
        if !isVerifying {
            scheduleRateVerify()
        }
    }

    private func tryStart() {
        guard let poster else {
            DispatchQueue.main.async { [self] in
                if !recreateDisplayLink() {
                    reset()
                }
            }
            return
        }
        if !CVDisplayLinkIsRunning(poster) {
            if CVDisplayLinkStart(poster) == kCVReturnSuccess {
                os_unfair_lock_lock(&stateLock)
                lastCallbackTime = CFAbsoluteTimeGetCurrent()
                os_unfair_lock_unlock(&stateLock)
            } else {
                DispatchQueue.main.async { [self] in
                    recreateDisplayLink()
                }
            }
        }
    }

    private func reset() {
        invalidateAll()
        os_unfair_lock_lock(&stateLock)
        state.reset()
        os_unfair_lock_unlock(&stateLock)
    }

    private func processing() {
        os_unfair_lock_lock(&stateLock)
        let now = CFAbsoluteTimeGetCurrent()
        lastCallbackTime = now
        let frame = state.advance(now: now)
        processedFrameCount += 1
        if let output = frame.output, let snapshot = preparePostingSnapshot() {
            post(snapshot, output)
            postedFrameCount += 1
        }
        os_unfair_lock_unlock(&stateLock)
        if frame.shouldStop {
            stop()
        }
    }

    @discardableResult
    private func recreateDisplayLink() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRecreateAttempt >= recreateCooldown else {
            return false
        }
        lastRecreateAttempt = now
        create()
        if let poster, CVDisplayLinkStart(poster) == kCVReturnSuccess {
            os_unfair_lock_lock(&stateLock)
            lastCallbackTime = CFAbsoluteTimeGetCurrent()
            os_unfair_lock_unlock(&stateLock)
        }
        return true
    }

    private func healthCheck() {
        guard let poster else {
            recreateDisplayLink()
            return
        }
        if CVDisplayLinkIsRunning(poster) {
            os_unfair_lock_lock(&stateLock)
            let lastTime = lastCallbackTime
            os_unfair_lock_unlock(&stateLock)
            if lastTime > 0, CFAbsoluteTimeGetCurrent() - lastTime > 2.0 {
                os_log("Mos scrolling: zombie CVDisplayLink detected, recreating", type: .info)
                recreateDisplayLink()
            }
        }
    }

    // A display that is waking up can briefly report a low refresh rate. Re-check a few times
    // after creating the link and rebuild it if it is bound well below the display's real rate.
    private func scheduleRateVerify() {
        rateVerifyAttemptsLeft = rateVerifyDelays.count
        armNextRateVerify()
    }

    private func armNextRateVerify() {
        rateVerifyTimer?.invalidate()
        guard rateVerifyAttemptsLeft > 0 else {
            rateVerifyTimer = nil
            return
        }
        let delay = rateVerifyDelays[rateVerifyDelays.count - rateVerifyAttemptsLeft]
        rateVerifyTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.verifyRateAndFixIfNeeded()
        }
    }

    private func verifyRateAndFixIfNeeded() {
        rateVerifyAttemptsLeft -= 1
        guard let current = poster else {
            rateVerifyTimer = nil
            return
        }
        let nominal = Self.nominalHz(of: current)
        let maxHz = Self.maxActiveDisplayHz()
        guard nominal > 1, maxHz > 1, nominal < maxHz * rateVerifyRatio else {
            rateVerifyTimer = nil
            rateVerifyAttemptsLeft = 0
            return
        }
        let wasRunning = CVDisplayLinkIsRunning(current)
        isVerifying = true
        create()
        isVerifying = false
        if wasRunning, let refreshed = poster {
            CVDisplayLinkStart(refreshed)
        }
        lastRecreateAttempt = 0
        armNextRateVerify()
    }

    private static func nominalHz(of link: CVDisplayLink) -> Double {
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        guard period.timeValue != 0, period.timeScale != 0 else {
            return -1
        }
        let seconds = Double(period.timeValue) / Double(period.timeScale)
        return seconds > 0 ? 1.0 / seconds : -1
    }

    private static func maxActiveDisplayHz() -> Double {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return -1
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return -1
        }
        return ids.prefix(Int(count)).compactMap { CGDisplayCopyDisplayMode($0)?.refreshRate }.max() ?? -1
    }

    // MARK: Dispatch (port of ScrollDispatchContext)

    private struct PostingSnapshot {
        let template: CGEvent
        let targetPID: pid_t
        let generation: UInt64
        let capturedAt: CFTimeInterval
    }

    private func capture(event: CGEvent) -> Bool {
        guard let template = event.copy() else {
            return false
        }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        os_unfair_lock_lock(&dispatchLock)
        eventTemplate = template
        targetPID = pid
        templateCapturedAt = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_unlock(&dispatchLock)
        return true
    }

    private func advanceGeneration() {
        os_unfair_lock_lock(&dispatchLock)
        generation &+= 1
        os_unfair_lock_unlock(&dispatchLock)
    }

    private func clearContext() {
        os_unfair_lock_lock(&dispatchLock)
        eventTemplate = nil
        targetPID = 0
        templateCapturedAt = 0
        os_unfair_lock_unlock(&dispatchLock)
    }

    private func invalidateAll() {
        os_unfair_lock_lock(&dispatchLock)
        generation &+= 1
        eventTemplate = nil
        targetPID = 0
        templateCapturedAt = 0
        os_unfair_lock_unlock(&dispatchLock)
    }

    private func preparePostingSnapshot() -> PostingSnapshot? {
        os_unfair_lock_lock(&dispatchLock)
        defer { os_unfair_lock_unlock(&dispatchLock) }
        guard targetPID != 0, let eventTemplate else {
            return nil
        }
        return PostingSnapshot(
            template: eventTemplate,
            targetPID: targetPID,
            generation: generation,
            capturedAt: templateCapturedAt
        )
    }

    private func post(_ snapshot: PostingSnapshot, _ value: (y: Double, x: Double), phase: (scroll: Double, momentum: Double)? = nil) {
        guard let frame = Self.makeFrame(from: snapshot.template, delta: value) else {
            return
        }
        if let phase {
            frame.setDoubleValueField(.scrollWheelEventScrollPhase, value: phase.scroll)
            frame.setDoubleValueField(.scrollWheelEventMomentumPhase, value: phase.momentum)
        }
        postQueue.async { [self] in
            os_unfair_lock_lock(&dispatchLock)
            let valid = snapshot.generation == generation
                && CFAbsoluteTimeGetCurrent() - snapshot.capturedAt <= eventTTL
            os_unfair_lock_unlock(&dispatchLock)
            guard valid else {
                return
            }
            frame.postToPid(snapshot.targetPID)
        }
    }
}
