import Foundation
import Carbon

/// Exercises production settings and their real dependent types without ever
/// constructing an application delegate, monitor, or hardware controller.
@main
enum SettingsRegressionTests {
    private static var checks = 0
    private static var cases = 0

    private enum Failure: Error, CustomStringConvertible {
        case assertion(String, Int)
        case preferencesUnavailable
        var description: String {
            switch self {
            case let .assertion(message, line): return "Line \(line): \(message)"
            case .preferencesUnavailable: return "Could not create isolated test preferences."
            }
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String, line: Int = #line) throws {
        checks += 1
        if !condition() { throw Failure.assertion(message, line) }
    }

    private static func near(_ value: Double, _ expected: Double) -> Bool {
        value.isFinite && abs(value - expected) < 0.000_001
    }

    private static func isolated(_ label: String, seed: [String: Any] = [:],
                                 _ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "com.sway.settings-regression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
        // Only this disposable test domain is written or removed. Never use
        // UserDefaults.standard, the app's bundle domain, or registered globals.
        defaults.setPersistentDomain(seed, forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
        cases += 1
        print("PASS \(label)")
    }

    static func main() throws {
        try isolated("fresh installation defaults") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(settings.isEnabled && settings.minimumFingers == 2, "fresh setup enables two-finger gestures")
            try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "familiar default edge actions")
            try expect(near(settings.leftZoneWidth, 0.2) && near(settings.rightZoneWidth, 0.2), "default zones leave free center space")
            try expect(near(settings.brightnessMin, 0.05) && near(settings.brightnessMax, 1), "default brightness protects against a black screen")
            try expect(near(settings.volumeMin, 0) && near(settings.volumeMax, 1), "fresh audio uses its full range")
            try expect(!settings.topEdgeEnabled && !settings.cursorFreezeOnOneFinger, "fresh setup does not add top zones or freeze the pointer")
            try expect(settings.palmRejectionMode == "balanced" && near(settings.typingCooldown, 0.45), "typing protection is enabled by default")
            try expect(settings.toggleHotkey.isEmpty && !settings.launchAtLogin, "no system shortcut or login registration is implied")
            try expect(settings.excludedApps.isEmpty && settings.appearanceMode == "system", "fresh app scope and appearance")
            try expect(settings.osdStyle == "horizontal" && near(settings.osdHorizontalWidth, 240), "fresh indicator uses the readable pill")
            try expect(settings.hapticConfiguration == HapticConfiguration(), "fresh haptics use standard 5% steps and an activation tap")
            try expect(!settings.showDockIcon, "menu-bar-only appearance stays the default")
        }

        try isolated("Dock discoverability persists independently") { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.showDockIcon = true
            let restored = TrackpadSettings(defaults: defaults)
            try expect(restored.showDockIcon, "Dock preference survives relaunch")
            restored.applyGesturePreset(.precise)
            try expect(restored.showDockIcon, "presets leave app discoverability alone")
            restored.resetGestureSettings()
            try expect(restored.showDockIcon, "gesture reset preserves Dock preference")
            restored.showDockIcon = false
            try expect(!TrackpadSettings(defaults: defaults).showDockIcon, "Dock icon can be disabled and stays disabled")
        }

        try isolated("legacy haptics off stays off", seed: ["hapticFeedback": false]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(!settings.hapticFeedback && !settings.hapticConfiguration.enabled, "upgrading never re-enables disabled haptics")
        }
        try isolated("unknown haptic preferences recover safely", seed: ["hapticStyle": "strongest", "hapticSpacing": "invalid", "hapticOnStart": "invalid"]) { defaults, _ in
            try expect(TrackpadSettings(defaults: defaults).hapticConfiguration == HapticConfiguration(), "unknown styles, spacing, and start values fall back")
        }
        for style in HapticStyle.allCases {
            for spacing in HapticSpacing.allCases {
                try isolated("haptic preferences persist: \(style.rawValue), \(spacing.rawValue)") { defaults, suite in
                    let settings = TrackpadSettings(defaults: defaults)
                    settings.hapticStyle = style
                    settings.hapticSpacing = spacing
                    settings.hapticOnStart = false
                    settings.hapticFeedback = false
                    defaults.synchronize()
                    let restored = TrackpadSettings(defaults: UserDefaults(suiteName: suite)!)
                    try expect(restored.hapticConfiguration == HapticConfiguration(enabled: false, style: style, spacing: spacing, onStart: false), "all choices survive relaunch even when disabled")
                    restored.hapticFeedback = true
                    restored.applyGesturePreset(.precise)
                    try expect(restored.hapticConfiguration == HapticConfiguration(style: style, spacing: spacing, onStart: false), "reenabling and gesture presets retain preferred haptics")
                    restored.resetGestureSettings()
                    try expect(TrackpadSettings(defaults: defaults).hapticConfiguration == HapticConfiguration(), "explicit reset restores haptics and persists them")
                }
            }
        }

