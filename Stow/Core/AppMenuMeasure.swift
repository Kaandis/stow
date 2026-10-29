import AppKit
import ApplicationServices

/// Where the frontmost app's menus end in the menu bar, read through
/// Accessibility. Stow asks only for this one thing: with it, the space it
/// fills when hiding is exactly the room between the menus and its divider,
/// so icons fade out and back in instead of sliding. Without the permission
/// Stow still works; it just fills more than it needs.
@MainActor
enum AppMenuMeasure {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Stow to the Accessibility list.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
