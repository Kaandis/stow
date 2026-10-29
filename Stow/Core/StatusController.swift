import AppKit

/// Stow's own menu bar items, right to left: the toggle, the divider that
/// closes off the Hidden section, and (when turned on) the divider for
/// Always Hidden.
///
/// Hiding a section is widening its divider until nothing to its left fits,
/// and macOS leaves those icons out of the bar. Before macOS 27 one very
/// wide divider does it. macOS 27 discards any item wider than half its
/// display, so there the divider stops at that cap and blank spacers, placed
/// right beside it, make up the rest. It's all public `NSStatusItem` API, so
/// Stow needs no permissions, and nothing runs while the bar sits still.
@MainActor
final class StatusController {
    enum State { case hidden, shown, all }

    private(set) var state = State.hidden
    var onShowSettings: (() -> Void)?
    var onShowGuide: (() -> Void)?

    private let toggle: NSStatusItem
    private let divider: NSStatusItem
    private var alwaysDivider: NSStatusItem?
    private var rehide: DispatchWorkItem?
    /// Blank items filling beside each closed divider on macOS 27, keyed by
    /// the divider's autosave name. They exist only while hiding, so they
    /// leave no gaps when icons show.
    private var spacers: [String: [NSStatusItem]] = [:]
    /// Bumped on every change, so a delayed grow never lands after the
    /// icons were asked to show again.
    private var fillGeneration = 0