        try isolated("out-of-range persisted numbers recover safely", seed: [
            "leftZoneWidth": -4.0, "rightZoneWidth": 8.0, "sensitivity": 100.0,
            "brightnessMin": -2.0, "brightnessMax": 4.0,
            "volumeMin": 0.90, "volumeMax": 0.10,
            "activationThreshold": -5.0, "osdHorizontalWidth": 900.0,
            "topEdgeHeight": -1.0, "typingCooldown": 40.0,
            "minimumFingers": 99, "topEdgeEnabled": true
        ]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(near(settings.leftZoneWidth, 0.01), "negative left width clamps to 1% minimum")
            try expect(near(settings.rightZoneWidth, 0.4), "oversized right width clamps to maximum")
            try expect(near(settings.sensitivity, 3), "sensitivity clamps on load")
            try expect(near(settings.brightnessMin, 0) && near(settings.brightnessMax, 1), "brightness remains within device range")
            try expect(near(settings.volumeMin, 0.90) && near(settings.volumeMax, 0.95), "inverted audio limits retain a usable interval")
            try expect(near(settings.activationThreshold, 0), "activation distance cannot be negative")
            try expect(near(settings.osdHorizontalWidth, 320), "indicator fits its supported width")
            try expect(near(settings.topEdgeHeight, 0.01), "top strip supports a 1% minimum height")
            try expect(near(settings.typingCooldown, 1), "typing cooldown remains bounded")
            try expect(settings.minimumFingers == 2 && !settings.topEdgeEnabled, "invalid finger count cannot enable unsupported two-finger top mode")
        }

