import Foundation
import Combine
import Carbon
import SwiftUI

// MARK: - Zone Action
enum ZoneAction: String, CaseIterable, Identifiable {
    case brightness = "brightness"
    case volume     = "volume"
    case microphoneLevel, keyboardBrightness, outputMute, microphoneMute
    case mediaTracks, playPause, tabs, history, zoom, pages, documentEnds
    case workspaces, missionControl, appWindows, showDesktop, switchApps, cycleWindows
    case fullScreen, minimizeWindow, hideApp, spotlight, screenshotTools, emojiPicker
    case customShortcut
    case disabled   = "disabled"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brightness: return "Brightness"
        case .volume:     return "Volume"
        case .microphoneLevel: return "Microphone level"
        case .keyboardBrightness: return "Keyboard backlight"
        case .outputMute: return "Speaker mute"
        case .microphoneMute: return "Microphone mute"
        case .mediaTracks: return "Previous / next track"
        case .playPause: return "Play / pause"
        case .tabs: return "Switch tabs"
        case .history: return "Back / forward"
        case .zoom: return "App zoom"
        case .pages: return "Page up / down"
        case .documentEnds: return "Document start / end"
        case .workspaces: return "Switch desktops"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App Exposé"
        case .showDesktop: return "Show desktop"
        case .switchApps: return "Switch apps"
        case .cycleWindows: return "Cycle app windows"
        case .fullScreen: return "Toggle full screen"
        case .minimizeWindow: return "Minimize window"
        case .hideApp: return "Hide current app"
        case .spotlight: return "Spotlight"
        case .screenshotTools: return "Screenshot tools"
        case .emojiPicker: return "Emoji & symbols"
        case .customShortcut: return "Custom shortcuts"
        case .disabled:   return "Off"
        }
    }

    var icon: String {
        switch self {
        case .brightness: return "sun.max.fill"
        case .volume:     return "speaker.wave.2.fill"
        case .microphoneLevel: return "mic.fill"
        case .keyboardBrightness: return "light.max"
        case .outputMute: return "speaker.slash.fill"
        case .microphoneMute: return "mic.slash.fill"
        case .mediaTracks: return "forward.end.fill"
        case .playPause: return "playpause.fill"
        case .tabs: return "rectangle.on.rectangle"
        case .history: return "arrow.left.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        case .pages: return "doc.text"
        case .documentEnds: return "arrow.up.to.line"
        case .workspaces: return "rectangle.split.3x1"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .showDesktop: return "menubar.dock.rectangle"
        case .switchApps: return "app.stack"
        case .cycleWindows: return "macwindow"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .minimizeWindow: return "minus.rectangle"
        case .hideApp: return "eye.slash"
        case .spotlight: return "magnifyingglass"
        case .screenshotTools: return "camera.viewfinder"
        case .emojiPicker: return "face.smiling"
        case .customShortcut: return "keyboard"
        case .disabled:   return "slash.circle"
        }
    }

    var category: String {
        switch self {
        case .brightness, .keyboardBrightness: return "Display & keyboard"
        case .volume, .microphoneLevel, .outputMute, .microphoneMute: return "Audio & microphone"
        case .mediaTracks, .playPause: return "Media"
        case .tabs, .history, .zoom, .pages, .documentEnds: return "Navigation"
        case .workspaces, .missionControl, .appWindows, .showDesktop, .switchApps, .cycleWindows,
             .fullScreen, .minimizeWindow, .hideApp: return "Windows & desktops"
        case .spotlight, .screenshotTools, .emojiPicker, .customShortcut: return "Tools & shortcuts"
        case .disabled: return "Other"
        }
    }
    static let categories = ["Display & keyboard", "Audio & microphone", "Media", "Navigation", "Windows & desktops", "Tools & shortcuts", "Other"]
    var isContinuous: Bool { self == .brightness || self == .volume || self == .microphoneLevel }
    var repeatsWhileSwiping: Bool { [.keyboardBrightness, .tabs, .zoom, .pages, .cycleWindows].contains(self) }
    var guidance: String {
        switch self {
        case .brightness: return "Up brightens; down dims the built-in display."
        case .volume: return "Up raises; down lowers the default audio output."
        case .microphoneLevel: return "Up raises; down lowers the default input’s gain. Does not record audio or change a meeting app’s mute button."
        case .keyboardBrightness: return "Up brightens; down dims a supported backlit keyboard using macOS media keys. Ambient light can limit changes."
        case .outputMute: return "Up unmutes; down mutes the default output. Requires a hardware mute control."
        case .microphoneMute: return "Up unmutes; down mutes the default input device, only when hardware mute is available. Other inputs and app mute buttons are separate."
        case .mediaTracks: return "Up sends next track; down sends previous track. One request per swipe to the active media app."
        case .playPause: return "Either direction sends play/pause to the active media app. Once per swipe."
        case .tabs: return "Up selects the next tab; down selects the previous tab. Uses Control-Tab in apps that support it."
        case .history: return "Up goes forward; down goes back. Uses Command-] / Command-[ in supporting apps."
        case .zoom: return "Up zooms in; down zooms out. Uses Command-+ / Command-− in supporting apps; not macOS accessibility zoom."
        case .pages: return "Up sends Page Up; down sends Page Down to the current app."
        case .documentEnds: return "Up goes to the start; down goes to the end. Uses Command-Up / Command-Down."
        case .workspaces: return "Up moves to the next desktop; down to the previous. Requires macOS Control-Arrow shortcuts."
        case .missionControl: return "Either direction opens Mission Control using Control-Up. Once per swipe."
        case .appWindows: return "Either direction shows the current app’s windows using Control-Down."
        case .showDesktop: return "Either direction sends F11 (Show Desktop). Requires this macOS shortcut to be enabled."
        case .switchApps: return "Up switches to the next recent app; down switches in reverse. One switch per swipe."
        case .cycleWindows: return "Up cycles forward through the current app’s windows; down cycles backward. Uses Command-`."
        case .fullScreen: return "Either direction sends Control-Command-F to toggle the current window’s full screen."
        case .minimizeWindow: return "Either direction sends Command-M to minimize the current window. Once per swipe."
        case .hideApp: return "Either direction sends Command-H to hide the current app. Once per swipe."
        case .spotlight: return "Either direction sends Command-Space. Requires the standard Spotlight shortcut."
        case .screenshotTools: return "Either direction opens the macOS screenshot toolbar (Command-Shift-5). You choose what to capture; Sway records nothing."
        case .emojiPicker: return "Either direction opens Emoji & Symbols using Control-Command-Space."
        case .customShortcut: return "Record an up/right and down/left shortcut below. Each runs once per swipe, in the app where the gesture started."
        case .disabled: return "This edge behaves like the rest of your trackpad."
        }
    }
}