    /// Before macOS 27: wider than any display, so everything to the left
    /// is pushed off.
    private static let closedLength: CGFloat = 10_000
    private static let dividerLength: CGFloat = 14
    /// The room macOS 27 adds around each item's length.
    private static let hostedPadding: CGFloat = 16
    private static let isHosted = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    init() {
        // On first launch, seed the order: Stow's arrow at the right end of
        // the app icons (left of Wi-Fi, battery and the other system items),
        // its divider just left of it. Larger positions sit
        // further left, and 0 means "unset". After that, macOS keeps wherever
        // you ⌘-drag them.
        let start = Self.systemItemsEdge + 1
        Self.seedPosition("Stow.Arrow", start)
        Self.seedPosition("Stow.Divider", start + 1)
        let bar = NSStatusBar.system
        toggle = bar.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "Stow.Arrow"
        divider = bar.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "Stow.Divider"

        if let button = toggle.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "Stow"))
        }
        divider.button?.setAccessibilityLabel(String(localized: "Stow divider"))
        applySettings()
        // Open first; hide once the items are laid out and their order can be
        // checked. On first launch they stay open for the guide.
        apply(.shown, animated: false)
        if Prefs.bool(Prefs.hasCompletedOnboarding) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.set(.hidden) }
        }
    }

    /// Re-reads the settings that shape the bar: the Always Hidden divider
    /// and whether dividers show.
    func applySettings() {
        if Prefs.bool(Prefs.alwaysHiddenEnabled), alwaysDivider == nil {
            Self.seedPosition("Stow.AlwaysDivider", Self.systemItemsEdge + 3)
            let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
            item.autosaveName = "Stow.AlwaysDivider"
            item.button?.setAccessibilityLabel(String(localized: "Stow Always Hidden divider"))
            alwaysDivider = item
        } else if !Prefs.bool(Prefs.alwaysHiddenEnabled), let item = alwaysDivider {
            removeSpacers(beside: item)
            NSStatusBar.system.removeStatusItem(item)
            alwaysDivider = nil
        }
        apply(state, animated: false)
    }

    // MARK: Showing and hiding

    func toggleHidden() {
        set(state == .hidden ? .shown : .hidden, byUser: true)
    }

    func reveal(all: Bool = false) {
        set(all ? .all : .shown)
    }

    /// `byUser` marks a click or shortcut; only then is a problem explained
    /// in a dialog, never on an automatic re-hide.
    func set(_ new: State, byUser: Bool = false) {
        if new == .hidden && !orderIsValid {
            // The toggle sits left of the divider: hiding would hide Stow
            // itself, with no way back. Stay open and say why.
            apply(.shown, animated: true)
            if byUser { showOrderHint() }
            log.notice("Not hiding: Stow's arrow is left of its divider")
            return
        }
        apply(new, animated: true)
    }

    private func apply(_ new: State, animated: Bool) {
        state = new
        fillGeneration += 1
        let dividers = Prefs.bool(Prefs.showDividers)
        configure(divider, closed: new == .hidden, visible: dividers, glyph: "|")
        if let alwaysDivider {
            configure(alwaysDivider, closed: new != .all, visible: dividers, glyph: "‖")
        }
        toggle.button?.image = NSImage(systemSymbolName: new == .hidden ? "chevron.compact.left" : "chevron.compact.right",
                                       accessibilityDescription: nil)
        toggle.button?.image?.isTemplate = true
        toggle.button?.toolTip = new == .hidden ? String(localized: "Show hidden icons") : String(localized: "Hide icons")
        scheduleRehide()
    }

    private func configure(_ item: NSStatusItem, closed: Bool, visible: Bool, glyph: String) {
        if closed && Self.isHosted {
            fill(beside: item)
        } else {
            removeSpacers(beside: item)
            item.length = closed ? Self.closedLength : (visible ? Self.dividerLength : 0)
        }
        guard let button = item.button else { return }
        button.image = closed || !visible ? nil : Self.dividerImage(double: glyph == "‖")
        button.isEnabled = false
    }

    // MARK: macOS 27 filling

    /// Closes `divider` on macOS 27: the divider at the largest length every
    /// display accepts, and enough blank spacers right beside it to span the
    /// widest display. macOS then overflows everything left of them; the
    /// divider and spacers go too, so no gap is left behind.
    ///
    /// New spacers start at no length and everything grows together a beat
    /// later, once they're in place. Grown one by one, the divider would
    /// first shove the icons left and only then would they fade into the
    /// overflow; together they always simply fade.
    private func fill(beside divider: NSStatusItem) {
        let widths = NSScreen.screens.map(\.frame.width)
        let cap = ((widths.min() ?? 1000) / 2).rounded(.down) - Self.hostedPadding
        let slot = cap + Self.hostedPadding
        let count = min(max(Int(((widths.max() ?? 1000) / slot).rounded(.up)), 1), 8)
        guard let name = divider.autosaveName else { divider.length = cap; return }

        var placed = false
        if (spacers[name]?.count ?? 0) != count - 1 {
            removeSpacers(beside: divider)
            // Seated just left of wherever the divider is now, so they move
            // with it when you ⌘-drag the divider elsewhere.
            let base = UserDefaults.standard.double(forKey: Self.positionKey(name))
            spacers[name] = (1..<max(count, 1)).map { index in
                let spacerName = "\(name).Spacer\(index)"
                UserDefaults.standard.set(base + Double(index) * 0.1, forKey: Self.positionKey(spacerName))
                let item = NSStatusBar.system.statusItem(withLength: 0)
                item.autosaveName = spacerName
                item.button?.title = ""
                item.button?.isEnabled = false
                item.button?.setAccessibilityElement(false)
                return item
            }
            placed = !(spacers[name]?.isEmpty ?? true)
        }
        let generation = fillGeneration
        let grow = { [weak self] in
            guard let self, generation == self.fillGeneration else { return }
            divider.length = cap
            self.spacers[name]?.forEach { $0.length = cap }
        }
        if placed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: grow)
        } else {
            grow()
        }
    }

    private func removeSpacers(beside divider: NSStatusItem) {
        guard let name = divider.autosaveName, let items = spacers.removeValue(forKey: name) else { return }
        for item in items {
            let key = item.autosaveName.map(Self.positionKey)
            NSStatusBar.system.removeStatusItem(item)
            if let key { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private static func positionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// The leftmost of Control Center's own items (Wi-Fi, battery…), read
    /// from its preferences, so Stow's arrow starts just left of them.
    private static var systemItemsEdge: Double {
        let positions = (UserDefaults(suiteName: "com.apple.controlcenter")?.dictionaryRepresentation() ?? [:])
            .filter { $0.key.hasPrefix("NSStatusItem Preferred Position") }
            .compactMap { ($0.value as? NSNumber)?.doubleValue }
        return positions.max() ?? 0
    }

    private static func seedPosition(_ autosaveName: String, _ position: Double) {
        let key = positionKey(autosaveName)
        if UserDefaults.standard.double(forKey: key) == 0 { UserDefaults.standard.set(position, forKey: key) }
    }

    /// A thin rounded rule, drawn as a template so it follows the bar's colour.
    private static func dividerImage(double: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 14), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.45).setFill()
            let xs: [CGFloat] = double ? [1.5, 3.5] : [2.5]
            for x in xs {
                NSBezierPath(roundedRect: NSRect(x: x - 0.6, y: 1, width: 1.2, height: rect.height - 2),
                             xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Tucks the icons away again after a while, but not while the pointer
    /// is on the menu bar or one of its menus is open.
    private func scheduleRehide() {
        rehide?.cancel()
        let delay = Prefs.double(Prefs.hideDelay)
        guard state != .hidden, delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state != .hidden else { return }
            if MenuBarState.isPointerOnMenuBar || MenuBarState.isMenuOpen {
                self.rehide = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scheduleRehideSoon() }
                return
            }
            self.set(.hidden)
        }
        rehide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleRehideSoon() {
        guard state != .hidden, rehide == nil else { return }
        if MenuBarState.isPointerOnMenuBar || MenuBarState.isMenuOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scheduleRehideSoon() }
        } else {
            set(.hidden)
        }
    }

    /// The toggle has to stay right of the divider(s).
    private var orderIsValid: Bool {
        guard let toggleX = toggle.button?.window?.frame.minX,
              let dividerX = divider.button?.window?.frame.minX else { return true }
        return toggleX > dividerX
    }

    private func showOrderHint() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Stow’s arrow is left of its divider")
        alert.informativeText = String(localized: "Hold ⌘ and drag Stow’s arrow to the right of the thin divider, so it stays in the menu bar when the icons tuck away.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Clicks

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            set(state == .all ? .hidden : .all, byUser: true)
        } else {
            toggleHidden()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if alwaysDivider != nil {
            let item = menu.addItem(withTitle: state == .all ? String(localized: "Hide Always Hidden Icons")
                                                               : String(localized: "Show Always Hidden Icons"),
                                    action: #selector(toggleAll), keyEquivalent: "")
            item.target = self
            menu.addItem(.separator())
        }
        let settings = menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let guide = menu.addItem(withTitle: String(localized: "How to Use Stow…"), action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Stow"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggle.menu = menu
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    @objc private func toggleAll() { set(state == .all ? .hidden : .all, byUser: true) }
    @objc private func openSettings() { onShowSettings?() }
    @objc private func openGuide() { onShowGuide?() }

    /// Puts every icon back before Stow quits, so nothing is left pushed away.
    func restoreForQuit() {
        removeSpacers(beside: divider)
        if let alwaysDivider { removeSpacers(beside: alwaysDivider) }
        divider.length = Self.dividerLength
        alwaysDivider?.length = Self.dividerLength
    }
}

/// What's happening on the menu bar right now, read only when asked.
enum MenuBarState {
    static var isPointerOnMenuBar: Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 6
    }

    /// Whether any app has a menu open, judged by pop-up menu windows on screen.
    static var isMenuOpen: Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }
}
