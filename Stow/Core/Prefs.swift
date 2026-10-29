import Foundation

/// UserDefaults keys shared by @AppStorage and the controller. Every key a
/// user can change is also described in `Resources/settings-schema.json`, so
/// Harbor can show these settings too.
enum Prefs {
    /// Seconds before revealed items tuck away again; 0 keeps them out.
    static let hideDelay = "hideDelay"
    /// Reveal when the pointer rests on the menu bar.
    static let revealOnHover = "revealOnHover"
    /// Show the thin dividers while items are revealed, so you can see where
    /// to ⌘-drag an icon.
    static let showDividers = "showDividers"
    /// A second divider for items that stay hidden until you ask for them.
    static let alwaysHiddenEnabled = "alwaysHiddenEnabled"
    /// "off", "controlOptionS" or "optionCommandB".
    static let toggleShortcut = "toggleShortcut"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hideDelay: 15.0,
            revealOnHover: false,
            showDividers: true,
            alwaysHiddenEnabled: false,
            toggleShortcut: "off",
            hasCompletedOnboarding: false,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
}
