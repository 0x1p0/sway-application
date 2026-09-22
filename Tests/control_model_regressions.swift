import Foundation
import CoreAudio
import CoreGraphics

private final class ModelAudioBackend: AudioOutputBackend {
    private let lock = NSLock()
    var token = AudioOutputToken(device: 42, source: nil)
    var scalar: Float = 0.4
    var muted = false
    var failWrites = false
    var operations: [String] = []
    var blocker: (kind: String, entered: DispatchSemaphore, release: DispatchSemaphore)?
    private var queue: DispatchQueue?
    private var handler: ((AudioBackendEvent) -> Void)?
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func start(on queue: DispatchQueue, handler: @escaping (AudioBackendEvent) -> Void) {
        locked { self.queue = queue; self.handler = handler }
    }
    func stop() { locked { handler = nil } }
    func currentOutput() -> AudioOutputToken? { locked { token } }
    func configuration(for token: AudioOutputToken) -> AudioOutputConfiguration {
        AudioOutputConfiguration(token: token, name: "Fake speakers", volumeElements: [0], volumeWritable: true,
                                 muteElements: [0], muteWritable: true)
    }
    func observe(_ configuration: AudioOutputConfiguration?) {}
    func volume(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? { locked { scalar } }
    func mute(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? { locked { muted } }
    private func waitIfBlocked(_ kind: String) {
        let wait = locked { () -> (String, DispatchSemaphore, DispatchSemaphore)? in
            guard blocker?.kind == kind else { return nil }
            defer { blocker = nil }
            return blocker
        }
        wait?.1.signal()
        if let wait { _ = wait.2.wait(timeout: .now() + 3) }
    }
    func setVolume(_ value: Float, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        waitIfBlocked("volume")
        return locked { operations.append("volume"); if failWrites { return false }; scalar = value; return true }
    }
    func setMute(_ value: Bool, device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        waitIfBlocked("mute")
        return locked { operations.append(value ? "mute" : "unmute"); if failWrites { return false }; muted = value; return true }
    }
    func emit(_ event: AudioBackendEvent) {
        let state = locked { (queue, handler) }
        state.0?.async { state.1?(event) }
    }
    func block(_ kind: String) -> (DispatchSemaphore, DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        locked { blocker = (kind, entered, release) }
        return (entered, release)
    }
}

private final class ModelDisplayBackend: BrightnessHardware {
    let canWrite = true
    private let lock = NSLock()
    private var value: Float = 0.7
    private var handler: (() -> Void)?
    func activeDisplays() -> [CGDirectDisplayID] { [17] }
    func isBuiltIn(_ display: CGDirectDisplayID) -> Bool { display == 17 }
    func isActive(_ display: CGDirectDisplayID) -> Bool { display == 17 }
    func read(_ display: CGDirectDisplayID) -> Float? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: Float, to display: CGDirectDisplayID) -> Bool {
        lock.lock(); self.value = value; lock.unlock(); return true
    }
    func observeChanges(_ callback: @escaping () -> Void) { handler = callback }
}

private final class ModelFixture {
    let backend = ModelAudioBackend()
    let audio: VolumeController
    let display: BrightnessController
    let model: ControlCenterModel
    let suite = "Sway.ControlTests.\(UUID().uuidString)"
    init() {
        audio = VolumeController(backend: backend)
        display = BrightnessController(backend: ModelDisplayBackend())
        let settings = TrackpadSettings(defaults: UserDefaults(suiteName: suite)!)
        model = ControlCenterModel(settings: settings, preview: false, audio: audio, display: display)
        audio.flushWorkerForTesting()
        model.refresh()
        ControlModelTests.waitFor("fixture hardware ready") { model.volumeAvailable && model.brightnessAvailable }
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

@main private enum ControlModelTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }; checks += 1
    }
    static func close(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.0001 }
    static func waitFor(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        expect(condition(), message)
    }
    static func main() {
        testRapidMute()
        testOptimisticDrag()
        testExternalAndFailures()
        testAtomicUndoAndRouteGuard()
        testVisibilityAndPreview()
        print("\(checks) control model regression checks passed (fake audio/display hardware only).")
    }

    static func testRapidMute() {
        let fixture = ModelFixture(), model = fixture.model
        let blocked = fixture.backend.block("mute")
        model.toggleMute()
        expect(model.isMuted, "first mute click is immediately reflected")
        expect(blocked.0.wait(timeout: .now() + 1) == .success, "slow mute driver entered")
        model.toggleMute()
        expect(!model.isMuted, "second rapid mute click reverses optimistic intention")
        blocked.1.signal()
        waitFor("rapid mute reaches final intended state") {
            fixture.backend.locked { fixture.backend.operations.count >= 2 && !fixture.backend.muted }
        }
        fixture.audio.flushWorkerForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        expect(!model.isMuted, "old mute readback never overrides final unmute")
        expect(fixture.backend.locked { fixture.backend.operations } == ["mute", "unmute"], "rapid clicks execute opposite mute states")
    }

