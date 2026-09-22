import SwiftUI
import AppKit
import Carbon
import Combine
import UniformTypeIdentifiers

// Semantic monochrome colors follow macOS appearance and accessibility settings.
enum SwayTheme {
    static let brand = Color.primary
    static let accent = Color.primary
    static let brightness = Color.primary
    static let volume = Color.primary
    static let canvas = Color(nsColor: .controlBackgroundColor)
}

extension ZoneAction {
    var tint: Color {
        switch self {
        case .brightness: return SwayTheme.brightness
        case .volume: return SwayTheme.volume
        case .disabled: return .secondary
        }
    }
}

// One lightweight model survives panel closures; view trees do not. Hardware
// listeners update cached values, with a visible-only display/permission refresh.
final class ControlCenterModel: ObservableObject {
    static let shared = ControlCenterModel(settings: .shared, preview: false)

    struct UndoChange {
        let action: ZoneAction
        let value: Double
        let device: String
        let muted: Bool
    }
    @Published var volume: Double = 0
    @Published var brightness: Double = 0
    @Published var volumeAvailable = false
    @Published var brightnessAvailable = false
    @Published var volumeDevice = "Audio output"
    @Published var brightnessDevice = "Built-in display"
    @Published var hasAccess = false
    @Published var isMuted = false
    @Published var message: String?
    @Published var undoValues: UndoChange?
    private var lastAudibleVolume: Double = 0.35
    private var cancellables = Set<AnyCancellable>()
    private var visibleSurfaces = Set<String>()
    private var visibleTimer: Timer?
    private var interactionEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var pendingAudio: (revision: UInt64, target: String)?
    private var pendingDisplay: (revision: UInt64, target: String)?
    let preview: Bool
    private let settings: TrackpadSettings
    private let injectedAudio: VolumeController?
    private let injectedDisplay: BrightnessController?
    private var audioController: VolumeController { injectedAudio ?? .shared }
    private var displayController: BrightnessController { injectedDisplay ?? .shared }

