import AppKit
import ApplicationServices
import HarborKit

/// Where the frontmost app's menus end in the menu bar, read through
/// Accessibility. Stow asks only for this one thing, and only for Always
/// Hidden on macOS 27: it sizes that section to exactly the room between the
/// menus and its divider. Everything else works without the permission.
@MainActor
enum AppMenuMeasure {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Called whenever the permission is found to have changed.
    static var onChange: (() -> Void)?
    private static var lastKnown: Bool?
    private static var watchToken: NSObjectProtocol?

    /// Follows the permission while Stow runs. macOS posts a system-wide
    /// note when the Accessibility list changes; the new state settles a
    /// moment later, so it's read again after a short wait.
    static func startWatching() {
        lastKnown = isAllowed
        publish()
        guard watchToken == nil else { return }
        watchToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { checkSoon() }
        }
    }

    /// Re-reads the permission now and over the next few seconds.
    static func checkSoon() {
        for delay in [0.0, 0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check() }
        }
    }

    private static func check() {
        let now = isAllowed
        guard now != lastKnown else { return }
        lastKnown = now
        log.notice("Accessibility \(now ? "allowed" : "not allowed")")
        publish()
        onChange?()
    }

    /// Tells Harbor, which shows it on Stow's page.
    private static func publish() {
        SettingsBridge.publishPermissions(["accessibility": isAllowed])
    }

    /// Shows the system prompt that adds Stow to the Accessibility list,
    /// then watches for the switch to be turned on.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        for delay in stride(from: 1.0, through: 60, by: 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check() }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The right edge of the frontmost app's last menu title, in screen
    /// points from the left of the main display. Nil without permission or
    /// when the app has no menu bar to read.
    static func menusEnd() -> CGFloat? {
        guard isAllowed, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBar, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement], !items.isEmpty else { return nil }
        let ends = items.compactMap { item -> CGFloat? in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { return nil }
            var origin = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return extent.width > 0 ? origin.x + extent.width : nil
        }
        return ends.max()
    }
}
