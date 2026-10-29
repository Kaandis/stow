import AppKit
import Carbon.HIToolbox

/// A global shortcut that toggles the hidden icons. Carbon's hot keys need
/// no permission and cost nothing until pressed.
@MainActor
final class ToggleShortcut {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// The presets Settings offers, as (key code, Carbon modifiers).
    private static let presets: [String: (UInt32, UInt32)] = [
        "controlOptionS": (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey)),
        "optionCommandB": (UInt32(kVK_ANSI_B), UInt32(optionKey | cmdKey)),
    ]

    func apply(_ preset: String) {
        unregister()
        guard let (key, modifiers) = Self.presets[preset] else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let shortcut = Unmanaged<ToggleShortcut>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.onPress?() }
            return noErr
        }, 1, &type, refcon, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354_4f57), id: 1) // "STOW"
        RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}

/// Reveals the icons when the pointer rests on the menu bar. Off by default:
/// it's the one feature that has to follow the pointer, so it only listens
/// while turned on.
@MainActor
final class HoverReveal {
    var onDwell: (() -> Void)?
    private var monitor: Any?
    private var dwell: DispatchWorkItem?

    func setEnabled(_ enabled: Bool) {
        if enabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.moved() }
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            dwell?.cancel()
        }
    }

    private func moved() {
        guard MenuBarState.isPointerOnMenuBar else {
            dwell?.cancel()
            dwell = nil
            return
        }
        guard dwell == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwell = nil
            if MenuBarState.isPointerOnMenuBar { self.onDwell?() }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
