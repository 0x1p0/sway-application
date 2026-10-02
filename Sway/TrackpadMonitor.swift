import Foundation
import AppKit
import Combine

private let trackpadFrames = GestureFrameInbox()

final class TrackpadMonitor: ObservableObject {
    static let shared = TrackpadMonitor()
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Paused"

    private let settings = TrackpadSettings.shared
    private var recognizer = EdgeGestureRecognizer()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var generation: UInt64 = 0
    private var outputRevision: UInt64 = 0
    private var activeValue: RelativeGestureValue?
    private var activeAction: ZoneAction = .disabled
    private var activeTarget: String?
    private var activeApplication: pid_t?
    private var commandStepper = GestureActionStepper()
    private var haptics = GestureHapticFeedback()
    private var lastFrameTime = 0.0
    private var cursorFreezeActive = false
    private var frozenCursorPosition = CGPoint.zero
    private var scrollCapture = GestureScrollCapture()
    private var inputWatchdog: Timer?
    private var cachedConfiguration = GestureConfiguration()
    private var configurationIsDirty = true
    private var settingsObserver: AnyCancellable?
    private var brightnessPreparationGeneration: UInt64 = 0
    private var brightnessPreparationStarted = false
    private var brightnessBaseline: (value: Float, target: String)?
    private struct PendingOutput {
        let action: ZoneAction
        var count: Int
    }
    private var outputScope: UUID?
    private var pendingOutputs: [UUID: PendingOutput] = [:]

