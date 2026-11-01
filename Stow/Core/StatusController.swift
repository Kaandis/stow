import AppKit

/// Stow's own menu bar items, right to left: the toggle, the divider that
/// closes off the Hidden section, and (when turned on) the divider for
/// Always Hidden.
///
/// Hiding a section is making sure nothing to the left of its divider fits,
/// and macOS leaves those icons out of the bar. Before macOS 27 the divider
/// itself widens past the screen. macOS 27 discards any item wider than half
/// its display and animates width changes, so there blank spacers, each under
/// that cap and already full width, are added right beside the divider and
/// taken away to show the icons again. It's all public `NSStatusItem` API,
/// and nothing runs while the bar sits still.
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
    private var pendingLayout: DispatchWorkItem?
    private var lastLayout = Date.distantPast
    /// How long macOS takes to fade icons in or out of the bar.
    private static let settleTime: TimeInterval = 0.45
    /// The divider position each set of spacers was seated beside.
    private var spacerBases: [String: Double] = [:]
    /// The position spacers are seated at beside each divider, once found by
    /// trying (see `checkSeating`), and the search for it while it's on.
    private var seats: [String: Double] = [:]
    private var seatSearch: [String: (low: Double?, high: Double?, tries: Int)] = [:]
    /// Where each divider's group started the last time it was open.
    private var openLeftEdges: [String: CGFloat] = [:]
    private var activationToken: NSObjectProtocol?

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
        // Spacers left behind by a crash would come back as blank gaps.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(Self.positionKey("Stow.")) && key.contains(".Spacer") {
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

        if let button = toggle.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "Stow"))
        }
        divider.button?.setAccessibilityLabel(String(localized: "Stow divider"))
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        }
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
    /// On macOS 27 the Always Hidden section can only be sized right with
    /// the app menus measured; filled blind it overflows itself and leaves
    /// the system's overflow arrow showing for nothing.
    static var canUseAlwaysHidden: Bool { !isHosted || AppMenuMeasure.isAllowed }

    func applySettings() {
        let wantsAlwaysHidden = Prefs.bool(Prefs.alwaysHiddenEnabled) && Self.canUseAlwaysHidden
        if wantsAlwaysHidden, alwaysDivider == nil {
            // It starts at the far left, so nothing is always hidden until you
            // ⌘-drag icons past it. Everything shows so you can see it at once.
            Self.seedPosition("Stow.AlwaysDivider", 100_000)
            let item = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
            item.autosaveName = "Stow.AlwaysDivider"
            item.button?.setAccessibilityLabel(String(localized: "Stow Always Hidden divider"))
            alwaysDivider = item
            state = .all
        } else if !wantsAlwaysHidden, let item = alwaysDivider {
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

    /// The arrow answers at once; the bar follows. While macOS is still
    /// animating the last change, a new one waits for it to finish and only
    /// the latest state is applied. Changed mid-animation, the bar throws the
    /// icons to the far left and slides them back.
    private func apply(_ new: State, animated: Bool) {
        state = new
        toggle.button?.image = NSImage(systemSymbolName: new == .hidden ? "chevron.compact.left" : "chevron.compact.right",
                                       accessibilityDescription: nil)
        toggle.button?.image?.isTemplate = true
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
    }

    private func configure(_ item: NSStatusItem, closed: Bool, visible: Bool, glyph: String) {
        if Self.isHosted {
            // On macOS 27 the divider never changes width; closing adds the
            // spacers beside it and opening takes them away.
            item.length = visible ? Self.dividerLength : 0
            if closed { close(item) } else { removeSpacers(beside: item) }
        } else {
            item.length = closed ? Self.closedLength : (visible ? Self.dividerLength : 0)
        }
        guard let button = item.button else { return }
        button.image = closed || !visible ? nil : Self.dividerImage(double: glyph == "‖")
        // Left enabled with no action: disabled, macOS 27 draws it too faint to find.
        button.appearsDisabled = false
    }

    // MARK: macOS 27 filling

    /// Closes `divider` on macOS 27 by placing blank spacers, already at full
    /// width, right beside it. Nothing to their left fits any more, so macOS
    /// files those icons into its overflow and they fade out where they are.
    ///
    /// Growing an item instead would be animated by the menu bar: the icons
    /// would first be shoved left and only fade once the item grew enough,
    /// sometimes one, sometimes the other. Added whole, they always fade.
    /// Taking the spacers away lets the icons slide back in from the left,
    /// every time the same way.
    private func close(_ divider: NSStatusItem) {
        guard let name = divider.autosaveName else { return }
        if spacers[name] == nil, let edge = clusterLeftEdge(of: divider) { openLeftEdges[name] = edge }
        let lengths = divider === alwaysDivider ? Self.measuredLengths(leftEdge: openLeftEdges[name]) : Self.spanLengths
        let base = UserDefaults.standard.double(forKey: Self.positionKey(name))
        if let current = spacers[name], current.count == lengths.count, spacerBases[name] == base {
            zip(current, lengths).forEach { $0.length = $1 }
            return
        }
        removeSpacers(beside: divider)
        spacerBases[name] = base
        // Seated just left of wherever the divider is now, so they move with
        // it when you ⌘-drag the divider elsewhere.
        let seat = seats[name] ?? (UserDefaults.standard.object(forKey: Self.seatKey(name)) as? Double) ?? base + 0.1
        seats[name] = seat
        spacers[name] = lengths.enumerated().map { index, length in
            let spacerName = "\(name).Spacer\(index + 1)"
            UserDefaults.standard.set(seat + Double(index) * 0.01, forKey: Self.positionKey(spacerName))
            let item = NSStatusBar.system.statusItem(withLength: length)
            item.autosaveName = spacerName
            item.button?.title = ""
            item.button?.isEnabled = false
            item.button?.setAccessibilityElement(false)
            return item
        }
        checkSeating(of: divider)
    }

    /// Once ⌘-dragged, macOS 27 keeps its own record of where Stow's items
    /// sit and never writes it back, so the divider's position in Stow's
    /// preferences can be stale. Spacers seated by it can land anywhere,
    /// even right of the arrow, pushing Stow's own items off with the rest.
    /// So after the bar lays them out, Stow checks the first spacer sits
    /// right against the divider; if not, it narrows down the position that
    /// does, a step per layout, and remembers it.
    private func checkSeating(of divider: NSStatusItem) {
        guard let name = divider.autosaveName else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime) { [weak self] in
            guard let self, let first = self.spacers[name]?.first, let seat = self.seats[name],
                  let spacer = first.button?.window?.frame, let edge = divider.button?.window?.frame else { return }
            var search = self.seatSearch[name] ?? (nil, nil, 0)
            if edge.minY >= 0, spacer.minY >= 0, spacer.maxX > edge.minX + 2 {
                search.low = seat        // right of the divider: seat further left
            } else if edge.minY >= 0, spacer.minY >= 0, spacer.maxX < edge.minX - 2 {
                search.high = seat       // icons left between them: seat closer
            } else if edge.minY < 0, spacer.minY >= 0 {
                search.low = seat        // the divider itself was pushed off
            } else {
                // Right against it, or too wide to fit at all (a narrow
                // display), which hides everything left of it just the same.
                if search.tries > 0 {
                    UserDefaults.standard.set(seat, forKey: Self.seatKey(name))
                    log.notice("Spacers seated at \(seat)")
                }
                self.seatSearch[name] = nil
                return
            }
            search.tries += 1
            guard search.tries <= 12 else {
                log.error("Couldn't seat the spacers beside \(name); showing instead")
                self.seatSearch[name] = nil
                self.apply(.shown, animated: false)
                return
            }
            let step = 16 * pow(2, Double(search.tries - 1))
            switch (search.low, search.high) {
            case let (low?, high?): self.seats[name] = (low + high) / 2
            case let (low?, nil): self.seats[name] = low + step
            case let (nil, high?): self.seats[name] = max(high - step, 0)
            default: return
            }
            self.seatSearch[name] = search
            self.removeSpacers(beside: divider)
            self.close(divider)
        }
    }

    private static func seatKey(_ autosaveName: String) -> String { "seat \(autosaveName)" }

    /// Where the divider's group starts while it's open. Nil if the bar
    /// hasn't laid it out (on another Space, say).
    private func clusterLeftEdge(of divider: NSStatusItem) -> CGFloat? {
        guard let window = divider.button?.window, window.isOnActiveSpace, window.frame.minX > 0 else { return nil }
        return window.frame.minX
    }

    /// Spacers spanning the widest display: whatever the app's menus, nothing
    /// left of them fits. Each stays under half the narrowest display, which
    /// macOS 27 requires.
    private static var spanLengths: [CGFloat] {
        let widths = NSScreen.screens.map(\.frame.width)
        let cap = ((widths.min() ?? 1000) / 2).rounded(.down) - hostedPadding
        let count = min(max(Int(((widths.max() ?? 1000) / (cap + hostedPadding)).rounded(.up)), 1), 8)
        return Array(repeating: cap, count: count)
    }

    /// Spacers for the Always Hidden section while the rest shows: just the
    /// room between the app's menus and the divider, measured through
    /// Accessibility, so only the icons left of the divider overflow and the
    /// spacers themselves stay put. Spanning the display, they'd overflow
    /// too and leave the system's overflow arrow showing for nothing.
    private static func measuredLengths(leftEdge: CGFloat?) -> [CGFloat] {
        guard let leftEdge, let menusEnd = AppMenuMeasure.menusEnd(), leftEdge > menusEnd + 20 else { return spanLengths }
        let total = leftEdge - menusEnd + fitMargin
        let cap = ((NSScreen.screens.map(\.frame.width).min() ?? 1000) / 2).rounded(.down) - hostedPadding
        let count = min(max(Int((total / (cap + hostedPadding)).rounded(.up)), 1), 8)
        return Array(repeating: min(max(total / CGFloat(count) - hostedPadding, 0), cap), count: count)
    }

    /// A little more than the measured room, so the last icon never squeezes in.
    private static let fitMargin: CGFloat = 24

    /// Fits the Always Hidden spacers again when another app comes forward:
    /// its menus end somewhere else, so the room changed.
    func refit() {
        guard Self.isHosted, AppMenuMeasure.isAllowed, pendingLayout == nil,
              state == .shown, let alwaysDivider else { return }
        close(alwaysDivider)
    }

    /// Called when preferences change: if you ⌘-dragged a closed divider,
    /// its spacers follow it to the new place.
    func followDraggedDividers() {
        guard Self.isHosted else { return }
        for item in [divider] + (alwaysDivider.map { [$0] } ?? []) {
            guard let name = item.autosaveName, spacers[name] != nil else { continue }
            if spacerBases[name] != UserDefaults.standard.double(forKey: Self.positionKey(name)) { close(item) }
        }
    }

    private func removeSpacers(beside divider: NSStatusItem) {
        guard let name = divider.autosaveName else { return }
        spacerBases[name] = nil
        guard let items = spacers.removeValue(forKey: name) else { return }
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
        if Self.isHosted && !AppMenuMeasure.isAllowed {
            let allow = menu.addItem(withTitle: String(localized: "Allow Accessibility for Always Hidden…"),
                                     action: #selector(allowAccessibility), keyEquivalent: "")
            allow.target = self
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
    @objc private func allowAccessibility() {
        AppMenuMeasure.requestPermission()
        AppMenuMeasure.openSettings()
    }
    @objc private func openGuide() { onShowGuide?() }

    /// Puts every icon back before Stow quits, so nothing is left pushed away.
    func restoreForQuit() {
        pendingLayout?.cancel()
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
