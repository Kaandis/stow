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
    private var pendingLayout: DispatchWorkItem?
    private var lastLayout = Date.distantPast
    /// How long macOS takes to fade icons in or out of the bar.
    private static let settleTime: TimeInterval = 0.45
    /// The divider position each set of spacers was seated beside.
    private var spacerBases: [String: Double] = [:]
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
        fillGeneration += 1
        // Showing everything is when you arrange, so dividers show then even
        // if you hid them.
        let dividers = Prefs.bool(Prefs.showDividers) || state == .all
        configure(divider, closed: state == .hidden, visible: dividers, glyph: "|")
        if let alwaysDivider {
            configure(alwaysDivider, closed: state != .all, visible: dividers, glyph: "‖")
        }
    }

    private func configure(_ item: NSStatusItem, closed: Bool, visible: Bool, glyph: String) {
        if closed && Self.isHosted {
            fill(beside: item)
        } else {
            // Spacers stay in place at no length, so the next hide only grows
            // them and nothing shifts first.
            if let name = item.autosaveName { spacers[name]?.forEach { $0.length = 0 } }
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
    /// Spacers are made once and kept at no length while icons show. Added
    /// at hide time, each new one would nudge the icons left before they
    /// fade; kept, hiding is only growing, and the icons simply fade.
    private func fill(beside divider: NSStatusItem) {
        // The room is measured from where the divider's group starts while
        // it's open; once closed, the last open measure stands in.
        guard let name = divider.autosaveName else { return }
        let isOpen = divider.length <= Self.dividerLength + 1
        if isOpen, let edge = clusterLeftEdge(of: divider) { openLeftEdges[name] = edge }
        let lengths = Self.fillLengths(leftEdge: openLeftEdges[name])
        let created = seatSpacers(beside: divider, count: lengths.count - 1)
        let generation = fillGeneration
        let grow = { [weak self] in
            guard let self, generation == self.fillGeneration else { return }
            for (item, length) in zip(self.spacers[name] ?? [], lengths.dropFirst()) { item.length = length }
            divider.length = lengths[0]
        }
        if created {
            whenSeated(spacers[name] ?? [], beside: divider, generation: generation, then: grow)
        } else {
            grow()
        }
    }

    /// Where the divider's group starts, while it's open: the left edge of
    /// its leftmost spacer, or of the divider itself. Nil if the bar hasn't
    /// laid them out (on another Space, say).
    private func clusterLeftEdge(of divider: NSStatusItem) -> CGFloat? {
        let items = [divider] + (divider.autosaveName.flatMap { spacers[$0] } ?? [])
        let edges = items.compactMap { item -> CGFloat? in
            guard let window = item.button?.window, window.isOnActiveSpace, window.frame.minX > 0 else { return nil }
            return window.frame.minX
        }
        return edges.min()
    }

    /// How long the divider and each spacer get when closing.
    ///
    /// The fill should cover just the room between the frontmost app's menus
    /// and the divider: then macOS files the icons into its overflow and they
    /// fade out, and back in when shown. Much more than that shoves them off
    /// the left of the screen and they slide back in instead. With
    /// Accessibility allowed, the menus are measured and the fill is that
    /// room plus a little; without it, the fill spans the whole display,
    /// which always hides but may slide. Each item stays under half the
    /// narrowest display, which macOS 27 requires.
    private static func fillLengths(leftEdge: CGFloat?) -> [CGFloat] {
        let (cap, count) = fillMetrics
        #if DEBUG
        // `-debugFill <points>` fills exactly that much instead, for testing.
        let forced = UserDefaults.standard.double(forKey: "debugFill")
        if forced > 0 { return split(forced, cap: cap) }
        #endif
        guard let leftEdge, let menusEnd = AppMenuMeasure.menusEnd(), leftEdge > menusEnd else {
            return Array(repeating: cap, count: count)
        }
        return split(leftEdge - menusEnd + fitMargin, cap: cap)
    }

    /// A little more than the measured room, so the last icon never squeezes in.
    private static let fitMargin: CGFloat = 40

    /// Fits the fill again when another app comes forward: its menus end
    /// somewhere else, so the room changed.
    func refit() {
        guard Self.isHosted, AppMenuMeasure.isAllowed, pendingLayout == nil else { return }
        fillGeneration += 1
        if state == .hidden { fill(beside: divider) }
        if state != .all, let alwaysDivider { fill(beside: alwaysDivider) }
    }

    /// Splits `total` points of filling into items no wider than `cap`, the
    /// divider first, allowing for the padding macOS adds around each.
    private static func split(_ total: CGFloat, cap: CGFloat) -> [CGFloat] {
        let slot = cap + hostedPadding
        let count = min(max(Int((total / slot).rounded(.up)), 1), 8)
        let each = min(max(total / CGFloat(count) - hostedPadding, 0), cap)
        return Array(repeating: each, count: count)
    }

    /// The largest length every display accepts, and how many items it
    /// takes at that length to span the widest display.
    private static var fillMetrics: (cap: CGFloat, count: Int) {
        let widths = NSScreen.screens.map(\.frame.width)
        let cap = ((widths.min() ?? 1000) / 2).rounded(.down) - hostedPadding
        let slot = cap + hostedPadding
        return (cap, min(max(Int(((widths.max() ?? 1000) / slot).rounded(.up)), 1), 8))
    }

    /// Makes sure `count` spacers sit just left of the divider, recreating
    /// them only when the count changed or the divider was dragged elsewhere.
    /// Returns whether new ones were made.
    @discardableResult
    private func seatSpacers(beside divider: NSStatusItem, count: Int) -> Bool {
        guard let name = divider.autosaveName else { return false }
        let base = UserDefaults.standard.double(forKey: Self.positionKey(name))
        if spacers[name]?.count == count && spacerBases[name] == base { return false }
        removeSpacers(beside: divider)
        spacerBases[name] = base
        guard count > 0 else { return false }
        spacers[name] = (1...count).map { index in
            let spacerName = "\(name).Spacer\(index)"
            UserDefaults.standard.set(base + Double(index) * 0.1, forKey: Self.positionKey(spacerName))
            let item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = spacerName
            item.button?.title = ""
            item.button?.isEnabled = false
            item.button?.setAccessibilityElement(false)
            return item
        }
        return true
    }

    /// Called when preferences change: if you ⌘-dragged a divider, its
    /// spacers follow it to the new place.
    func followDraggedDividers() {
        guard Self.isHosted else { return }
        for item in [divider] + (alwaysDivider.map { [$0] } ?? []) {
            guard let name = item.autosaveName, let current = spacers[name] else { continue }
            let base = UserDefaults.standard.double(forKey: Self.positionKey(name))
            guard spacerBases[name] != base else { continue }
            let length = current.first?.length ?? 0
            seatSpacers(beside: item, count: current.count)
            spacers[name]?.forEach { $0.length = length }
        }
    }

    /// Waits until new spacers sit right beside the divider in the bar, as
    /// their frames report, then calls `then`. Gives up waiting after about
    /// half a second and grows anyway.
    private func whenSeated(_ items: [NSStatusItem], beside divider: NSStatusItem, generation: Int,
                            attempt: Int = 0, then: @escaping () -> Void) {
        guard generation == fillGeneration else { return }
        let seated: Bool = {
            guard let dividerFrame = divider.button?.window?.frame, dividerFrame.width > 0 else { return false }
            return items.allSatisfy { item in
                guard let frame = item.button?.window?.frame, frame.width > 0 else { return false }
                return frame.maxX <= dividerFrame.minX + 1 && frame.maxX >= dividerFrame.minX - 40
            }
        }()
        if seated || attempt >= 20 {
            // One more beat so the bar has drawn them before everything grows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: then)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.whenSeated(items, beside: divider, generation: generation, attempt: attempt + 1, then: then)
            }
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