    private init() {
        // objectWillChange arrives before the setter completes: mark dirty now,
        // then rebuild once on the next frame, after all preset fields settle.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            self?.configurationIsDirty = true
        }
    }

    func start() {
        guard settings.isEnabled else { statusMessage = "Paused"; return }
        guard !isRunning else { return }
        let actions = [settings.leftZoneAction, settings.rightZoneAction, settings.topLeftAction, settings.topRightAction, settings.topEdgeAction]
        if actions.contains(.keyboardBrightness) { KeyboardBacklightCapability.shared.refresh() }
        if actions.contains(.microphoneLevel) || actions.contains(.microphoneMute) { VolumeController.microphone.refresh() }
        guard AXIsProcessTrusted() else {
            statusMessage = "Accessibility permission needed"
            return
        }
        guard installEventTap() else {
            statusMessage = "Input monitoring could not start. Check Accessibility, then retry."
            return
        }
        generation &+= 1
        recognizer.reset()
        trackpadFrames.clear()
        MTBridge_SetFrameCallback { count, contacts, _, token in
            // The native array lives only until callback return. Copy every
            // contact here, and timestamp receipt before the main-queue hop.
            let copied: [GestureContact]
            if let contacts, count > 0 {
                copied = UnsafeBufferPointer(start: contacts, count: Int(count)).map {
                    GestureContact(id: $0.identifier, x: Double($0.x), y: Double($0.y))
                }
            } else { copied = [] }
            let receivedAt = ProcessInfo.processInfo.systemUptime
            if trackpadFrames.enqueue(GestureInputFrame(contacts: copied, timestamp: receivedAt, generation: token)) {
                DispatchQueue.main.async { TrackpadMonitor.shared.drainFrames() }
            }
        }
        let deviceCount = MTBridge_Start(generation)
        guard deviceCount > 0 else {
            removeEventTap()
            MTBridge_Stop()
            statusMessage = "No compatible trackpad found. Connect it, then retry."
            return
        }
        isRunning = true
        statusMessage = "Ready for edge gestures"
    }

    func restart() { stop(); start() }

    func stop() {
        isRunning = false
        generation &+= 1
        MTBridge_Stop()
        trackpadFrames.clear()
        removeEventTap()
        finishAdjustment()
        recognizer.reset()
        scrollCapture = GestureScrollCapture()
        statusMessage = settings.isEnabled ? "Stopped" : "Paused"
        GestureTelemetry.shared.monitorStopped()
    }

    func cancelCurrentGesture() {
        cancelCurrentGesture(reason: "Gesture cancelled. Lift your fingers to start again.")
    }

    private func cancelCurrentGesture(reason: String) {
        let decision = recognizer.cancel(reason: reason)
        GestureTelemetry.shared.publish(decision, at: ProcessInfo.processInfo.systemUptime, force: true)
        finishAdjustment()
    }

    private var configuration: GestureConfiguration {
        guard configurationIsDirty else { return cachedConfiguration }
        var result = GestureConfiguration()
        result.requiredFingers = settings.minimumFingers == 1 ? 1 : 2
        result.leftWidth = settings.leftZoneWidth
        result.rightWidth = settings.rightZoneWidth
        result.topHeight = settings.topEdgeHeight
        result.topEnabled = settings.topEdgeEnabled
        result.topHorizontal = settings.topEdgeSwipeDirection == "horizontal"
        result.strict = settings.palmRejectionMode == "strict"
        result.activationThreshold = settings.activationThreshold
        result.typingCooldown = settings.typingCooldown
        result.enabledRegions = Set(GestureRegion.allCases.filter { action(for: $0) != .disabled })
        cachedConfiguration = result
        configurationIsDirty = false
        return cachedConfiguration
    }

    private func drainFrames() {
        for frame in trackpadFrames.takeBatch() {
            handleFrame(frame.contacts, at: frame.timestamp, generation: frame.generation)
        }
    }

    private func updateWatchdog() {
        guard isRunning && recognizer.isCapturing else {
            inputWatchdog?.invalidate()
            inputWatchdog = nil
            return
        }
        guard inputWatchdog == nil else { return }
        scheduleWatchdog(after: 0.25)
    }

    private func scheduleWatchdog(after delay: Double) {
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.inputWatchdog = nil
            guard self.isRunning && self.recognizer.isCapturing else { return }
            let remaining = 0.25 - (ProcessInfo.processInfo.systemUptime - self.lastFrameTime)
            if remaining <= 0 {
                self.cancelCurrentGesture(reason: "Touch tracking stopped. Lift your fingers to reset.")
            } else {
                self.scheduleWatchdog(after: remaining)
            }
        }
        inputWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleFrame(_ contacts: [GestureContact], at timestamp: Double, generation token: UInt64) {
        guard isRunning, generation == token else { return }
        guard settings.isEnabled else { stop(); return }
        defer { updateWatchdog() }
        lastFrameTime = timestamp
        if contacts.isEmpty { scrollCapture.touchesEnded() }
        // A stalled main thread must never replay queued gestures onto hardware.
        if ProcessInfo.processInfo.systemUptime - timestamp > 0.12 {
            if !contacts.isEmpty {
                _ = recognizer.process(contacts: contacts, timestamp: timestamp, configuration: configuration)
                cancelCurrentGesture(reason: "Input arrived too late. Lift your fingers and try again.")
            } else {
                _ = recognizer.process(contacts: [], timestamp: timestamp, configuration: configuration)
                finishAdjustment()
            }
            return
        }
        var decision = recognizer.process(contacts: contacts, timestamp: timestamp, configuration: configuration)
        if configuration.requiredFingers == 2, scrollCapture.blocksEdgeGesture, recognizer.isCapturing {
            decision = recognizer.cancel(reason: "Normal scrolling started first. Lift your fingers before using an edge control.")
        }
        if ExcludedAppsManager.shared.activeAppIsExcluded && !contacts.isEmpty {
            decision = recognizer.cancel(reason: "Sway is paused in this app.")
        }
        let telemetry = GestureTelemetry.shared
        if !telemetry.isTesting, recognizer.isCapturing, action(for: decision.region) == .brightness {
            prepareBrightnessBaseline(for: decision.region)
        }
        // Unsupported hardware never consumes scrolling, freezes the cursor or
        // pretends to adjust a level. Test mode can still explain the gesture.
        // Brightness may have changed since the UI was last visible: its fresh
        // read, begun during intent gathering, owns the availability verdict.
        if !telemetry.isTesting && recognizer.isCapturing && action(for: decision.region) != .brightness &&
            !isAvailable(action(for: decision.region)) {
            decision = recognizer.cancel(reason: "This control is unavailable on the current device.")
        }
        telemetry.publish(decision, at: timestamp)
        if contacts.isEmpty || decision.phase == .rejected || decision.ended {
            // The last legitimate request should settle after a normal lift.
            // Cancellation and rejected evidence discard queued hardware work.
            finishAdjustment(cancelPending: decision.phase == .rejected)
            return
        }
        guard decision.phase == .accepted else { return }
        if decision.justAccepted {
            if !telemetry.isTesting { beginAdjustment(for: decision.region) }
            return
        }
        guard !telemetry.isTesting, activeValue != nil, decision.delta != 0 else { return }
        apply(delta: decision.delta, region: decision.region)
    }

    private func prepareBrightnessBaseline(for region: GestureRegion) {
        guard !brightnessPreparationStarted else { return }
        brightnessPreparationStarted = true
        brightnessPreparationGeneration &+= 1
        let preparation = brightnessPreparationGeneration
        BrightnessController.shared.refresh { [weak self] result in
            guard let self, self.brightnessPreparationGeneration == preparation,
                  self.isRunning, self.recognizer.isCapturing, !GestureTelemetry.shared.isTesting else { return }
            guard self.action(for: region) == .brightness else {
                self.cancelCurrentGesture(reason: "Gesture settings changed. Lift your fingers to use the new setup.")
                return
            }
            switch result {
            case let .applied(value, target):
                guard target == BrightnessController.shared.targetIdentifier else {
                    self.cancelCurrentGesture(reason: "The display changed. Lift your fingers to reset.")
                    return
                }
                self.brightnessBaseline = (value, target)
                if self.recognizer.decision.phase == .accepted { self.beginAdjustment(for: region) }
            case .failed, .cancelled:
                self.cancelCurrentGesture(reason: "Brightness control is unavailable on the current display.")
            }
        }
    }

    private func beginAdjustment(for region: GestureRegion) {
        guard activeValue == nil else { return }
        let action = action(for: region)
        let value: Float
        let target: String?
        if action == .brightness {
            // If a driver is slow, skip pre-baseline deltas. Never jump from an
            // old cached brightness or replay movement accumulated during IO.
            guard let baseline = brightnessBaseline else { return }
            guard baseline.target == BrightnessController.shared.targetIdentifier else {
                cancelCurrentGesture(reason: "The display changed. Lift your fingers to reset.")
                return
            }
            value = baseline.value
            target = baseline.target
        } else {
            guard isAvailable(action) else { return }
            value = currentValue(action)
            target = targetIdentifier(action)
        }
        outputRevision &+= 1
        activeAction = action
        activeApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
        commandStepper = GestureActionStepper()
        outputScope = UUID()
        activeTarget = target
        activeValue = RelativeGestureValue(value: Double(value))
        let now = ProcessInfo.processInfo.systemUptime
        if let style = haptics.begin(value: Double(value), configuration: settings.hapticConfiguration, at: now),
           !GestureTelemetry.shared.isTesting, now - lastFrameTime <= 0.12 {
            HapticOutput.shared.play(style)
        }
        NotificationCenter.default.post(name: .swayGestureBegan, object: nil,
                                        userInfo: ["action": activeAction.rawValue])
        if settings.minimumFingers == 1 && settings.cursorFreezeOnOneFinger,
           let event = CGEvent(source: nil) {
            // CGEvent.location and CGWarpMouseCursorPosition share global display
            // coordinates, including negative origins on secondary displays.
            frozenCursorPosition = event.location
            cursorFreezeActive = true
            NSCursor.hide()
        }
    }

    private func finishAdjustment(cancelPending: Bool = true) {
        brightnessPreparationGeneration &+= 1
        brightnessPreparationStarted = false
        brightnessBaseline = nil
        if cancelPending && (activeAction != .disabled || !pendingOutputs.isEmpty) {
            outputRevision &+= 1
            for (scope, output) in pendingOutputs {
                if output.action == .volume || output.action == .outputMute { VolumeController.shared.cancelPendingRequests(in: scope) }
                else if output.action == .microphoneLevel || output.action == .microphoneMute { VolumeController.microphone.cancelPendingRequests(in: scope) }
                else if output.action == .brightness { BrightnessController.shared.cancelPendingRequests(in: scope) }
            }
            pendingOutputs.removeAll(keepingCapacity: true)
        }
        inputWatchdog?.invalidate()
        inputWatchdog = nil
        activeValue = nil
        activeAction = .disabled
        outputScope = nil
        activeTarget = nil
        activeApplication = nil
        commandStepper = GestureActionStepper()
        haptics.end()
        if cursorFreezeActive {
            cursorFreezeActive = false
            NSCursor.unhide()
        }
    }

    private func apply(delta: Double, region: GestureRegion) {
        guard var value = activeValue, let scope = outputScope, activeAction == action(for: region) else {
            cancelCurrentGesture()
            return
        }
        guard activeTarget != nil, activeTarget == targetIdentifier(activeAction) else {
            cancelCurrentGesture(reason: "The output device changed. Lift your fingers to reset.")
            return
        }
        if !activeAction.isContinuous {
            applyCommand(delta: delta, region: region, scope: scope)
            return
        }
        let limits: ClosedRange<Double>
        if activeAction == .volume {
            limits = min(settings.volumeMin, settings.volumeMax)...max(settings.volumeMin, settings.volumeMax)
        } else if activeAction == .brightness {
            limits = min(settings.brightnessMin, settings.brightnessMax)...max(settings.brightnessMin, settings.brightnessMax)
        } else { limits = 0...1 }
        let previous = value.value
        let requested = value.apply(delta: delta, sensitivity: settings.sensitivity,
                                    inverted: settings.invertScrollDirection, bounds: limits)
        guard abs(requested - previous) > 0.00001 else { return }
        // Accumulate from the requested continuous value, not delayed/quantized
        // device readback. The controllers coalesce writes off the main thread.
        activeValue = value
        // Keep the epoch stable through this gesture. Already-applied samples
        // can render while a newer desired value is pending; filtering by every
        // request would freeze feedback whenever the driver runs below 120 Hz.
        let revision = outputRevision
        let target = activeTarget
        if pendingOutputs[scope] == nil { pendingOutputs[scope] = PendingOutput(action: activeAction, count: 0) }
        pendingOutputs[scope]?.count += 1
        if activeAction == .volume || activeAction == .microphoneLevel {
            let action = activeAction
            let audio = action == .volume ? VolumeController.shared : VolumeController.microphone
            audio.requestVolume(Float(requested), muteAtZero: action == .volume && settings.muteAtZero,
                                                   expectedTargetIdentifier: target, cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(measured, _, appliedTarget):
                    guard appliedTarget == target, appliedTarget == self.targetIdentifier(action) else { return }
                    self.publishAdjustment(measured, action: action, region: region)
                case .failed:
                    self.cancelCurrentGesture(reason: "The device did not accept this adjustment.")
                case .cancelled: break
                }
            }
        } else {
            BrightnessController.shared.requestBrightness(Float(requested), expectedTargetIdentifier: target,
                                                           cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(measured, appliedTarget):
                    guard appliedTarget == target, appliedTarget == self.targetIdentifier(.brightness) else { return }
                    self.publishAdjustment(measured, action: .brightness, region: region)
                case .failed:
                    self.cancelCurrentGesture(reason: "The device did not accept this adjustment.")
                case .cancelled: break
                }
            }
        }
    }

    private func applyCommand(delta: Double, region: GestureRegion, scope: UUID) {
        guard let application = activeApplication,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application else {
            cancelCurrentGesture(reason: "The active app changed. Lift your fingers before sending another action.")
            return
        }
        guard let increasing = commandStepper.consume(delta: delta, sensitivity: settings.sensitivity,
            inverted: settings.invertScrollDirection, repeats: activeAction.repeatsWhileSwiping,
            at: ProcessInfo.processInfo.systemUptime) else { return }
        let action = activeAction
        if action == .outputMute || action == .microphoneMute {
            let controller = action == .outputMute ? VolumeController.shared : VolumeController.microphone
            let revision = outputRevision
            let target = activeTarget
            pendingOutputs[scope] = PendingOutput(action: action, count: 1)
            controller.requestMuted(!increasing, expectedTargetIdentifier: target, cancellationScope: scope) { [weak self] result in
                guard let self else { return }
                defer { self.outputFinished(in: scope) }
                guard self.outputRevision == revision else { return }
                switch result {
                case let .applied(value, muted, identifier):
                    guard target == identifier, identifier == controller.targetIdentifier else { return }
                    if action == .outputMute { self.publishAdjustment(muted ? 0 : value, action: .volume, region: region) }
                    else {
                        NotificationCenter.default.post(name: .microphoneMuteChanged, object: muted)
                    }
                case .failed: self.cancelCurrentGesture(reason: "The device did not confirm the mute change. Check its controls.")
                case .cancelled: break
                }
            }
            return
        }
        let custom = increasing ? settings.swipeUpShortcut : settings.swipeDownShortcut
        guard let command = EdgeCommand.resolve(action, increasing: increasing, custom: custom),
              EdgeActionController.send(command, expectedApplication: application) else {
            cancelCurrentGesture(reason: "This action is not configured or could not be sent. Check its settings.")
            return
        }
        if settings.hapticFeedback { HapticOutput.shared.play(settings.hapticStyle) }
    }

    private func outputFinished(in scope: UUID) {
        guard let pending = pendingOutputs[scope] else { return }
        if pending.count <= 1 { pendingOutputs[scope] = nil }
        else { pendingOutputs[scope]?.count -= 1 }
    }

    private func publishAdjustment(_ measured: Float, action: ZoneAction, region: GestureRegion) {
        let name: Notification.Name
        if action == .volume { name = region.isTop ? .topEdgeVolumeChanged : .volumeChanged }
        else if action == .microphoneLevel { name = .microphoneLevelChanged }
        else { name = region.isTop ? .topEdgeBrightnessChanged : .brightnessChanged }
        let side = region == .left || region == .topLeft ? "left" : "right"
        NotificationCenter.default.post(name: name, object: measured,
                                        userInfo: ["zone": side, "gestureRegion": region.rawValue])
        if activeValue != nil { haptic(at: measured) }
    }

    private func action(for region: GestureRegion) -> ZoneAction {
        switch region {
        case .left: return settings.leftZoneAction
        case .right: return settings.rightZoneAction
        case .topLeft: return settings.topLeftAction
        case .topRight: return settings.topRightAction
        case .top: return settings.topEdgeAction
        case .none: return .disabled
        }
    }

    private func isAvailable(_ action: ZoneAction) -> Bool {
        switch action {
        case .volume: return VolumeController.shared.isAvailable
        case .brightness: return BrightnessController.shared.isAvailable
        case .microphoneLevel: return VolumeController.microphone.isAvailable
        case .outputMute: return VolumeController.shared.supportsMute
        case .microphoneMute: return VolumeController.microphone.supportsMute
        case .keyboardBrightness: return KeyboardBacklightCapability.shared.isAvailable
        case .customShortcut: return !settings.swipeUpShortcut.isEmpty || !settings.swipeDownShortcut.isEmpty
        case .disabled: return false
        default: return NSWorkspace.shared.frontmostApplication != nil
        }
    }

    private func currentValue(_ action: ZoneAction) -> Float {
        switch action {
        case .volume: return VolumeController.shared.getVolume()
        case .brightness: return BrightnessController.shared.getBrightness()
        case .microphoneLevel: return VolumeController.microphone.getVolume()
        default: return 0.5
        }
    }

    private func targetIdentifier(_ action: ZoneAction) -> String? {
        switch action {
        case .volume, .outputMute: return VolumeController.shared.targetIdentifier
        case .brightness: return BrightnessController.shared.targetIdentifier
        case .microphoneLevel, .microphoneMute: return VolumeController.microphone.targetIdentifier
        case .disabled: return nil
        default: return NSWorkspace.shared.frontmostApplication.map { "app:\($0.processIdentifier)" }
        }
    }

    private func haptic(at value: Float) {
        guard settings.hapticFeedback else { haptics.end(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !GestureTelemetry.shared.isTesting, recognizer.decision.phase == .accepted,
              now - lastFrameTime <= 0.12 else { return }
        let lower = activeAction == .volume ? settings.volumeMin : activeAction == .brightness ? settings.brightnessMin : 0
        let upper = activeAction == .volume ? settings.volumeMax : activeAction == .brightness ? settings.brightnessMax : 1
        if let style = haptics.update(value: Double(value), bounds: min(lower, upper)...max(lower, upper), at: now) {
            HapticOutput.shared.play(style)
        }
    }

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let types: [CGEventType] = [.scrollWheel, .keyDown, .mouseMoved,
                                   .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                   .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, _ in
            TrackpadMonitor.shared.handleEvent(type: type, event: event)
        }, userInfo: nil) else { return false }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard isRunning else { return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCurrentGesture(reason: "Input monitoring was interrupted. Lift your fingers to reset.")
            scrollCapture = GestureScrollCapture()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return pass
        }
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            if cursorFreezeActive {
                CGWarpMouseCursorPosition(frozenCursorPosition)
                return nil
            }
            return pass
        }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .keyDown {
            if event.getIntegerValueField(.eventSourceUserData) == EdgeActionController.eventMarker { return pass }
            let decision = recognizer.keyDown(at: now)
            GestureTelemetry.shared.publish(decision, at: now, force: true)
            finishAdjustment()
            return pass
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            cancelCurrentGesture(reason: "Click detected. Lift your fingers before swiping.")
            return pass
        }
        guard type == .scrollWheel else { return pass }
        guard let scrolling = NSEvent(cgEvent: event), scrolling.hasPreciseScrollingDeltas else { return pass }
        let phase = scrollPhase(scrolling.phase)
        let momentum = scrollPhase(scrolling.momentumPhase)
        scrollCapture.prepare(phase: phase, momentum: momentum)
        // Native touch callbacks and the event tap arrive via separate queues.
        // Apply all already-received touches/lifts before deciding who owns the
        // beginning of this scroll; do not use the preceding gesture's contacts.
        if momentum == .none && (phase == .mayBegin || phase == .began) {
            drainFrames()
        }
        let observedAt = ProcessInfo.processInfo.systemUptime
        let eligible = settings.isEnabled && settings.minimumFingers == 2 && recognizer.isCapturing &&
            recognizer.decision.count == 2 && observedAt - lastFrameTime < 0.12 &&
            !ExcludedAppsManager.shared.activeAppIsExcluded
        let consume = scrollCapture.consume(precise: true, phase: phase, momentum: momentum,
                                            eligible: eligible, at: observedAt)
        if scrollCapture.blocksEdgeGesture && settings.minimumFingers == 2 && recognizer.isCapturing {
            cancelCurrentGesture(reason: "Normal scrolling started first. Lift your fingers before using an edge control.")
        }
        return consume ? nil : pass
    }

    private func scrollPhase(_ phase: NSEvent.Phase) -> GestureScrollCapture.Phase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.stationary) { return .stationary }
        return .none
    }
}

extension Notification.Name {
    static let swayGestureBegan = Notification.Name("swayGestureBegan")
    static let volumeChanged = Notification.Name("volumeChanged")
    static let brightnessChanged = Notification.Name("brightnessChanged")
    static let microphoneLevelChanged = Notification.Name("microphoneLevelChanged")
    static let microphoneMuteChanged = Notification.Name("microphoneMuteChanged")
    static let topEdgeVolumeChanged = Notification.Name("topEdgeVolumeChanged")
    static let topEdgeBrightnessChanged = Notification.Name("topEdgeBrightnessChanged")
}