    init(settings: TrackpadSettings, preview: Bool,
         audio: VolumeController? = nil, display: BrightnessController? = nil) {
        self.settings = settings
        self.preview = preview
        injectedAudio = audio
        injectedDisplay = display
        if preview {
            volume = 0.28; brightness = 0.72
            volumeAvailable = true; brightnessAvailable = true
            volumeDevice = "MacBook speakers"; brightnessDevice = "Built-in display"
            hasAccess = true
        } else {
            NotificationCenter.default.publisher(for: .swayGestureBegan)
                .sink { [weak self] note in
                    guard let raw = note.userInfo?["action"] as? String, let action = ZoneAction(rawValue: raw) else { return }
                    self?.captureUndo(action)
                }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .swayAudioStateChanged)
                .sink { [weak self] _ in self?.refreshAudio() }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: .swayDisplayStateChanged)
                .sink { [weak self] _ in self?.refreshDisplay() }.store(in: &cancellables)
        }
    }

    deinit { visibleTimer?.invalidate() }

    private func assign<Value: Equatable>(_ key: ReferenceWritableKeyPath<ControlCenterModel, Value>, _ value: Value) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func refreshAccess() {
        guard !preview else { return }
        assign(\.hasAccess, AXIsProcessTrusted())
    }

    func refresh() {
        guard !preview else { return }
        refreshAccess()
        refreshAudio()
        refreshDisplay()
        audioController.refresh()
        displayController.refresh()
    }

    func setVisible(_ surface: String, _ visible: Bool) {
        guard !preview else { return }
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        if visibleSurfaces.isEmpty {
            visibleTimer?.invalidate()
            visibleTimer = nil
        } else if visibleTimer == nil {
            // DisplayServices has no public scalar-change listener. Poll only
            // while a user is looking at the controls, never for hidden panels.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshAccess()
                self?.displayController.refresh()
            }
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common)
            visibleTimer = timer
        }
    }

    private func refreshAudio() {
        let audio = audioController
        assign(\.volumeAvailable, audio.isAvailable)
        assign(\.volumeDevice, audio.deviceName)
        if let pending = pendingAudio, pending.target != audio.targetIdentifier {
            pendingAudio = nil
        }
        if pendingAudio == nil {
            assign(\.volume, Double(audio.getVolume()))
            assign(\.isMuted, audio.isMuted)
        }
        if audio.getVolume() > 0.01 { lastAudibleVolume = Double(audio.getVolume()) }
    }

    private func refreshDisplay() {
        let display = displayController
        assign(\.brightnessAvailable, display.isAvailable)
        assign(\.brightnessDevice, display.deviceName)
        if let pending = pendingDisplay, pending.target != display.targetIdentifier {
            pendingDisplay = nil
        }
        if pendingDisplay == nil { assign(\.brightness, Double(display.getBrightness())) }
    }

    func captureUndo(_ action: ZoneAction) {
        guard !preview, action != .disabled else { return }
        interactionEpoch &+= 1
        pendingAudio = nil
        pendingDisplay = nil
        guard action == .volume ? audioController.isAvailable : displayController.isAvailable,
              let identifier = action == .volume ? audioController.targetIdentifier : displayController.targetIdentifier else { return }
        undoValues = UndoChange(action: action,
            value: action == .volume ? Double(audioController.getVolume()) : Double(displayController.getBrightness()),
            device: identifier,
            muted: action == .volume && audioController.isMuted)
    }

    /// The slider responds immediately; only measured driver success emits OSD
    /// feedback. Slow output devices cannot stall the main thread or build a
    /// backlog of obsolete values.
    @discardableResult
    func adjust(_ action: ZoneAction, to value: Double, restoringMute: Bool? = nil, completion: ((Bool) -> Void)? = nil) -> Bool {
        guard !preview, value.isFinite else { return false }
        revision &+= 1
        let request = revision
        let epoch = interactionEpoch
        switch action {
        case .volume:
            let audio = audioController
            guard audio.isAvailable, let target = audio.targetIdentifier else { return false }
            let bounded = min(settings.volumeMax, max(settings.volumeMin, value))
            pendingAudio = (request, target)
            assign(\.volume, bounded)
            if let restoringMute { assign(\.isMuted, restoringMute) }
            else if bounded > 0 { assign(\.isMuted, false) }
            audio.requestVolume(Float(bounded), muteAtZero: settings.muteAtZero, restoringMute: restoringMute, expectedTargetIdentifier: target) { [weak self] result in
                guard let self else { return }
                let latest = self.pendingAudio?.revision == request
                if latest { self.pendingAudio = nil; self.refreshAudio() }
                guard self.interactionEpoch == epoch else { completion?(false); return }
                switch result {
                case let .applied(actual, muted, identifier):
                    guard identifier == audio.targetIdentifier else { completion?(false); return }
                    if latest { self.assign(\.message, nil) }
                    NotificationCenter.default.post(name: .volumeChanged, object: muted ? Float(0) : actual, userInfo: ["source": "control"])
                    completion?(true)
                case .failed:
                    if latest { self.assign(\.message, "This audio output did not accept the change. Check its controls or connection.") }
                    completion?(false)
                case .cancelled: completion?(false)
                }
            }
        case .brightness:
            let display = displayController
            guard display.isAvailable, let target = display.targetIdentifier else { return false }
            let bounded = min(settings.brightnessMax, max(settings.brightnessMin, value))
            pendingDisplay = (request, target)
            assign(\.brightness, bounded)
            display.requestBrightness(Float(bounded), expectedTargetIdentifier: target) { [weak self] result in
                guard let self else { return }
                let latest = self.pendingDisplay?.revision == request
                if latest { self.pendingDisplay = nil; self.refreshDisplay() }
                guard self.interactionEpoch == epoch else { completion?(false); return }
                switch result {
                case let .applied(actual, identifier):
                    guard identifier == display.targetIdentifier else { completion?(false); return }
                    if latest { self.assign(\.message, nil) }
                    NotificationCenter.default.post(name: .brightnessChanged, object: actual, userInfo: ["source": "control"])
                    completion?(true)
                case .failed:
                    if latest { self.assign(\.message, "This display did not accept the change. Check its controls or connection.") }
                    completion?(false)
                case .cancelled: completion?(false)
                }
            }
        case .disabled: return false
        }
        return true
    }

    private func changeMute(_ muted: Bool, target: String, completion: ((Bool) -> Void)? = nil) {
        revision &+= 1
        let request = revision
        let epoch = interactionEpoch
        pendingAudio = (request, target)
        assign(\.isMuted, muted)
        let audio = audioController
        audio.requestMuted(muted, expectedTargetIdentifier: target) { [weak self] result in
            guard let self else { return }
            let latest = self.pendingAudio?.revision == request
            if latest { self.pendingAudio = nil; self.refreshAudio() }
            guard self.interactionEpoch == epoch else { completion?(false); return }
            switch result {
            case let .applied(value, actualMute, identifier):
                guard identifier == audio.targetIdentifier else { completion?(false); return }
                if latest { self.assign(\.message, nil) }
                NotificationCenter.default.post(name: .volumeChanged, object: actualMute ? Float(0) : value, userInfo: ["source": "control"])
                completion?(true)
            case .failed:
                if latest { self.assign(\.message, "This output did not accept the mute change.") }
                completion?(false)
            case .cancelled: completion?(false)
            }
        }
    }

    func toggleMute() {
        guard !preview, let target = audioController.targetIdentifier else { return }
        // Preserve the latest displayed intention even if a slow driver has
        // not acknowledged the preceding click or slider move yet.
        let restoreFromZero = volume <= 0.01
        let nextMute = !isMuted
        captureUndo(.volume)
        if restoreFromZero {
            adjust(.volume, to: max(0.1, lastAudibleVolume))
        } else if audioController.supportsMute {
            changeMute(nextMute, target: target)
        } else {
            adjust(.volume, to: 0)
        }
    }

    func undo() {
        guard !preview, let saved = undoValues else { return }
        let currentDevice = saved.action == .volume ? audioController.targetIdentifier : displayController.targetIdentifier
        guard currentDevice == saved.device else {
            assign(\.message, "The active device changed. Undo is no longer available.")
            undoValues = nil
            return
        }
        interactionEpoch &+= 1
        let epoch = interactionEpoch
        let restoreMute = saved.action == .volume && audioController.supportsMute ? saved.muted : nil
        adjust(saved.action, to: saved.value, restoringMute: restoreMute) { [weak self] success in
            guard let self, self.interactionEpoch == epoch, success else { return }
            self.undoValues = nil
        }
    }

    #if SWAY_CONTROL_TESTS
    var visibleRefreshActiveForTesting: Bool { visibleTimer != nil }
    #endif
}

// MARK: - Quick controls

/// The menu bar is for immediate adjustments. Configuration lives in a window.
struct MenuBarView: View {
    @ObservedObject private var settings: TrackpadSettings
    @ObservedObject private var session = SwaySession.shared
    @ObservedObject private var monitor = TrackpadMonitor.shared
    @ObservedObject private var telemetry = GestureTelemetry.shared
    @ObservedObject private var exclusions = ExcludedAppsManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @StateObject private var controls: ControlCenterModel
    @State private var showsMoreOptions = false
    private let preview: Bool
    private let previewStandaloneSurface: Bool
    private let previewReduceTransparency: Bool
    private let openSettings: () -> Void