        try isolated("malformed persisted values fall back", seed: [
            "sensitivity": "invalid", "leftZoneAction": "unknown", "rightZoneAction": "unknown",
            "osdPosition": "unknown", "palmRejectionMode": "unknown",
            "toggleHotkey": Data([0xff, 0x00]), "brightnessMin": 100.0, "brightnessMax": -100.0
        ]) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            try expect(near(settings.sensitivity, 1), "nonnumeric sensitivity uses its default")
            try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "unknown actions remain usable")
            try expect(settings.osdPosition == .right && settings.palmRejectionMode == "balanced", "invalid constrained options use defaults")
            try expect(settings.toggleHotkey.isEmpty, "corrupt shortcut data does not register a shortcut")
            try expect(near(settings.brightnessMin, 0.95) && near(settings.brightnessMax, 1), "reversed extreme brightness limits stay within 0–1")
            for value in [Double.nan, .infinity, -.infinity] {
                try expect(near(TrackpadSettings.clamp(value, to: 0...1, fallback: 0.45), 0.45), "nonfinite scalar uses safe fallback")
            }
            try expect(near(TrackpadSettings.clamp(-1, to: 0...1, fallback: 0.45), 0), "finite low scalar clamps")
            try expect(near(TrackpadSettings.clamp(2, to: 0...1, fallback: 0.45), 1), "finite high scalar clamps")
            try expect(near(TrackpadSettings.clamp(0.37, to: 0...1, fallback: 0.45), 0.37), "in-range precision is preserved")
        }

        for width in [0.01, 0.025] {
            try isolated("\(width * 100)% edge widths survive persistence", seed: [
                "leftZoneWidth": width, "rightZoneWidth": width,
                "topEdgeHeight": width, "minimumFingers": 1, "topEdgeEnabled": true
            ]) { defaults, suite in
                let settings = TrackpadSettings(defaults: defaults)
                try expect(near(settings.leftZoneWidth, width), "narrow left width is not raised to the old 5% floor")
                try expect(near(settings.rightZoneWidth, width), "narrow right width is not raised to the old 5% floor")
                try expect(near(settings.topEdgeHeight, width), "narrow top height loads without rounding")
                let changedWidth = width == 0.01 ? 0.025 : 0.01
                settings.leftZoneWidth = changedWidth
                settings.rightZoneWidth = changedWidth
                settings.topEdgeHeight = changedWidth
                defaults.synchronize()
                guard let reopened = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
                let restored = TrackpadSettings(defaults: reopened)
                try expect(near(restored.leftZoneWidth, changedWidth), "edited narrow left width survives a new preferences instance")
                try expect(near(restored.rightZoneWidth, changedWidth), "edited narrow right width survives a new preferences instance")
                try expect(near(restored.topEdgeHeight, changedWidth), "edited narrow top height survives a new preferences instance")
            }
        }

        let shortcut = HotkeyCombo(keyCode: 1, modifiers: UInt32(cmdKey | optionKey))
        let preferenceSeed: [String: Any] = [
            "excludedApps": ["com.example.editor", "com.example.meeting"],
            "appearanceMode": "dark", "toggleHotkey": try JSONEncoder().encode(shortcut),
            "launchAtLogin": true, "isEnabled": false, "osdStyle": "off", "menuBarValueSource": "both"
        ]
        for preset in GesturePreset.allCases {
            try isolated("\(preset.title) preset scope", seed: preferenceSeed) { defaults, _ in
                let settings = TrackpadSettings(defaults: defaults)
                settings.leftZoneAction = .disabled
                settings.rightZoneAction = .brightness
                settings.invertScrollDirection = true
                settings.topEdgeEnabled = true
                settings.cursorFreezeOnOneFinger = true
                settings.brightnessMin = 0.2
                settings.volumeMax = 0.6
                settings.applyGesturePreset(preset)
                try expect(settings.leftZoneAction == .brightness && settings.rightZoneAction == .volume, "preset restores deliberate edge assignments")
                try expect(settings.minimumFingers == (preset == .oneFinger ? 1 : 2), "preset selects its advertised contact count")
                try expect(near(settings.leftZoneWidth, preset == .precise ? 0.12 : 0.2) && near(settings.rightZoneWidth, settings.leftZoneWidth), "preset widths match intended precision")
                try expect(near(settings.sensitivity, preset == .precise ? 0.65 : 1), "precise preset slows level changes")
                try expect(near(settings.activationThreshold, preset == .precise ? 7 : 4), "precise preset requires additional travel")
                try expect(settings.palmRejectionMode == (preset == .precise ? "strict" : "balanced"), "preset applies its intent policy")
                try expect(near(settings.typingCooldown, preset == .precise ? 0.65 : 0.45), "preset applies its typing delay")
                try expect(!settings.topEdgeEnabled && !settings.invertScrollDirection && !settings.cursorFreezeOnOneFinger, "preset resets optional gesture modifiers")
                try expect(near(settings.brightnessMin, 0.2) && near(settings.volumeMax, 0.6), "gesture preset preserves comfort limits")
                try preservedPreferences(settings, shortcut: shortcut)
            }
        }

        try isolated("reset restores gestures and limits only", seed: preferenceSeed) { defaults, _ in
            let settings = TrackpadSettings(defaults: defaults)
            settings.applyGesturePreset(.precise)
            settings.brightnessMin = 0.4; settings.brightnessMax = 0.6
            settings.volumeMin = 0.2; settings.volumeMax = 0.3
            settings.topEdgeEnabled = true; settings.topEdgeHeight = 0.28
            settings.topEdgeSwipeDirection = "vertical"
            settings.topLeftAction = .volume; settings.topRightAction = .disabled; settings.topEdgeAction = .brightness
            settings.hapticFeedback = false; settings.muteAtZero = false
            settings.resetGestureSettings()
            try expect(settings.minimumFingers == 2 && !settings.topEdgeEnabled, "reset restores simple two-finger setup")
            try expect(near(settings.sensitivity, 1) && near(settings.activationThreshold, 4), "reset restores everyday responsiveness")
            try expect(settings.palmRejectionMode == "balanced" && near(settings.typingCooldown, 0.45), "reset retains typing and intent protection")
            try expect(near(settings.brightnessMin, 0.05) && near(settings.brightnessMax, 1), "reset restores safe brightness range")
            try expect(near(settings.volumeMin, 0) && near(settings.volumeMax, 1), "reset restores audio range")
            try expect(near(settings.topEdgeHeight, 0.15) && settings.topEdgeSwipeDirection == "horizontal", "reset restores top geometry")
            try expect(settings.topLeftAction == .brightness && settings.topRightAction == .volume && settings.topEdgeAction == .volume, "reset restores all top assignments")
            try expect(settings.hapticFeedback && settings.muteAtZero, "reset restores feedback options")
            try preservedPreferences(settings, shortcut: shortcut)
        }

        try isolated("edits survive a new settings instance", seed: preferenceSeed) { defaults, suite in
            let settings = TrackpadSettings(defaults: defaults)
            settings.applyGesturePreset(.oneFinger)
            settings.leftZoneAction = .volume; settings.rightZoneAction = .disabled
            settings.leftZoneWidth = 0.17; settings.rightZoneWidth = 0.27
            settings.brightnessMin = 0.12; settings.brightnessMax = 0.83
            settings.volumeMin = 0.08; settings.volumeMax = 0.74
            settings.topEdgeEnabled = true; settings.topEdgeHeight = 0.11
            settings.topEdgeSwipeDirection = "vertical"; settings.topEdgeAction = .brightness
            settings.typingCooldown = 0.7; settings.palmRejectionMode = "strict"
            settings.invertScrollDirection = true; settings.cursorFreezeOnOneFinger = true
            settings.hapticFeedback = false; settings.muteAtZero = false
            defaults.synchronize()
            guard let reopened = UserDefaults(suiteName: suite) else { throw Failure.preferencesUnavailable }
            let restored = TrackpadSettings(defaults: reopened)
            try expect(restored.minimumFingers == 1 && restored.topEdgeEnabled, "one-finger top mode survives reload")
            try expect(restored.leftZoneAction == .volume && restored.rightZoneAction == .disabled, "edge actions persist")
            try expect(near(restored.leftZoneWidth, 0.17) && near(restored.rightZoneWidth, 0.27), "zone geometry persists")
            try expect(near(restored.brightnessMin, 0.12) && near(restored.brightnessMax, 0.83), "brightness range persists")
            try expect(near(restored.volumeMin, 0.08) && near(restored.volumeMax, 0.74), "audio range persists")
            try expect(near(restored.topEdgeHeight, 0.11) && restored.topEdgeSwipeDirection == "vertical" && restored.topEdgeAction == .brightness, "top configuration persists")
            try expect(restored.palmRejectionMode == "strict" && near(restored.typingCooldown, 0.7), "intent configuration persists")
            try expect(restored.invertScrollDirection && restored.cursorFreezeOnOneFinger && !restored.hapticFeedback && !restored.muteAtZero, "gesture modifiers persist")
            try expect(reopened.persistentDomain(forName: suite)?["leftZoneAction"] as? String == "volume", "changes are written to the isolated persistent domain")
            try preservedPreferences(restored, shortcut: shortcut)
            restored.resetGestureSettings()
            let resetReload = TrackpadSettings(defaults: reopened)
            try expect(resetReload.minimumFingers == 2 && !resetReload.topEdgeEnabled && near(resetReload.brightnessMin, 0.05), "reset itself persists across reload")
        }
        for action in ZoneAction.allCases {
            try isolated("action persists: \(action.rawValue)") { defaults, _ in
                let settings = TrackpadSettings(defaults: defaults)
                settings.leftZoneAction = action
                settings.rightZoneAction = action
                settings.topEdgeAction = action
                settings.swipeUpShortcut = HotkeyCombo(keyCode: 24, modifiers: UInt32(cmdKey))
                settings.swipeDownShortcut = HotkeyCombo(keyCode: 27, modifiers: UInt32(cmdKey))
                let reopened = TrackpadSettings(defaults: defaults)
                try expect(reopened.leftZoneAction == action && reopened.rightZoneAction == action && reopened.topEdgeAction == action, "all edges retain the action")
                try expect(reopened.swipeUpShortcut == settings.swipeUpShortcut && reopened.swipeDownShortcut == settings.swipeDownShortcut, "custom pairs persist without global registration")
            }
        }
        print("\(checks) settings assertions passed across \(cases) isolated cases. No monitor, hardware writes, shortcuts, or login registrations ran.")
    }

    private static func preservedPreferences(_ settings: TrackpadSettings, shortcut: HotkeyCombo) throws {
        try expect(settings.excludedApps == ["com.example.editor", "com.example.meeting"], "excluded applications are preserved")
        try expect(settings.appearanceMode == "dark", "appearance is preserved")
        try expect(settings.toggleHotkey == shortcut, "saved shortcut is preserved without registration")
        try expect(settings.launchAtLogin && !settings.isEnabled, "login preference and pause state are preserved")
        try expect(settings.osdStyle == "off" && settings.menuBarValueSource == "both", "indicator and menu preferences are preserved")
    }
}
