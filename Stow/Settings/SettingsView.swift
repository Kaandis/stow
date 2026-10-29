import HarborKit
import ServiceManagement
import SwiftUI

/// Stow's own settings window. With Harbor installed the same settings show
/// there too (see `settings-schema.json`); everything is a plain UserDefaults key.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.hideDelay) private var hideDelay = 15.0
    @AppStorage(Prefs.revealOnHover) private var revealOnHover = false
    @AppStorage(Prefs.showDividers) private var showDividers = true
    @AppStorage(Prefs.alwaysHiddenEnabled) private var alwaysHidden = false
    @AppStorage(Prefs.toggleShortcut) private var shortcut = "off"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage.current
    private let launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }

            Section {
                Picker("Hide again after", selection: $hideDelay) {
                    Text("5 seconds").tag(5.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("Never").tag(0.0)
                }
                Toggle("Show when the pointer rests on the menu bar", isOn: $revealOnHover)
                Picker("Shortcut", selection: $shortcut) {
                    Text("None").tag("off")
                    Text("⌃⌥S").tag("controlOptionS")
                    Text("⌥⌘B").tag("optionCommandB")
                }
            } header: {
                Text("Showing hidden icons")
            }

            Section {
                Toggle("Show dividers while icons are showing", isOn: $showDividers)
                Toggle("Always Hidden section", isOn: $alwaysHidden)
                Text("A second divider for icons that stay hidden until you ⌥-click Stow’s arrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("How to Use Stow…") { Guide.show() }
            } header: {
                Text("Sections")
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: language) { _, language in language.apply() }
                if language != launchLanguage {
                    HStack {
                        Text("Restart Stow to switch languages.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Stow")
                .font(.system(size: 22, weight: .bold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Free and open source. Part of the Harbor apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("Website", destination: URL(string: "https://kaandis.github.io/stow/")!)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}