    static func testOptimisticDrag() {
        let fixture = ModelFixture(), model = fixture.model
        model.captureUndo(.volume)
        let first = fixture.backend.block("volume")
        expect(model.adjust(.volume, to: 0.6), "first slider request accepted")
        expect(first.0.wait(timeout: .now() + 1) == .success, "first slow scalar entered")
        let second = fixture.backend.block("volume")
        expect(model.adjust(.volume, to: 0.8), "next slider request accepted")
        expect(close(model.volume, 0.8), "slider tracks latest desired position immediately")
        var measuredProgress: [Float] = []
        let observer = NotificationCenter.default.addObserver(forName: .volumeChanged, object: nil, queue: nil) {
            if let value = $0.object as? Float { measuredProgress.append(value) }
        }
        first.1.signal()
        expect(second.0.wait(timeout: .now() + 1) == .success, "latest scalar begins after first measured write")
        waitFor("measured in-flight progress is published") { !measuredProgress.isEmpty }
        expect(close(model.volume, 0.8), "old actual readback does not snap back a dragged slider")
        expect(close(Double(measuredProgress[0]), 0.6), "OSD notification is measured, not optimistic")
        second.1.signal()
        waitFor("final slider hardware value settles") { close(Double(fixture.audio.getVolume()), 0.8) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        expect(close(model.volume, 0.8), "settled slider matches device")
        expect(close(model.undoValues?.value ?? -1, 0.4), "drag undo captures preinteraction scalar")
        NotificationCenter.default.removeObserver(observer)
    }

    static func testExternalAndFailures() {
        let fixture = ModelFixture(), model = fixture.model
        var indicators = 0
        let observer = NotificationCenter.default.addObserver(forName: .volumeChanged, object: nil, queue: nil) { _ in indicators += 1 }
        fixture.backend.locked { fixture.backend.scalar = 0.22; fixture.backend.muted = true }
        fixture.backend.emit(.state)
        waitFor("external volume/mute refresh model") { close(model.volume, 0.22) && model.isMuted }
        expect(indicators == 0, "external state changes do not emit intentional OSD")
        fixture.backend.locked { fixture.backend.failWrites = true }
        model.captureUndo(.volume)
        expect(model.adjust(.volume, to: 0.9), "failed write starts optimistically")
        expect(close(model.volume, 0.9), "optimistic failure still responds immediately")
        waitFor("failure rolls back to measured state") { model.message != nil && close(model.volume, 0.22) }
        expect(model.isMuted, "failure reconciles measured mute state")
        expect(indicators == 0, "failed write never produces success OSD")
        expect(!model.adjust(.volume, to: .nan), "nonfinite input rejected")
        NotificationCenter.default.removeObserver(observer)
    }

    static func testAtomicUndoAndRouteGuard() {
        let fixture = ModelFixture(), model = fixture.model
        fixture.backend.locked { fixture.backend.muted = true }
        fixture.backend.emit(.state)
        waitFor("initial muted state ready") { model.isMuted }
        model.captureUndo(.volume)
        model.adjust(.volume, to: 0.9)
        waitFor("adjustment unmuted and settled") { !model.isMuted && close(Double(fixture.audio.getVolume()), 0.9) }
        fixture.backend.locked { fixture.backend.operations = [] }
        model.undo()
        waitFor("atomic undo settles") { model.undoValues == nil && model.isMuted && close(model.volume, 0.4) }
        expect(fixture.backend.locked { fixture.backend.operations } == ["mute", "volume"], "undo restores muted scalar without audible unmute")
        model.captureUndo(.volume)
        fixture.backend.locked { fixture.backend.token = AudioOutputToken(device: 43, source: nil); fixture.backend.operations = [] }
        fixture.backend.emit(.route)
        waitFor("replacement route reaches cache") { fixture.audio.targetIdentifier == "audio:43" }
        model.undo()
        expect(model.undoValues == nil && model.message?.contains("device changed") == true, "undo explains stale route and clears action")
        expect(fixture.backend.locked { fixture.backend.operations.isEmpty }, "undo never writes a replacement audio device")
        model.captureUndo(.brightness)
        model.adjust(.brightness, to: 0.3)
        waitFor("display slider settled") { close(model.brightness, 0.3) && close(Double(fixture.display.getBrightness()), 0.3) }
        model.undo()
        waitFor("display undo settled") { model.undoValues == nil && close(model.brightness, 0.7) }
    }

    static func testVisibilityAndPreview() {
        let fixture = ModelFixture(), model = fixture.model
        expect(!model.visibleRefreshActiveForTesting, "hidden model has no refresh timer")
        model.setVisible("settings", true)
        expect(model.visibleRefreshActiveForTesting, "visible settings enables fallback display refresh")
        model.setVisible("popover", true)
        model.setVisible("settings", false)
        expect(model.visibleRefreshActiveForTesting, "one remaining visible surface keeps refresh active")
        model.setVisible("popover", false)
        expect(!model.visibleRefreshActiveForTesting, "last surface closing releases refresh timer")
        let preview = ControlCenterModel(settings: TrackpadSettings(defaults: UserDefaults(suiteName: fixture.suite)!),
                                         preview: true, audio: fixture.audio, display: fixture.display)
        preview.refresh(); preview.toggleMute(); preview.undo(); preview.setVisible("test", true)
        expect(!preview.adjust(.volume, to: 1), "preview rejects hardware adjustment")
        expect(!preview.visibleRefreshActiveForTesting, "preview has no refresh timer")
        expect(fixture.backend.locked { fixture.backend.operations.isEmpty }, "preview performs no audio writes")
    }
}
