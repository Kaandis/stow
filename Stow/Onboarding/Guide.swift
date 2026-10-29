import AppKit
import HarborKit
import SwiftUI

/// The welcome window: how to choose what Stow hides, shown once and again
/// from the menu.
@MainActor
enum Guide {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.background)
            window.title = String(localized: "Welcome to Stow")
            window.contentView = NSHostingView(rootView: GuideView { close() })
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        UserDefaults.standard.set(true, forKey: Prefs.hasCompletedOnboarding)
        window?.close()
    }
}

struct GuideView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tuck menu bar icons away")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.ink)
            Text("Stow keeps the icons you rarely need out of the way, and brings them back with a click.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            MenuBarDemo()
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "Hold ⌘ and drag icons across the thin divider: left of it tucks away, right of Stow’s arrow stays in view.")
                Step(number: 2, text: "Click Stow’s arrow to tuck everything left of the divider away. Click again to bring it back.")
                Step(number: 3, text: "⌥-click the arrow for the Always Hidden icons, if you turned them on. Right-click it for settings.")
            }
            .padding(.top, 24)

            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                HStack(alignment: .center, spacing: 12) {
                    Text("Optional: allow Accessibility so Stow can see where app menus end. Hidden icons then fade out and back in instead of sliding. Stow reads nothing else.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !AppMenuMeasure.isAllowed {
                        Button("Allow…") {
                            AppMenuMeasure.requestPermission()
                            AppMenuMeasure.openSettings()
                        }
                        .buttonStyle(HarborButtonStyle(prominent: false))
                    }
                }
                .padding(.top, 18)
            }

            Spacer(minLength: 20)
            HStack {
                Spacer()
                Button("Got It", action: onDone)
                    .buttonStyle(HarborButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 580, height: 560)
        .background(Theme.background)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.background)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.ink))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small menu bar acting out the two steps on a loop: an icon is ⌘-dragged
/// past the divider, then the arrow tucks it away and brings it back. It
/// plays three times while the window is open, and holds still with Reduce
/// Motion.
private struct MenuBarDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private let spring = Animation.spring(response: 0.5, dampingFraction: 1)
    private let iconSpacing: CGFloat = 30

    var body: some View {
        // Icons left to right. "message" starts right of the divider and is
        // dragged left of it in phase 1.
        let dragged = phase >= 1
        let tucked = phase == 2 || phase == 3
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    ForEach(["cloud.sun.fill", "music.note", "paperplane.fill"], id: \.self) { icon($0) }
                    if dragged { icon("message.fill").transition(.opacity) }
                }
                .opacity(tucked ? 0 : 1)
                .offset(x: tucked ? -40 : 0)
                .frame(width: 160, alignment: .trailing)
                .clipped()

                Capsule().fill(Theme.ink3.opacity(0.6)).frame(width: 1.5, height: 15)
                    .padding(.horizontal, 10)
                    .opacity(tucked ? 0 : 1)

                Image(systemName: tucked ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .scaleEffect(phase == 2 || phase == 4 ? 0.85 : 1)
                    .frame(width: 22)

                HStack(spacing: 14) {
                    if !dragged { icon("message.fill").transition(.opacity) }
                    icon("wifi")
                    icon("battery.75percent")
                    Text("9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                }
                .padding(.leading, 14)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 44)
        .overlay(alignment: .topTrailing) {
            if phase == 1 {
                Keycap(key: "⌘")
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("An icon dragged left of the divider, then tucked away by Stow’s arrow."))
        .task {
            guard !reduceMotion else { phase = 1; return }
            // Three rounds are enough to follow; then it rests, costing nothing.
            for _ in 0..<3 where !Task.isCancelled {
                for next in [1, 2, 3, 4, 0] {
                    try? await Task.sleep(for: .seconds(next == 0 ? 1.2 : 1.6))
                    withAnimation(spring) { phase = next }
                }
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(width: 16)
    }
}