// MARK: - OSD Position
enum OSDPosition: String, CaseIterable, Identifiable {
    case left   = "left"
    case center = "center"
    case right  = "right"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left:   return "Left"
        case .center: return "Center"
        case .right:  return "Right"
        }
    }

    var icon: String {
        switch self {
        case .left:   return "align.horizontal.left"
        case .center: return "align.horizontal.center"
        case .right:  return "align.horizontal.right"
        }
    }
}

// MARK: - Hotkey
struct HotkeyCombo: Codable, Equatable {
    var keyCode:   UInt32
    var modifiers: UInt32  // Carbon modifier flags

    static let none = HotkeyCombo(keyCode: 0, modifiers: 0)
    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    var displayString: String {
        guard !isEmpty else { return "None" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    private func keyName(for code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X",
            8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R",
            16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6",
            23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0",
            30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 37:"L",
            38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/",
            45:"N", 46:"M", 47:".", 49:"Space", 51:"⌫",
            53:"Esc", 96:"F5", 97:"F6", 98:"F7", 99:"F3",
            100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12",
            122:"F1", 120:"F2", 118:"F4",
        ]
        return map[code] ?? "(\(code))"
    }
}

// MARK: - Settings
class TrackpadSettings: ObservableObject {
    static let shared = TrackpadSettings()
    /// Normalized geometry retains fractional percentages; a 1% strip is valid.
    static let sideZoneWidthRange = 0.01...0.4
    static let topEdgeHeightRange = 0.01...0.3
    private let defaults: UserDefaults
    private var reconcilingLoginStatus = false

