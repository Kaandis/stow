import AppKit

/// Stow's own menu bar items, right to left: the toggle, the divider that
/// closes off the Hidden section, and (when turned on) the divider for
/// Always Hidden.
///
/// Hiding a section is making sure nothing to the left of its divider fits,
/// and macOS leaves those icons out of the bar. Before macOS 27 the divider
/// itself widens past the screen. macOS 27 discards any item wider than half
/// its display and keeps where items sit to itself, so a blank item can't be
/// seated beside the divider reliably. There the divider and the arrow each
/// take half the display instead: macOS seats both where you put them, by
/// name, and together they leave no room left of the divider. It's all
/// public `NSStatusItem` API, and nothing runs while the bar sits still.
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
    private var pendingLayout: DispatchWorkItem?
    private var lastLayout = Date.distantPast
    /// How long macOS takes to fade icons in or out of the bar.
    private static let settleTime: TimeInterval = 0.45

    /// Before macOS 27: wider than any display, so everything to the left
    /// is pushed off.
    private static let closedLength: CGFloat = 10_000
    private static let dividerLength: CGFloat = 14
    /// The widest an item may be on macOS 27: half the narrowest display,
    /// since every display shows it.
    private static var halfDisplay: CGFloat {
        ((NSScreen.screens.map(\.frame.width).min() ?? 1000) / 2).rounded(.down) - hostedPadding
    }
    /// The room macOS 27 adds around each item's length.
    private static let hostedPadding: CGFloat = 16
    private static let isHosted = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    init() {
        // On first launch, seed the order: Stow's arrow at the right end of
        // the app icons (left of Wi-Fi, battery and the other system items),
        // its divider just left of it. Larger positions sit
        // further left, and 0 means "unset". After that, macOS keeps wherever
        // you ⌘-drag them.
        // Spacers from Stow 1.0.4 and earlier would come back as blank gaps.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(Self.positionKey("Stow.")) && key.contains(".Spacer") || key.hasPrefix("seat Stow.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let start = Self.systemItemsEdge + 1
        Self.seedPosition("Stow.Arrow", start)
        Self.seedPosition("Stow.Divider", start + 1)
        let bar = NSStatusBar.system
        toggle = bar.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "Stow.Arrow"
        divider = bar.statusItem(withLength: Self.dividerLength)
        divider.autosaveName = "Stow.Divider"
        // Quit while taken off the bar to change width, they'd stay off.
        toggle.isVisible = true
        divider.isVisible = true

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
        let wantsAlwaysHidden = Prefs.bool(Prefs.alwaysHiddenEnabled)
        if wantsAlwaysHidden, alwaysDivider == nil {
            // It starts at the far left, so nothing is always hidden until you
            // ⌘-drag icons past it. Everything shows so you can see it at once.
            Self.seedPosition("Stow.AlwaysDivider", 100_000)
            let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
            item.autosaveName = "Stow.AlwaysDivider"
            item.button?.setAccessibilityLabel(String(localized: "Stow Always Hidden divider"))
            item.isVisible = true
            alwaysDivider = item
            state = .all
        } else if !wantsAlwaysHidden, let item = alwaysDivider {
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

    /// The arrow answers at once; the bar follows. While macOS is still
    /// animating the last change, a new one waits for it to finish and only
    /// the latest state is applied. Changed mid-animation, the bar throws the
    /// icons to the far left and slides them back.
    private func apply(_ new: State, animated: Bool) {
        state = new
        drawArrow()
        toggle.button?.toolTip = new == .hidden ? String(localized: "Show hidden icons") : String(localized: "Hide icons")
        scheduleRehide()

        pendingLayout?.cancel()
        let wait = animated ? Self.settleTime - Date().timeIntervalSince(lastLayout) : 0
        guard wait > 0 else { layOut(); return }
        let work = DispatchWorkItem { [weak self] in self?.layOut() }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Sets the dividers for the current state.
    private func layOut() {
        pendingLayout = nil
        lastLayout = Date()
        // Showing everything is when you arrange, so dividers show then even
        // if you hid them.
        let dividers = Prefs.bool(Prefs.showDividers) || state == .all
        configure(divider, closed: state == .hidden, visible: dividers, glyph: "|")
        if let alwaysDivider {
            configure(alwaysDivider, closed: state != .all, visible: dividers, glyph: "‖")
        }
        if Self.isHosted {
            // Half the display beside the divider's half: whatever the app's
            // menus, nothing left of the divider fits. The arrow widens in
            // place, after the divider has already cleared the icons: it's
            // anchored on the right, so only blank bar moves. Taken off and
            // put back, it would fly in from the right.
            let length = state == .hidden ? Self.halfDisplay : NSStatusItem.squareLength
            if toggle.length != length {
                toggle.button?.image = nil
                toggle.length = length
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.widenTime) { [weak self] in
                    guard let self, self.toggle.length == length else { return }
                    self.drawArrow()
                }
            }
        }
    }

    /// The arrow, at the right end of its item however wide it is. While
    /// the item is still changing width it's left out: macOS would slide it
    /// along with the edge.
    private func drawArrow() {
        let symbol = NSImage(systemSymbolName: state == .hidden ? "chevron.compact.left" : "chevron.compact.right",
                             accessibilityDescription: nil)
        symbol?.isTemplate = true
        let width = toggle.length
        guard let symbol, width > Self.arrowWidth * 2 else {
            toggle.button?.image = symbol
            return
        }
        let image = NSImage(size: NSSize(width: width, height: symbol.size.height), flipped: false) { rect in
            symbol.draw(in: NSRect(x: rect.maxX - (Self.arrowWidth + symbol.size.width) / 2, y: 0,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        toggle.button?.image = image
    }

    /// How long macOS 27 takes to settle an item's new width.
    private static let widenTime: TimeInterval = 0.8
    /// The arrow's own width, NSStatusItem.squareLength once laid out.
    private static let arrowWidth: CGFloat = 22

    /// Changes an item's width on macOS 27 while it's off the bar for a
    /// moment. Changed in place, the bar animates the width and shoves the
    /// icons beside it sideways; put back, it's seated whole where it was.
    private func resize(_ item: NSStatusItem, to length: CGFloat) {
        guard item.length != length else { return }
        item.isVisible = false
        item.length = length
        item.isVisible = true
    }

    private func configure(_ item: NSStatusItem, closed: Bool, visible: Bool, glyph: String) {
        if Self.isHosted {
            resize(item, to: closed ? Self.halfDisplay : (visible ? Self.dividerLength : 0))
        } else {
            item.length = closed ? Self.closedLength : (visible ? Self.dividerLength : 0)
        }
        guard let button = item.button else { return }
        button.image = closed || !visible ? nil : Self.dividerImage(double: glyph == "‖")
        // Left enabled with no action: disabled, macOS 27 draws it too faint to find.
        button.appearsDisabled = false
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
            NSColor.black.withAlphaComponent(0.7).setFill()
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
        pendingLayout?.cancel()
        toggle.length = NSStatusItem.squareLength
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
