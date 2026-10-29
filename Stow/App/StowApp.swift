import HarborKit
import OSLog
import SwiftUI

let log = Logger(subsystem: "app.stow.Stow", category: "app")

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?
    private let shortcut = ToggleShortcut()
    private let hover = HoverReveal()
    private var defaultsToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        SettingsBridge.listen()

        let controller = StatusController()
        controller.onShowSettings = { [weak self] in self?.showSettings() }
        controller.onShowGuide = { Guide.show() }
        self.controller = controller
        shortcut.onPress = { [weak controller] in controller?.toggleHidden() }
        hover.onDwell = { [weak controller] in
            if controller?.state == .hidden { controller?.reveal() }
        }
        applyPrefs()

        // Settings change here or in Harbor; either way, apply them at once.
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }

        if !Prefs.bool(Prefs.hasCompletedOnboarding) { Guide.show() }
        #if DEBUG
        // `Stow --cycle` steps through hidden, shown and all every few seconds,
        // for watching the bar without clicking.
        if CommandLine.arguments.contains("--cycle") {
            // A stand-in icon to the left of the divider, so hiding shows.
            let test = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            test.button?.title = "TEST"
            Task { @MainActor in
                _ = test
                for state in [StatusController.State.shown, .hidden, .all, .hidden] {
                    try? await Task.sleep(for: .seconds(4))
                    controller.set(state)
                    log.notice("cycle: \(String(describing: state))")
                }
            }
        }
        #endif
        log.notice("Launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.restoreForQuit()
    }

    /// Opening Stow again (Launchpad, Finder) shows its settings, since it has no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private var applied: (shortcut: String, hover: Bool, always: Bool, dividers: Bool)?

    private func applyPrefs() {
        let now = (Prefs.string(Prefs.toggleShortcut), Prefs.bool(Prefs.revealOnHover),
                   Prefs.bool(Prefs.alwaysHiddenEnabled), Prefs.bool(Prefs.showDividers))
        if applied?.shortcut != now.0 { shortcut.apply(now.0) }
        if applied?.hover != now.1 { hover.setEnabled(now.1) }
        if applied == nil || applied?.always != now.2 || applied?.dividers != now.3 { controller?.applySettings() }
        applied = now
    }

    /// With Harbor installed, settings live there; otherwise in Stow's own window.
    private func showSettings() {
        guard !HarborLink.openSettings(appID: "stow") else { return }
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