    init(settings: TrackpadSettings = .shared, preview: Bool = false, previewStandaloneSurface: Bool = false, previewReduceTransparency: Bool = false, previewExpandedOptions: Bool = false, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.preview = preview
        self.previewStandaloneSurface = preview && previewStandaloneSurface
        self.previewReduceTransparency = preview && previewReduceTransparency
        self.openSettings = openSettings
        _showsMoreOptions = State(initialValue: preview && previewExpandedOptions)
        _controls = StateObject(wrappedValue: preview ? ControlCenterModel(settings: settings, preview: true) : .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Text("Sway").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Gestures").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Enable trackpad gestures", isOn: Binding(get: { settings.isEnabled }, set: {
                    if preview { settings.isEnabled = $0 } else { session.setEnabled($0) }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(settings.isEnabled ? "Pause edge gestures; sliders stay available" : "Resume edge gestures")
            }

            VStack(spacing: 14) {
                QuickLevelRow(action: .brightness,
                    value: Binding(get: { controls.brightness }, set: { controls.adjust(.brightness, to: $0) }),
                    available: controls.brightnessAvailable, device: controls.brightnessDevice,
                    bounds: settings.brightnessMin...max(settings.brightnessMin, settings.brightnessMax),
                    onBegin: { controls.captureUndo(.brightness) })
                QuickLevelRow(action: .volume,
                    value: Binding(get: { controls.volume }, set: { controls.adjust(.volume, to: $0) }),
                    available: controls.volumeAvailable, device: controls.volumeDevice,
                    bounds: settings.volumeMin...max(settings.volumeMin, settings.volumeMax),
                    muted: controls.isMuted,
                    muteAvailable: preview || settings.volumeMin == 0 || VolumeController.shared.supportsMute,
                    onBegin: { controls.captureUndo(.volume) }, onMute: { controls.toggleMute() })
            }

            if !controls.hasAccess {
                Button(action: openSettings) {
                    Label("Allow trackpad access…", systemImage: "lock.shield")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Open Settings to enable Accessibility access")
            } else if settings.isEnabled && !monitor.isRunning && !preview {
                HStack(alignment: .top, spacing: 8) {
                    Label(monitor.statusMessage, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Retry") { monitor.restart() }.controlSize(.small)
                }
            } else if telemetry.isTesting && !preview {
                Label("Testing · gestures won’t change levels", systemImage: "waveform.path")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let until = session.pauseUntil, !preview {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("Resumes in")
                    Text(until, style: .timer).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else if exclusions.activeAppIsExcluded && !preview {
                Text("Gestures paused in \(exclusions.currentAppName)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let message = controls.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updates.updateAvailable, let version = updates.latestVersion, !preview {
                Button { (NSApp.delegate as? AppDelegate)?.checkForUpdates() } label: {
                    Label("Sway \(version) available…", systemImage: "arrow.down.circle")
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Review and install the signed update")
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                if controls.undoValues != nil {
                    Button { controls.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo last adjustment").accessibilityLabel("Undo last adjustment")
                }
                MoreOptionsButton(isExpanded: showsMoreOptions) { showsMoreOptions.toggle() }
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            if showsMoreOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Button { if !preview { (NSApp.delegate as? AppDelegate)?.showQuickControls() } } label: {
                        Label("Open Controls…", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { if !preview { (NSApp.delegate as? AppDelegate)?.checkForUpdates() } } label: {
                        Label("Software Updates…", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } } label: {
                        Label("Getting Started…", systemImage: "questionmark.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text("Pause gestures").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([5, 15, 60], id: \.self) { minutes in
                            Button(minutes == 60 ? "1 hr" : "\(minutes) min") {
                                if !preview { session.pause(for: TimeInterval(minutes * 60)) }
                                showsMoreOptions = false
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Divider()
                    Button("Quit Sway") { if !preview { NSApp.terminate(nil) } }.keyboardShortcut("q")
                }.font(.system(size: 12)).buttonStyle(.plain)
            }
        }
        .padding(17)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuGlassSurface(standalone: previewStandaloneSurface, forceOpaque: previewReduceTransparency))
        .tint(.primary)
        .preferredColorScheme(settings.resolvedColorScheme)
    }
}

private struct QuickLevelRow: View {
    let action: ZoneAction
    @Binding var value: Double
    let available: Bool
    let device: String
    let bounds: ClosedRange<Double>
    var muted = false
    var muteAvailable = false
    let onBegin: () -> Void
    var onMute: (() -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                if let onMute {
                    Button(action: onMute) {
                        Image(systemName: muted || value <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain).disabled(!available || !muteAvailable)
                    .help(muted || value <= 0.01 ? "Restore audio" : "Mute audio")
                    .accessibilityLabel(muted || value <= 0.01 ? "Restore audio" : "Mute audio")
                } else {
                    Image(systemName: action.icon).frame(width: 18, height: 18)
                }
                Text(action.label).fontWeight(.medium)
                Spacer()
                Text(available ? (muted ? "Muted" : "\(Int((value * 100).rounded()))%") : "Unavailable")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            Slider(value: $value, in: bounds, onEditingChanged: { if $0 { onBegin() } })
                .controlSize(.small).disabled(!available)
                .accessibilityLabel(action.label)
                .accessibilityValue(available ? "\(Int(value * 100)) percent\(muted ? ", muted" : "")" : "Unavailable")
                .help(available ? device : "Use this device’s hardware controls")
        }
    }
}

private struct MenuGlassSurface: ViewModifier {
    var standalone = false
    var forceOpaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if !standalone {
            // NSPopover owns its native glass. Another material here would
            // flatten it and make the panel look opaque.
            content
        } else if reduceTransparency || forceOpaque {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(PopoverMaterial().clipShape(RoundedRectangle(cornerRadius: 12)))
        }
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Separate settings window

struct ContentView: View {
    @ObservedObject private var settings: TrackpadSettings
    @ObservedObject private var monitor = TrackpadMonitor.shared
    @ObservedObject private var telemetry = GestureTelemetry.shared
    @ObservedObject private var exclusions = ExcludedAppsManager.shared
    @ObservedObject private var login = LoginItemManager.shared
    @ObservedObject private var updates: UpdateChecker
    @StateObject private var controls: ControlCenterModel
    @State private var pane: SettingsPane
    @State private var search = ""
    @State private var showsSafeTest = false
    @State private var showAppPicker = false
    @State private var confirmReset = false
    @State private var presetMessage: String?
    @State private var selectedZone = "left"
    private let preview: Bool

    init(initialPane: SettingsPane = .gestures, preview: Bool = false, settings: TrackpadSettings = .shared, updates: UpdateChecker = .shared) {
        self.preview = preview
        self.settings = settings
        self.updates = updates
        _pane = State(initialValue: initialPane)
        _controls = StateObject(wrappedValue: preview ? ControlCenterModel(settings: settings, preview: true) : .shared)
    }

    private var visiblePanes: [SettingsPane] { SettingsPane.allCases.filter { $0.matches(search) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sway").font(.system(size: 20, weight: .semibold))
                TextField("Find a setting", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Find a setting")
                VStack(spacing: 4) {
                    ForEach(visiblePanes) { item in
                        Button { pane = item } label: {
                            Label(item.title, systemImage: item.icon)
                                .font(.system(size: 12, weight: pane == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 10)
                                .background(pane == item ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(pane == item ? [.isSelected] : [])
                    }
                }
                if visiblePanes.isEmpty { Text("No matching settings").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Button("Getting started…") { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(16).frame(width: 198)
            .background(Color.primary.opacity(0.025))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if visiblePanes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No settings found").font(.headline)
                        Text("Try a word like haptics, typing, or updates.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Clear search") { search = "" }.buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                PageTitle(pane.title, subtitle: pane.detail).padding(22)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !controls.hasAccess && [.gestures, .protection, .about].contains(pane) { permissionCard }
                        if controls.hasAccess && settings.isEnabled && !monitor.isRunning && !preview && pane == .gestures {
                            VStack(alignment: .leading, spacing: 10) {
                                Notice(monitor.statusMessage, icon: "exclamationmark.triangle", tint: .primary)
                                Button("Reconnect trackpad") { monitor.restart() }.buttonStyle(.bordered)
                            }
                        }
                        if let message = controls.message { Notice(message, icon: "exclamationmark.triangle", tint: .primary) }
                        switch pane {
                        case .gestures: gesturesPage
                        case .protection: protectionPage
                        case .levels: levelsPage
                        case .feedback: feedbackPage
                        case .appearance: appearancePage
                        case .general: generalPage
                        case .updates: SettingsSection("Updates") { UpdatePreferencesContent(updates: updates, preview: preview) }
                        case .about: aboutPage
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.id(pane)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 700, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.resolvedColorScheme)
        .tint(SwayTheme.accent)
        .onChange(of: pane) { value in if value != .protection { endTesting() } }
        .onChange(of: search) { _ in
            if !visiblePanes.contains(pane), let first = visiblePanes.first { pane = first }
            if visiblePanes.isEmpty { endTesting() }
        }
        .onChange(of: showsSafeTest) { if !$0 { endTesting() } }
        .onDisappear { endTesting() }
        .sheet(isPresented: $showAppPicker) { AppPickerSheet(excludedApps: $settings.excludedApps) }
        .alert("Reset gesture settings?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) { }
            Button("Reset gestures", role: .destructive) { settings.resetGestureSettings() }
        } message: { Text("Restores zone assignments, sensitivity, palm protection, haptics, and limits. Your excluded apps, shortcut, and appearance stay as they are.") }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Allow trackpad gestures", systemImage: "lock.shield")
                .font(.system(size: 15, weight: .semibold))
            Text("Enable Sway in System Settings → Privacy & Security → Accessibility. Menu-bar sliders work without this permission.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Accessibility Settings", action: openAccessibility).buttonStyle(.bordered)
                Button("Check again") { controls.refresh(); if controls.hasAccess { monitor.restart() } }.buttonStyle(.bordered)
            }
            .controlSize(.regular)
            AccessibilityRecoveryHelp()
        }
        .padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }


    private var gesturesPage: some View {
        Group {
            SettingsCard {
                SettingRow("Preset", detail: presetMessage ?? "Choose a starting point, then fine-tune.") {
                    Menu("Choose…") {
                        ForEach(GesturePreset.allCases) { preset in
                            Button(preset.title) {
                                settings.applyGesturePreset(preset)
                                presetMessage = "\(preset.title) applied."
                            }
                        }
                    }.frame(width: 145)
                }
                Divider()
                SettingRow("Finger count", detail: "Use the same number throughout a swipe.") {
                    Picker("Finger count", selection: $settings.minimumFingers) {
                        Text("1 finger").tag(1); Text("2 fingers").tag(2)
                    }.pickerStyle(.segmented).frame(width: 170)
                }
                .onChange(of: settings.minimumFingers) { value in if value != 1 { settings.topEdgeEnabled = false } }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trackpad edges").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Start inside an edge to adjust").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                TrackpadMap(settings: settings, selectedZone: selectedZone, telemetry: telemetry, showsTouches: false, onSelect: { selectedZone = $0 })
                    .frame(height: 108)
                SettingsCard {
                    ZoneEditor(title: "Left edge", action: $settings.leftZoneAction, width: $settings.leftZoneWidth, selected: selectedZone == "left")
                    Divider()
                    ZoneEditor(title: "Right edge", action: $settings.rightZoneAction, width: $settings.rightZoneWidth, selected: selectedZone == "right")
                }
            }
            SettingsCard {
                LabeledSlider("Sensitivity", detail: "How quickly a swipe changes the level.", value: $settings.sensitivity, range: 0.3...3, display: String(format: "%.1f×", settings.sensitivity))
                Divider()
                ToggleRow("Reverse swipe direction", detail: settings.invertScrollDirection ? "Down increases. Up decreases." : "Up increases. Down decreases.", value: $settings.invertScrollDirection)
                Divider()
                ToggleRow("Hold pointer while adjusting", detail: "Only during a confirmed one-finger gesture.", value: $settings.cursorFreezeOnOneFinger)
                    .disabled(settings.minimumFingers != 1)
            }
            SettingsCard {
                ToggleRow("Top edge gestures", detail: "One finger; side edges remain available.", value: Binding(get: { settings.topEdgeEnabled }, set: { value in if value { settings.minimumFingers = 1 }; settings.topEdgeEnabled = value }))
                if settings.topEdgeEnabled {
                    Divider()
                    SettingRow("Swipe direction") {
                        Picker("Top swipe direction", selection: $settings.topEdgeSwipeDirection) {
                            Text("Horizontal").tag("horizontal"); Text("Vertical").tag("vertical")
                        }.pickerStyle(.segmented).frame(width: 210)
                    }
                    if settings.topEdgeSwipeDirection == "horizontal" {
                        SettingRow("Top left") { ActionPicker(action: $settings.topLeftAction, label: "Top left action") }
                        SettingRow("Top right") { ActionPicker(action: $settings.topRightAction, label: "Top right action") }
                    } else {
                        SettingRow("Top edge action") { ActionPicker(action: $settings.topEdgeAction, label: "Top edge action") }
                    }
                    EdgeWidthSlider(title: "Top height", value: $settings.topEdgeHeight, range: TrackpadSettings.topEdgeHeightRange)
                        .padding(14)
                }
            }
        }
    }

    private var protectionPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard {
                    SettingRow("Intent checks", detail: settings.palmRejectionMode == "strict" ? "More travel and consistency before activation." : "Balanced response with deliberate movement.") {
                        Picker("Palm protection", selection: $settings.palmRejectionMode) {
                            Text("Balanced").tag("balanced"); Text("Strict").tag("strict")
                        }.pickerStyle(.segmented).frame(width: 170)
                    }
                    DisclosureGroup("Fine-tune protection") {
                        LabeledSlider("Pause after typing", detail: "Prevents a resting hand from starting a gesture after a keypress.", value: $settings.typingCooldown, range: 0.2...1, display: String(format: "%.2f s", settings.typingCooldown))
                        LabeledSlider("Start distance", detail: "Minimum travel across the trackpad before a swipe can activate.", value: $settings.activationThreshold, range: 0...12, display: String(format: "%.1f%%", max(settings.palmRejectionMode == "strict" ? 1.4 : 0.8, settings.activationThreshold / 5 * (settings.palmRejectionMode == "strict" ? 1.3 : 1))))
                    }.font(.system(size: 12)).padding(14)
                }
                Text("These are measured intent checks, not a claim that macOS identifies every palm. Straightness is net travel divided by total travel. No touch data is saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Test gestures safely", isExpanded: $showsSafeTest) {
                VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "testtube.2").font(.system(size: 24)).foregroundStyle(SwayTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(telemetry.isTesting ? "Test running" : "Safe test")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Volume, brightness, and pointer stay unchanged.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(telemetry.isTesting ? "Stop test" : "Start test") {
                    guard !preview else { return }
                    if telemetry.isTesting { endTesting() }
                    else { monitor.cancelCurrentGesture(); telemetry.resetCounters(); telemetry.isTesting = true; monitor.start() }
                }
                .buttonStyle(.bordered)
                .disabled(!controls.hasAccess || !settings.isEnabled)
            }.swayCard()
            if !settings.isEnabled {
                HStack {
                    Text("Gestures are paused.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { if !preview { SwaySession.shared.setEnabled(true) } }.buttonStyle(.bordered)
                }
            }
            TrackpadMap(settings: settings, selectedZone: nil, telemetry: telemetry, showsTouches: telemetry.isTesting, onSelect: nil)
                .frame(height: 145)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(telemetry.isTesting ? telemetry.phase : "Ready to test", systemImage: telemetry.phase == "Accepted" && telemetry.isTesting ? "checkmark.circle.fill" : "waveform.path")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(SwayTheme.accent)
                    Spacer()
                    Text("\(telemetry.acceptedCount) accepted · \(telemetry.rejectedCount) stopped")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(telemetry.isTesting ? telemetry.reason : "Start a test, then begin a deliberate swipe inside an edge zone.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    EvidenceMetric(label: "Contacts", value: "\(telemetry.fingerCount)")
                    EvidenceMetric(label: "Travel", value: String(format: "%.1f%%", telemetry.displacement * 100))
                    EvidenceMetric(label: "Straightness", value: telemetry.sampleCount > 1 ? "\(Int(telemetry.straightness * 100))%" : "—")
                    EvidenceMetric(label: "Duration", value: "\(telemetry.elapsedMilliseconds) ms")
                }
            }.swayCard()
                }.padding(.top, 14)
            }.font(.system(size: 13, weight: .medium))
        }
    }

    private var levelsPage: some View {
        SettingsSection("Comfort limits") {
            LimitEditor(action: .brightness, lower: $settings.brightnessMin, upper: $settings.brightnessMax)
            Divider()
            LimitEditor(action: .volume, lower: $settings.volumeMin, upper: $settings.volumeMax)
            Divider()
            ToggleRow("Mute at zero", detail: "Mute audio when the volume reaches 0%.", value: $settings.muteAtZero)
        }
    }

    private var feedbackPage: some View {
        SettingsSection("Trackpad haptics") {
            ToggleRow("Haptic feedback", detail: "Feel confirmed edge gestures and level changes.", value: $settings.hapticFeedback)
            if settings.hapticFeedback {
                Divider()
                SettingRow("Tap style") {
                    Picker("Haptic tap style", selection: $settings.hapticStyle) {
                        ForEach(HapticStyle.allCases) { style in Text(style.label).tag(style) }
                    }.pickerStyle(.segmented).frame(width: 230)
                }
                Divider()
                SettingRow("Level steps", detail: "Smaller steps give more taps.") {
                    Picker("Haptic level spacing", selection: $settings.hapticSpacing) {
                        ForEach(HapticSpacing.allCases) { spacing in Text(spacing.label).tag(spacing) }
                    }.pickerStyle(.segmented).frame(width: 165)
                }
                Divider()
                ToggleRow("Tap at gesture start", detail: "Know when Sway accepts your swipe.", value: $settings.hapticOnStart)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button("Try this tap") {
                        if !preview, !telemetry.isTesting { HapticOutput.shared.play(settings.hapticStyle) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(telemetry.isTesting)
                    .help("Click while keeping a finger on your Force Touch trackpad.")
                    Text(telemetry.isTesting ? "Stop the gesture test to preview haptics." : "Keep a finger resting on your Force Touch trackpad. These are tap patterns; macOS controls the strength and may suppress feedback.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(14)
            }
        }
    }

    private var appearancePage: some View {
        SettingsSection("Appearance") {
            SettingRow("On-screen indicator") {
                Picker("Indicator style", selection: $settings.osdStyle) {
                    Text("Pill").tag("horizontal"); Text("Vertical").tag("vertical"); Text("Off").tag("off")
                }.pickerStyle(.segmented).frame(width: 200)
            }
            if settings.osdStyle == "horizontal" {
                LabeledSlider("Indicator width", detail: "Shown at the bottom of the active display.", value: $settings.osdHorizontalWidth, range: 160...320, display: "\(Int(settings.osdHorizontalWidth)) pt")
            } else if settings.osdStyle == "vertical" {
                SettingRow("Position") {
                    Picker("Indicator position", selection: $settings.osdPosition) {
                        ForEach(OSDPosition.allCases) { item in Text(item.label).tag(item) }
                    }.frame(width: 140)
                }
            }
            if settings.osdStyle != "off" {
                Button("Preview indicator") { if !preview { OSDOverlay.shared.show(type: .volume, value: Float(controls.volume)) } }
                    .buttonStyle(.bordered).padding([.horizontal, .bottom], 14)
            }
            Divider()
            SettingRow("Theme") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.pickerStyle(.segmented).frame(width: 200)
            }
            Divider()
            SettingRow("Menu bar") {
                Picker("Menu bar display", selection: $settings.menuBarValueSource) {
                    Text("Sway icon").tag("icon"); Text("Sway name").tag("name"); Text("Volume").tag("volume"); Text("Brightness").tag("brightness"); Text("Both levels").tag("both")
                }.frame(width: 150)
            }
        }
    }

    private var generalPage: some View {
        SettingsSection("Stay out of the way") {
            ToggleRow("Show in Dock while windows are open", detail: "Close the last window to hide the Dock icon. Sway keeps running in the menu bar.", value: $settings.showDockIcon)
            Divider()
            HStack {
                Text("You can also reopen Sway from Spotlight or Applications.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open controls") { if !preview { (NSApp.delegate as? AppDelegate)?.showQuickControls() } }
                    .buttonStyle(.bordered)
            }.padding(14)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded apps").font(.system(size: 14, weight: .medium))
                    Text(settings.excludedApps.isEmpty ? "Gestures work in every app." : "\(settings.excludedApps.count) apps pause gestures automatically.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage…") { showAppPicker = true }.buttonStyle(.bordered)
            }.padding(14)
            if let id = exclusions.currentAppBundleID, !preview, !settings.excludedApps.contains(id) {
                Button("Exclude \(exclusions.currentAppName)") {
                    settings.excludedApps.append(id)
                }.buttonStyle(.plain).foregroundStyle(SwayTheme.accent).font(.system(size: 12)).padding([.horizontal, .bottom], 14)
            }
            Divider()
            HotkeyRecorder(hotkey: $settings.toggleHotkey)
            Divider()
            ToggleRow("Launch at login", detail: "Have Sway ready when you sign in.", value: $settings.launchAtLogin)
            if login.lastError != nil || login.status == .requiresApproval || login.status == .notFound {
                Text(login.statusMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding([.horizontal, .bottom], 14)
            }
        }
    }

    private var aboutPage: some View {
        SettingsSection("About Sway") {
            HStack {
                Text("Sway").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting started").font(.system(size: 14))
                    Text("Find Sway and set up trackpad access.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open guide…") { if !preview { (NSApp.delegate as? AppDelegate)?.showGettingStarted() } }
                    .buttonStyle(.bordered)
            }.padding(14)
            Divider()
            HStack {
                Text("Gesture setup").font(.system(size: 14))
                Spacer()
                Button("Reset…") { confirmReset = true }.buttonStyle(.bordered)
            }.padding(14)
        }
    }

    private func endTesting() {
        guard !preview, telemetry.isTesting else { return }
        monitor.cancelCurrentGesture()
        telemetry.isTesting = false
    }

    private func openAccessibility() {
        guard !preview else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

}

/// Shared update controls for General settings and the focused update window.
struct UpdatePreferencesContent: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var installer = InAppUpdater.shared
    var preview = false
    var previewUpdateAvailable = false
    private var showsPreviewUpdate: Bool { preview && previewUpdateAvailable }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow("Check automatically", detail: "Check GitHub daily. Downloads stay in your control.",
                      value: Binding(get: { updates.automaticallyChecks }, set: { if !preview { updates.automaticallyChecks = $0 } }))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(showsPreviewUpdate ? "A new version of Sway is available." : updates.status).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Update status: \(updates.status)")
                if let checked = updates.lastChecked {
                    Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if showsPreviewUpdate || (updates.updateAvailable && installer.isConfigured) {
                    SystemActionButton(title: installer.isBusy ? "Update in progress…" : "Install update…", isEnabled: !installer.isBusy) {
                        if !preview { installer.installUpdate() }
                    }.fixedSize()
                }
                HStack {
                    SystemActionButton(title: updates.isChecking ? "Checking…" : "Check now", isEnabled: !updates.isChecking) {
                        if !preview { updates.check() }
                    }.fixedSize()
                    SystemActionButton(title: updates.updateAvailable ? "View update…" : "GitHub Releases…") {
                        if !preview { updates.openReleasePage() }
                    }.fixedSize()
                }
                if let error = installer.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Install updates here without dragging a new app. Downloads and release information are verified before installation. Sway restarts when you confirm.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
        }
    }
}

struct UpdateWindowView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var settings: TrackpadSettings = .shared
    var preview = false
    var previewUpdateAvailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Software updates", systemImage: "arrow.down.circle")
                .font(.system(size: 21, weight: .semibold))
            UpdatePreferencesContent(updates: updates, preview: preview, previewUpdateAvailable: previewUpdateAvailable)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.padding(24).frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor)).tint(.primary)
            .preferredColorScheme(settings.resolvedColorScheme)
    }
}

/// First launch is a real, focused window, not a hidden menu-bar popover.
private struct AccessibilityRecoveryHelp: View {
    var body: some View {
        DisclosureGroup("Already enabled, but gestures don’t work?") {
            Text("Upgrading from 1.0.10 or earlier may need one final permission grant. In Accessibility, remove the old Sway entry with −, then use + to add Sway from Applications and enable it. Return here and choose Check again. If macOS still reports the old state, quit and reopen Sway once. Your other apps’ permissions stay untouched.")
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

struct GettingStartedView: View {
    @ObservedObject var settings: TrackpadSettings
    @StateObject private var controls: ControlCenterModel
    private let preview: Bool
    let openControls: () -> Void

    init(settings: TrackpadSettings = .shared, preview: Bool = false, hasAccess: Bool? = nil, openControls: @escaping () -> Void) {
        self.settings = settings
        self.preview = preview
        self.openControls = openControls
        let controls = preview ? ControlCenterModel(settings: settings, preview: true) : .shared
        if preview, let hasAccess { controls.hasAccess = hasAccess }
        _controls = StateObject(wrappedValue: controls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.path").font(.system(size: 34, weight: .medium))
                    .frame(width: 58, height: 58).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meet Sway").font(.system(size: 25, weight: .semibold))
                    Text("A lighter touch for your Mac.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text("Your menu bar").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "waveform.path").font(.system(size: 18, weight: .semibold))
                        .padding(8).background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("Sway menu bar icon")
                    Image(systemName: "wifi").foregroundStyle(.secondary)
                    Text("9:41").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                Text("Sway lives at the top of your screen. Click this waveform for volume and brightness.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Button("Show menu bar controls") {
                    if !preview { (NSApp.delegate as? AppDelegate)?.revealMenuBar() }
                }.buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(controls.hasAccess ? "Trackpad access is ready" : "Allow trackpad gestures",
                      systemImage: controls.hasAccess ? "checkmark.circle" : "hand.draw")
                    .font(.system(size: 14, weight: .semibold))
                Text("Accessibility lets Sway recognize edge swipes and keep them from scrolling. Touch data stays on your Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !controls.hasAccess {
                    HStack {
                        Button("Open Accessibility Settings…") {
                            guard !preview else { return }
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        Button("Check again") { controls.refresh() }
                    }.buttonStyle(.bordered)
                    AccessibilityRecoveryHelp()
                    Text("Use the sliders for now. This guide returns next time you open Sway until trackpad access is ready.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show in Dock while windows are open", isOn: $settings.showDockIcon).toggleStyle(.switch).controlSize(.small)
                Text("Close the last window to hide the Dock icon; Sway stays in your menu bar. Reopen it from Spotlight or Applications whenever you need controls.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .center, spacing: 16) {
                Text("Checks GitHub for updates daily.\nChange this in Software updates.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(controls.hasAccess ? "Get started" : "Continue with sliders", action: openControls)
                    .buttonStyle(MonochromePrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(settings.resolvedColorScheme)
        .tint(.primary)
    }
}


// Geometry describes real physical zones. Text stays outside narrow strips.
private struct TrackpadMap: View {
    @ObservedObject var settings: TrackpadSettings
    let selectedZone: String?
    @ObservedObject var telemetry: GestureTelemetry
    let showsTouches: Bool
    let onSelect: ((String) -> Void)?
    @State private var trail: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let topHeight = settings.topEdgeEnabled ? height * settings.topEdgeHeight : 0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 17).fill(SwayTheme.canvas)
                RoundedRectangle(cornerRadius: 17).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                zone("left", action: settings.leftZoneAction, width: width * settings.leftZoneWidth, height: height - topHeight)
                    .offset(y: topHeight)
                zone("right", action: settings.rightZoneAction, width: width * settings.rightZoneWidth, height: height - topHeight)
                    .offset(x: width * (1 - settings.rightZoneWidth), y: topHeight)
                if settings.topEdgeEnabled {
                    if settings.topEdgeSwipeDirection == "horizontal" {
                        zone("topLeft", action: settings.topLeftAction, width: width / 2, height: topHeight)
                        zone("topRight", action: settings.topRightAction, width: width / 2, height: topHeight).offset(x: width / 2)
                    } else {
                        zone("top", action: settings.topEdgeAction, width: width, height: topHeight)
                    }
                }
                VStack(spacing: 6) {
                    Image(systemName: showsTouches ? "waveform.path" : "cursorarrow")
                        .font(.system(size: 16, weight: .light)).foregroundStyle(.secondary)
                    Text(showsTouches ? "Live touch view" : "Free space")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    if !showsTouches { Text("Point & scroll").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                .frame(width: width * max(0.12, 1 - settings.leftZoneWidth - settings.rightZoneWidth), height: height - topHeight)
                .offset(x: width * settings.leftZoneWidth, y: topHeight)
                .allowsHitTesting(false)
                if showsTouches {
                    Path { path in
                        for (index, point) in trail.enumerated() {
                            let position = CGPoint(x: point.x * width, y: (1 - point.y) * height)
                            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                    }
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    if telemetry.fingerCount > 0 {
                        Circle().fill(Color.primary).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .position(x: telemetry.x * width, y: (1 - telemetry.y) * height)
                            .allowsHitTesting(false)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .onChange(of: telemetry.sampleCount) { count in
            guard showsTouches else { return }
            if count <= 1 { trail.removeAll(keepingCapacity: true) }
            if telemetry.fingerCount > 0 {
                trail.append(CGPoint(x: telemetry.x, y: telemetry.y))
                if trail.count > 80 { trail.removeFirst(trail.count - 80) }
            }
        }
        .onChange(of: showsTouches) { _ in trail.removeAll() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trackpad gesture map")
    }

    private func zone(_ key: String, action: ZoneAction, width: CGFloat, height: CGFloat) -> some View {
        let selected = selectedZone == key || (showsTouches && telemetry.activeZone == key)
        let isTop = key.hasPrefix("top")
        return Button { onSelect?(key) } label: {
            ZStack {
                Rectangle().fill(Color.primary.opacity(action == .disabled ? 0.025 : selected ? 0.16 : 0.075))
                Rectangle().strokeBorder(Color.primary.opacity(selected ? 0.6 : 0.2), lineWidth: selected ? 1.5 : 0.5)
                if width >= 38 && height >= 28 {
                    if isTop {
                        Image(systemName: settings.topEdgeSwipeDirection == "horizontal" ? "arrow.left.and.right" : "arrow.up.and.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: action.icon).font(.system(size: 15))
                            Image(systemName: "arrow.up.and.down").font(.system(size: 12, weight: .medium))
                        }.foregroundStyle(Color.primary.opacity(action == .disabled ? 0.35 : 0.85))
                    }
                }
            }.frame(width: max(0, width), height: max(0, height))
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
        .accessibilityLabel("\(key == "left" ? "Left edge" : key == "right" ? "Right edge" : "Top edge"): \(action.label)")
        .help("\(action.label) · click to configure")
    }
}

// MARK: - Consistent settings primitives

private struct PageTitle: View {
    let title: String
    let subtitle: String
    init(_ title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(15)
            .background(scheme == .dark ? Color.white.opacity(0.045) : Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private extension View { func swayCard() -> some View { modifier(CardModifier()) } }


private struct Notice: View {
    let text: String
    let icon: String
    let tint: Color
    init(_ text: String, icon: String, tint: Color) { self.text = text; self.icon = icon; self.tint = tint }
    var body: some View {
        Label { Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity)
            .background(scheme == .dark ? Color.white.opacity(0.045) : .white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            SettingsCard(content: content)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control
    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) { self.title = title; self.detail = detail; self.control = control }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                control().labelsHidden()
            }
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(14)
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var value: Bool
    init(_ title: String, detail: String, value: Binding<Bool>) { self.title = title; self.detail = detail; _value = value }
    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.switch).controlSize(.small).padding(14)
    }
}

private struct LabeledSlider: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    init(_ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) {
        self.title = title; self.detail = detail; _value = value; self.range = range; self.display = display
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Text(display).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(SwayTheme.accent)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(display)
        }.padding(14)
    }
}

private struct ActionPicker: View {
    @Binding var action: ZoneAction
    let label: String
    var body: some View {
        Picker(label, selection: $action) {
            ForEach(ZoneAction.allCases) { item in Label(item.label, systemImage: item.icon).tag(item) }
        }.frame(width: 145)
    }
}

private struct ZoneEditor: View {
    let title: String
    @Binding var action: ZoneAction
    @Binding var width: Double
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: action.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(action.tint)
                Spacer()
                ActionPicker(action: $action, label: "\(title) action").labelsHidden()
            }
            EdgeWidthSlider(title: "\(title) width", value: $width, range: TrackpadSettings.sideZoneWidthRange)
        }.padding(14).background(selected ? action.tint.opacity(0.045) : .clear)
    }
}

private struct EdgeWidthSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    private var percent: Binding<Double> {
        Binding(get: { value * 100 }, set: { entered in
            guard entered.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, entered / 100))
        })
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(title == "Top height" ? "Height" : "Width").font(.system(size: 12)).foregroundStyle(.secondary)
            // Snap to half-percent changes without drawing dozens of tick marks.
            // The text field still accepts finer values such as 1.2%.
            Slider(value: Binding(get: { value }, set: {
                value = min(range.upperBound, max(range.lowerBound, ($0 * 200).rounded() / 200))
            }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(value * 100, specifier: "%.1f") percent")
            HStack(spacing: 3) {
                TextField(title, value: percent, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .frame(width: 43).accessibilityLabel("Exact \(title.lowercased()) in percent")
                Text("%").foregroundStyle(.secondary)
            }.font(.system(size: 12)).monospacedDigit()
        }
        .help("\(Int(range.lowerBound * 100))–\(Int(range.upperBound * 100))%. Type an exact value, including decimals.")
    }
}

private struct LimitEditor: View {
    let action: ZoneAction
    @Binding var lower: Double
    @Binding var upper: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(action.label, systemImage: action.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(action.tint)
                Spacer()
                Text("\(Int(lower * 100))–\(Int(upper * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            HStack {
                Text("Min").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { lower }, set: { lower = min($0, upper - 0.05) }), in: 0...0.95, step: 0.01).accessibilityLabel("Minimum \(action.label)")
            }
            HStack {
                Text("Max").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { upper }, set: { upper = max($0, lower + 0.05) }), in: 0.05...1, step: 0.01).accessibilityLabel("Maximum \(action.label)")
            }
        }.padding(14).tint(action.tint)
    }
}

private struct EvidenceMetric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shortcuts and app exclusions

private struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyCombo
    @ObservedObject private var manager = HotkeyManager.shared
    @State private var recording = false
    @State private var eventMonitor: Any?
    @State private var hint: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pause / resume shortcut").font(.system(size: 14, weight: .medium))
                    Text(recording ? "Press a shortcut. Escape cancels." : "Works while any app is active.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(recording ? "Cancel" : hotkey.isEmpty ? "Record…" : hotkey.displayString) {
                    recording ? stop() : start()
                }.buttonStyle(.bordered)
                if !recording && !hotkey.isEmpty {
                    Button { hotkey = .none } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear shortcut")
                }
            }
            if let message = hint ?? manager.registrationError {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).onDisappear(perform: stop)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("swayPopoverClosed"))) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("swaySettingsClosed"))) { _ in stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }
    private func start() {
        stop(); recording = true; hint = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !flags.intersection([.command, .control, .option]).isEmpty else {
                hint = "Include Command, Control, or Option."; return nil
            }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            hotkey = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop(); return nil
        }
    }
    private func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil; recording = false
    }
}

struct AppPickerSheet: View {
    @Binding var excludedApps: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppInfo] = []
    @State private var search = ""
    @State private var loading = true
    private var filtered: [AppInfo] {
        let matching = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
        return matching.sorted { a, b in
            let ae = excludedApps.contains(a.bundleID), be = excludedApps.contains(b.bundleID)
            return ae != be ? ae : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Excluded apps").font(.system(size: 21, weight: .semibold))
                    Text("Sway pauses gestures whenever these apps are active.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.defaultAction)
            }
            TextField("Search applications", text: $search).textFieldStyle(.roundedBorder).controlSize(.large)
            if loading {
                ProgressView("Finding applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No applications found").font(.system(size: 15, weight: .semibold))
                    Text("Try another name or add an app below.").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { app in
                            Toggle(isOn: Binding(get: { excludedApps.contains(app.bundleID) }, set: { enabled in
                                if enabled { if !excludedApps.contains(app.bundleID) { excludedApps.append(app.bundleID) } }
                                else { excludedApps.removeAll { $0 == app.bundleID } }
                            })) {
                                HStack(spacing: 10) {
                                    Image(nsImage: app.icon).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.system(size: 14, weight: .medium))
                                        Text(app.bundleID).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }.toggleStyle(.switch).controlSize(.small).padding(10)
                        }
                    }
                }
            }
            HStack {
                Button("Add application…", action: addApplication).buttonStyle(.bordered)
                Spacer()
                Text("\(excludedApps.count) excluded").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 520, height: 540)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let discovered = ExcludedAppsManager.installedApps()
                DispatchQueue.main.async {
                    apps = discovered
                    for id in excludedApps where !apps.contains(where: { $0.bundleID == id }) {
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        let name = url?.deletingPathExtension().lastPathComponent ?? id
                        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
                        apps.append(AppInfo(name: name, bundleID: id, icon: icon))
                    }
                    loading = false
                }
            }
        }
    }
    private func addApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                if !excludedApps.contains(id) { excludedApps.append(id) }
                if !apps.contains(where: { $0.bundleID == id }) {
                    apps.append(AppInfo(name: url.deletingPathExtension().lastPathComponent, bundleID: id, icon: NSWorkspace.shared.icon(forFile: url.path)))
                }
            }
        }
    }
}