    @Published var leftZoneWidth: Double {
        didSet { defaults.set(leftZoneWidth, forKey: "leftZoneWidth") }
    }
    @Published var rightZoneWidth: Double {
        didSet { defaults.set(rightZoneWidth, forKey: "rightZoneWidth") }
    }
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var hapticStyle: HapticStyle {
        didSet { defaults.set(hapticStyle.rawValue, forKey: "hapticStyle") }
    }
    @Published var hapticSpacing: HapticSpacing {
        didSet { defaults.set(hapticSpacing.rawValue, forKey: "hapticSpacing") }
    }
    @Published var hapticOnStart: Bool {
        didSet { defaults.set(hapticOnStart, forKey: "hapticOnStart") }
    }
    var hapticConfiguration: HapticConfiguration {
        HapticConfiguration(enabled: hapticFeedback, style: hapticStyle,
                            spacing: hapticSpacing, onStart: hapticOnStart)
    }
    @Published var invertScrollDirection: Bool {
        didSet { defaults.set(invertScrollDirection, forKey: "invertScrollDirection") }
    }
    @Published var leftZoneAction: ZoneAction {
        didSet { defaults.set(leftZoneAction.rawValue, forKey: "leftZoneAction") }
    }
    @Published var rightZoneAction: ZoneAction {
        didSet { defaults.set(rightZoneAction.rawValue, forKey: "rightZoneAction") }
    }
    @Published var swipeUpShortcut: HotkeyCombo {
        didSet { if let data = try? JSONEncoder().encode(swipeUpShortcut) { defaults.set(data, forKey: "swipeUpShortcut") } }
    }
    @Published var swipeDownShortcut: HotkeyCombo {
        didSet { if let data = try? JSONEncoder().encode(swipeDownShortcut) { defaults.set(data, forKey: "swipeDownShortcut") } }
    }
    @Published var brightnessMin: Double {
        didSet { defaults.set(brightnessMin, forKey: "brightnessMin") }
    }
    @Published var brightnessMax: Double {
        didSet { defaults.set(brightnessMax, forKey: "brightnessMax") }
    }
    @Published var volumeMin: Double {
        didSet { defaults.set(volumeMin, forKey: "volumeMin") }
    }
    @Published var volumeMax: Double {
        didSet { defaults.set(volumeMax, forKey: "volumeMax") }
    }
    @Published var activationThreshold: Double {
        didSet { defaults.set(activationThreshold, forKey: "activationThreshold") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !reconcilingLoginStatus else { return }
            if !LoginItemManager.shared.setEnabled(launchAtLogin) {
                reconcilingLoginStatus = true
                launchAtLogin = LoginItemManager.shared.currentStatus()
                reconcilingLoginStatus = false
            }
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
        }
    }
    @Published var appearanceMode: String {
        didSet { defaults.set(appearanceMode, forKey: "appearanceMode") }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: "showDockIcon") }
    }

    // ── NEW: Global hotkey ───────────────────────────────────────────
    @Published var toggleHotkey: HotkeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(toggleHotkey) {
                defaults.set(data, forKey: "toggleHotkey")
            }
            HotkeyManager.shared.update(hotkey: toggleHotkey)
        }
    }

    // ── NEW: Excluded app bundle IDs ─────────────────────────────────
    @Published var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: "excludedApps") }
    }

    // ── NEW: OSD position ────────────────────────────────────────────
    @Published var osdPosition: OSDPosition {
        didSet { defaults.set(osdPosition.rawValue, forKey: "osdPosition") }
    }

    // ── NEW: OSD style: "vertical" | "horizontal" | "off" ───────────
    @Published var osdStyle: String {
        didSet { defaults.set(osdStyle, forKey: "osdStyle") }
    }

    // ── Horizontal OSD width (points, 120…320) ───────────────────────
    @Published var osdHorizontalWidth: Double {
        didSet { defaults.set(osdHorizontalWidth, forKey: "osdHorizontalWidth") }
    }

    // ── NEW: Menu bar display mode: "icon" | "volume" | "brightness"
    @Published var menuBarValueSource: String {
        didSet { defaults.set(menuBarValueSource, forKey: "menuBarValueSource") }
    }

    // ── NEW: Mute/unmute at zero ─────────────────────────────────────
    @Published var muteAtZero: Bool {
        didSet { defaults.set(muteAtZero, forKey: "muteAtZero") }
    }

    // Exact number of intentional contacts required to start a gesture.
    @Published var minimumFingers: Int {
        didSet { defaults.set(minimumFingers, forKey: "minimumFingers") }
    }

    // ── Cursor freeze while adjusting (1-finger mode only) ──────────
    @Published var cursorFreezeOnOneFinger: Bool {
        didSet { defaults.set(cursorFreezeOnOneFinger, forKey: "cursorFreezeOnOneFinger") }
    }

    // ── Top edge zone ─────────────────────────────────────────────────
    // horizontal mode: left half → topLeftAction, right half → topRightAction (swipe left/right)
    // vertical   mode: whole strip → topAction (swipe up/down)
    @Published var topEdgeEnabled: Bool {
        didSet { defaults.set(topEdgeEnabled, forKey: "topEdgeEnabled") }
    }
    @Published var topEdgeHeight: Double {
        didSet { defaults.set(topEdgeHeight, forKey: "topEdgeHeight") }
    }
    /// "horizontal" or "vertical"
    @Published var topEdgeSwipeDirection: String {
        didSet { defaults.set(topEdgeSwipeDirection, forKey: "topEdgeSwipeDirection") }
    }
    // horizontal mode actions (left half / right half)
    @Published var topLeftAction: ZoneAction {
        didSet { defaults.set(topLeftAction.rawValue, forKey: "topLeftAction") }
    }
    @Published var topRightAction: ZoneAction {
        didSet { defaults.set(topRightAction.rawValue, forKey: "topRightAction") }
    }
    // vertical mode action (single strip)
    @Published var topEdgeAction: ZoneAction {
        didSet { defaults.set(topEdgeAction.rawValue, forKey: "topEdgeAction") }
    }

    @Published var palmRejectionMode: String {
        didSet { defaults.set(palmRejectionMode, forKey: "palmRejectionMode") }
    }
    @Published var typingCooldown: Double {
        didSet { defaults.set(typingCooldown, forKey: "typingCooldown") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leftZoneWidth  = Self.clamp(defaults.object(forKey: "leftZoneWidth") as? Double ?? 0.2, to: Self.sideZoneWidthRange, fallback: 0.2)
        rightZoneWidth = Self.clamp(defaults.object(forKey: "rightZoneWidth") as? Double ?? 0.2, to: Self.sideZoneWidthRange, fallback: 0.2)
        sensitivity    = Self.clamp(defaults.object(forKey: "sensitivity") as? Double ?? 1, to: 0.3...3, fallback: 1)
        isEnabled      = defaults.object(forKey: "isEnabled")      as? Bool   ?? true
        hapticFeedback = defaults.object(forKey: "hapticFeedback") as? Bool   ?? true
        hapticStyle = HapticStyle(rawValue: defaults.string(forKey: "hapticStyle") ?? "") ?? .standard
        hapticSpacing = HapticSpacing(rawValue: defaults.string(forKey: "hapticSpacing") ?? "") ?? .regular
        hapticOnStart = defaults.object(forKey: "hapticOnStart") as? Bool ?? true
        invertScrollDirection = defaults.object(forKey: "invertScrollDirection") as? Bool ?? false

        let la = defaults.string(forKey: "leftZoneAction")  ?? ZoneAction.brightness.rawValue
        let ra = defaults.string(forKey: "rightZoneAction") ?? ZoneAction.volume.rawValue
        leftZoneAction  = ZoneAction(rawValue: la)  ?? .brightness
        rightZoneAction = ZoneAction(rawValue: ra)  ?? .volume
        swipeUpShortcut = defaults.data(forKey: "swipeUpShortcut").flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? .none
        swipeDownShortcut = defaults.data(forKey: "swipeDownShortcut").flatMap { try? JSONDecoder().decode(HotkeyCombo.self, from: $0) } ?? .none

        brightnessMin = Self.clamp(defaults.object(forKey: "brightnessMin") as? Double ?? 0.05, to: 0...0.95, fallback: 0.05)
        brightnessMax = max(Self.clamp(defaults.object(forKey: "brightnessMin") as? Double ?? 0.05, to: 0...0.95, fallback: 0.05) + 0.05, Self.clamp(defaults.object(forKey: "brightnessMax") as? Double ?? 1, to: 0.05...1, fallback: 1))
        volumeMin     = Self.clamp(defaults.object(forKey: "volumeMin") as? Double ?? 0, to: 0...0.95, fallback: 0)
        volumeMax     = max(Self.clamp(defaults.object(forKey: "volumeMin") as? Double ?? 0, to: 0...0.95, fallback: 0) + 0.05, Self.clamp(defaults.object(forKey: "volumeMax") as? Double ?? 1, to: 0.05...1, fallback: 1))

        activationThreshold = Self.clamp(defaults.object(forKey: "activationThreshold") as? Double ?? 4, to: 0...12, fallback: 4)
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        appearanceMode = defaults.string(forKey: "appearanceMode") ?? "system"
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? false

        if let data = defaults.data(forKey: "toggleHotkey"),
           let hk = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            toggleHotkey = hk
        } else {
            toggleHotkey = .none
        }

        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []

        let osdRaw = defaults.string(forKey: "osdPosition") ?? OSDPosition.right.rawValue
        osdPosition = OSDPosition(rawValue: osdRaw) ?? .right

        osdStyle = defaults.string(forKey: "osdStyle") ?? "horizontal"
        osdHorizontalWidth = Self.clamp(defaults.object(forKey: "osdHorizontalWidth") as? Double ?? 240, to: 160...320, fallback: 240)

        menuBarValueSource = defaults.string(forKey: "menuBarValueSource") ?? "icon"
        muteAtZero         = defaults.object(forKey: "muteAtZero") as? Bool ?? true
        minimumFingers = defaults.integer(forKey: "minimumFingers") == 1 ? 1 : 2
        cursorFreezeOnOneFinger = defaults.object(forKey: "cursorFreezeOnOneFinger") as? Bool ?? false

        topEdgeEnabled = defaults.integer(forKey: "minimumFingers") == 1 && (defaults.object(forKey: "topEdgeEnabled") as? Bool ?? false)
        topEdgeHeight  = Self.clamp(defaults.object(forKey: "topEdgeHeight") as? Double ?? 0.15, to: Self.topEdgeHeightRange, fallback: 0.15)

        topEdgeSwipeDirection = defaults.string(forKey: "topEdgeSwipeDirection") ?? "horizontal"
        let tla = defaults.string(forKey: "topLeftAction")  ?? ZoneAction.brightness.rawValue
        let tra = defaults.string(forKey: "topRightAction") ?? ZoneAction.volume.rawValue
        topLeftAction  = ZoneAction(rawValue: tla) ?? .brightness
        topRightAction = ZoneAction(rawValue: tra) ?? .volume
        let tea = defaults.string(forKey: "topEdgeAction") ?? ZoneAction.volume.rawValue
        topEdgeAction  = ZoneAction(rawValue: tea) ?? .volume
        palmRejectionMode = defaults.string(forKey: "palmRejectionMode") == "strict" ? "strict" : "balanced"
        typingCooldown = Self.clamp(defaults.object(forKey: "typingCooldown") as? Double ?? 0.45, to: 0.2...1.0, fallback: 0.45)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    func applyGesturePreset(_ preset: GesturePreset) {
        leftZoneAction = .brightness
        rightZoneAction = .volume
        leftZoneWidth = preset == .precise ? 0.12 : 0.20
        rightZoneWidth = preset == .precise ? 0.12 : 0.20
        minimumFingers = preset == .oneFinger ? 1 : 2
        sensitivity = preset == .precise ? 0.65 : 1.0
        activationThreshold = preset == .precise ? 7 : 4
        palmRejectionMode = preset == .precise ? "strict" : "balanced"
        typingCooldown = preset == .precise ? 0.65 : 0.45
        topEdgeEnabled = false
        invertScrollDirection = false
        cursorFreezeOnOneFinger = false
    }

    func resetGestureSettings() {
        applyGesturePreset(.everyday)
        brightnessMin = 0.05
        brightnessMax = 1
        volumeMin = 0
        volumeMax = 1
        topEdgeHeight = 0.15
        topEdgeSwipeDirection = "horizontal"
        topLeftAction = .brightness
        topRightAction = .volume
        topEdgeAction = .volume
        hapticFeedback = true
        hapticStyle = .standard
        hapticSpacing = .regular
        hapticOnStart = true
        muteAtZero = true
    }
}

enum GesturePreset: String, CaseIterable, Identifiable {
    case everyday, precise, oneFinger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyday: return "Everyday"
        case .precise: return "Precise"
        case .oneFinger: return "One finger"
        }
    }
    var detail: String {
        switch self {
        case .everyday: return "Two fingers · balanced"
        case .precise: return "Narrow zones · slower"
        case .oneFinger: return "One finger · edge only"
        }
    }
    var icon: String {
        switch self {
        case .everyday: return "hand.draw"
        case .precise: return "scope"
        case .oneFinger: return "hand.point.up"
        }
    }
}

// MARK: - Appearance helper (moved from ContentView extension)
extension TrackpadSettings {
    var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default: return nil
        }
    }
}
