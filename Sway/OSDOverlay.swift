import AppKit
import Combine

/// A lazy native indicator. Input frames update a single latest value; ordering,
/// screen lookup, and positioning occur only when a presentation begins.
final class OSDOverlay {
    static let shared = OSDOverlay()
    private let settings: TrackpadSettings
    private var window: OSDWindow?
    private var surface: OSDSurfaceView?
    private var hideTimer: Timer?
    private var fadeTimer: Timer?
    private var updateTimer: Timer?
    private var hideDeadline: TimeInterval = 0
    private var lastDisplayTime: TimeInterval = 0
    private var pendingValue: (OSDType, Double)?
    private var configuration: OSDConfiguration
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        settings = .shared
        configuration = OSDConfiguration(settings: settings)
        Publishers.CombineLatest4(settings.$osdStyle, settings.$osdHorizontalWidth,
                                  settings.$osdPosition, settings.$appearanceMode)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshConfiguration() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.window?.isVisible == true else { return }
                self.repositionWindow()
            }
            .store(in: &subscriptions)
    }

    func show(type: OSDType, value: Float) {
        guard value.isFinite else { return }
        if Thread.isMainThread { present(type: type, value: Double(value)) }
        else { DispatchQueue.main.async { [weak self] in self?.present(type: type, value: Double(value)) } }
    }

    private func present(type: OSDType, value: Double) {
        refreshConfiguration()
        guard configuration.style != "off" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        hideDeadline = now + 1.35
        let value = max(0, min(1, value))
        let isStarting = window?.isVisible != true
        if window == nil {
            let surface = OSDSurfaceView(horizontal: configuration.isHorizontal)
            let window = OSDWindow(contentRect: NSRect(origin: .zero, size: configuration.size))
            window.contentView = surface
            self.surface = surface
            self.window = window
            configureWindow()
        }
        // Cancel the sole owned fade. No old completion can hide a new request.
        if fadeTimer != nil {
            fadeTimer?.invalidate()
            fadeTimer = nil
            window?.alphaValue = 1
        }
        if isStarting {
            repositionWindow()
            window?.alphaValue = 1
            lastDisplayTime = 0
        }
        pendingValue = (type, value)
        let remaining = 1.0 / 60.0 - (now - lastDisplayTime)
        if remaining <= 0 || isStarting {
            updateTimer?.invalidate()
            updateTimer = nil
            displayPendingValue()
        } else if updateTimer == nil {
            updateTimer = scheduledTimer(after: remaining) { [weak self] in
                self?.updateTimer = nil
                self?.displayPendingValue()
            }
        }
        // Commit the first value before the compositor can display the window.
        if isStarting { window?.orderFrontRegardless() }
        if hideTimer == nil { scheduleHideCheck(after: 1.35) }
    }

    private func displayPendingValue() {
        guard let (type, value) = pendingValue else { return }
        pendingValue = nil
        lastDisplayTime = ProcessInfo.processInfo.systemUptime
        surface?.content.update(type: type, value: value)
    }

    private func scheduleHideCheck(after delay: TimeInterval) {
        hideTimer = scheduledTimer(after: delay, tolerance: 0.04) { [weak self] in
            guard let self else { return }
            self.hideTimer = nil
            let remaining = self.hideDeadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { self.scheduleHideCheck(after: remaining) }
            else { self.beginFade() }
        }
    }

    private func beginFade() {
        guard window?.isVisible == true else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { dismiss(); return }
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = (ProcessInfo.processInfo.systemUptime - started) / 0.16
            if progress >= 1 { self.dismiss() }
            else { self.window?.alphaValue = 1 - progress }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func dismiss() {
        hideTimer?.invalidate()
        fadeTimer?.invalidate()
        updateTimer?.invalidate()
        hideTimer = nil
        fadeTimer = nil
        updateTimer = nil
        pendingValue = nil
        window?.orderOut(nil)
        window?.alphaValue = 1
    }

    private func refreshConfiguration() {
        let updated = OSDConfiguration(settings: settings)
        guard updated != configuration else { return }
        configuration = updated
        if configuration.style == "off" { dismiss() }
        else if window != nil { configureWindow() }
    }

    private func configureWindow() {
        guard let window else { return }
        window.appearance = configuration.appearance
        surface?.content.isHorizontal = configuration.isHorizontal
        window.setContentSize(configuration.size)
        if window.isVisible { repositionWindow() }
    }

    private func repositionWindow() {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 24
        let x: CGFloat
        let y: CGFloat
        if configuration.isHorizontal {
            x = frame.midX - size.width / 2
            y = frame.minY + margin
        } else {
            y = frame.midY - size.height / 2
            switch configuration.position {
            case .left: x = frame.minX + margin
            case .center: x = frame.midX - size.width / 2
            case .right: x = frame.maxX - size.width - margin
            }
        }
        let origin = NSPoint(x: x, y: y)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    private func scheduledTimer(after delay: TimeInterval, tolerance: TimeInterval = 0,
                                action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { _ in action() }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

private struct OSDConfiguration: Equatable {
    let style: String
    let width: Double
    let position: OSDPosition
    let appearanceMode: String
    init(settings: TrackpadSettings) {
        style = settings.osdStyle
        width = settings.osdHorizontalWidth
        position = settings.osdPosition
        appearanceMode = settings.appearanceMode
    }
    var isHorizontal: Bool { style == "horizontal" }
    var size: NSSize {
        isHorizontal ? NSSize(width: max(160, min(320, width.isFinite ? width : 240)), height: 48)
                     : NSSize(width: 52, height: 208)
    }
    var appearance: NSAppearance? {
        switch appearanceMode {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}

final class OSDWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        // No opaque backing or clipping parent: AppKit owns glass compositing.
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OSDType: Equatable {
    case volume, brightness
    var icon: String { self == .volume ? "speaker.wave.2.fill" : "sun.max.fill" }
    var label: String { self == .volume ? "Volume" : "Brightness" }
}

/// Shared by production and safe fixtures. Apple's supported `contentView`
/// embedding API places our readout inside one native glass surface.
final class OSDSurfaceView: NSView {
    let content: OSDContentView
    private var material: NSView?
    private let forceReduceTransparency: Bool?
    private var accessibilityObserver: NSObjectProtocol?

    init(horizontal: Bool, forceReduceTransparency: Bool? = nil) {
        content = OSDContentView(horizontal: horizontal)
        self.forceReduceTransparency = forceReduceTransparency
        super.init(frame: .zero)
        rebuildMaterial()
        if forceReduceTransparency == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.rebuildMaterial() }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private func rebuildMaterial() {
        content.removeFromSuperview()
        material?.removeFromSuperview()
        let reduced = forceReduceTransparency ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let background: NSView
        if reduced {
            let opaque = OSDOpaqueSurface(frame: bounds)
            opaque.addSubview(content)
            background = opaque
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 24
            glass.contentView = content
            background = glass
        } else {
            let vibrant = NSVisualEffectView(frame: bounds)
            vibrant.material = .hudWindow
            vibrant.blendingMode = .behindWindow
            vibrant.state = .active
            vibrant.wantsLayer = true
            vibrant.layer?.cornerRadius = 24
            vibrant.layer?.masksToBounds = true
            vibrant.addSubview(content)
            background = vibrant
        }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        background.autoresizingMask = [.width, .height]
        material = background
        addSubview(background)
    }
    override func layout() {
        super.layout()
        material?.frame = bounds
        content.frame = bounds
    }
}

private final class OSDOpaqueSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 24, yRadius: 24).fill()
    }
}

/// Native labels and two tiny layers; no SwiftUI view invalidation or overlapping
/// 100 ms fill animations on a continuous gesture's hot path.
final class OSDContentView: NSView {
    var isHorizontal: Bool { didSet { if oldValue != isHorizontal { needsLayout = true } } }
    private let icon = NSImageView()
    private let percentage = NSTextField(labelWithString: "50")
    private let track = CALayer()
    private let fill = CALayer()
    private var type: OSDType = .volume
    private var value: Double = 0.5

    init(horizontal: Bool) {
        isHorizontal = horizontal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .labelColor
        percentage.textColor = .labelColor
        percentage.alignment = .center
        percentage.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        addSubview(icon)
        addSubview(percentage)
        track.cornerRadius = 3
        fill.cornerRadius = 3
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        refreshIcon()
        updateColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { nil }

    func update(type: OSDType, value: Double) {
        guard value.isFinite else { return }
        let clipped = max(0, min(1, value))
        let iconChanged = self.type != type || (self.value == 0) != (clipped == 0)
        guard self.type != type || abs(self.value - clipped) >= 0.0005 else { return }
        self.type = type
        self.value = clipped
        if iconChanged { refreshIcon() }
        let text = "\(Int((clipped * 100).rounded()))"
        if percentage.stringValue != text { percentage.stringValue = text }
        updateFill()
        updateAccessibility()
    }

    override func layout() {
        super.layout()
        let trackFrame: NSRect
        if isHorizontal {
            icon.frame = NSRect(x: 15, y: (bounds.height - 20) / 2, width: 20, height: 20)
            percentage.frame = NSRect(x: bounds.width - 43, y: (bounds.height - 16) / 2, width: 28, height: 16)
            trackFrame = NSRect(x: 46, y: (bounds.height - 6) / 2, width: max(0, bounds.width - 100), height: 6)
        } else {
            icon.frame = NSRect(x: (bounds.width - 20) / 2, y: bounds.height - 35, width: 20, height: 20)
            percentage.frame = NSRect(x: 7, y: 14, width: bounds.width - 14, height: 16)
            trackFrame = NSRect(x: (bounds.width - 6) / 2, y: 40, width: 6, height: max(0, bounds.height - 87))
        }
        withoutAnimation { track.frame = trackFrame }
        updateFill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateFill() {
        var frame = track.frame
        if isHorizontal { frame.size.width *= value }
        else { frame.size.height *= value }
        withoutAnimation { fill.frame = frame }
    }
    private func refreshIcon() {
        let name = type == .volume && value == 0 ? "speaker.slash.fill" : type.icon
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation {
                track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.88).cgColor
            }
        }
    }
    private func updateAccessibility() {
        setAccessibilityLabel(type.label)
        setAccessibilityValue("\(Int((value * 100).rounded())) percent")
    }
    private func withoutAnimation(_ action: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        action()
        CATransaction.commit()
    }
}
