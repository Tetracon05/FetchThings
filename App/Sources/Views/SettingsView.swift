import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings(model: model)
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var choosingFolder = false
    @State private var showRelaunchPrompt = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 18) {
            TileSection(
                title: Text("Language"),
                footer: Text("FetchThings must relaunch to change its language.")
            ) {
                SettingTile(symbol: "globe", tint: .blue, title: Text("Language")) {
                    Picker("Language", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
            }
            TileSection(title: Text("Downloads")) {
                SettingTile(
                    symbol: "folder.fill", tint: .blue, title: Text("Download folder"),
                    detail: Text(settings.downloadFolder.displayPath)
                ) {
                    Button("Choose…") { choosingFolder = true }
                        .glassButton()
                }
                SettingTile(
                    symbol: "arrow.triangle.branch", tint: .purple, title: Text("Connections per download"),
                    detail: Text("Each file is fetched in this many parts at once.")
                ) {
                    StepperControl(title: "Connections per download", value: $settings.segmentCount, range: AppSettings.segmentRange)
                }
                SettingTile(
                    symbol: "square.stack.3d.down.right.fill", tint: .teal, title: Text("Downloads at once"),
                    detail: Text("The rest wait in the queue.")
                ) {
                    StepperControl(title: "Downloads at once", value: $settings.maxConcurrentDownloads, range: AppSettings.concurrencyRange)
                }
            }
            TileSection(
                title: Text("Clipboard"),
                footer: Text("Off by default. When on, FetchThings offers to add web links you copy while it is the frontmost app. It never adds them by itself.")
            ) {
                SettingTile(symbol: "doc.on.clipboard.fill", tint: .orange, title: Text("Look for links on the clipboard")) {
                    Toggle("Look for links on the clipboard", isOn: $settings.detectClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(.vertical, 8)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { settings.downloadFolder = url }
        }
        .onChange(of: settings.maxConcurrentDownloads) { Task { await model.applyEngineSettings() } }
        .onChange(of: settings.language) { showRelaunchPrompt = true }
        .confirmationDialog(
            Text("Relaunch FetchThings to use \(settings.language.title)?"),
            isPresented: $showRelaunchPrompt
        ) {
            Button("Relaunch Now") { model.relaunch() }
            Button("Later", role: .cancel) {}
        }
    }
}

private struct NetworkSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 18) {
            TileSection(
                title: Text("Connection"),
                footer: Text("When the Mac is offline, downloads wait and continue by themselves.")
            ) {
                SettingTile(
                    symbol: "personalhotspot", tint: .indigo, title: Text("Pause on a Personal Hotspot or cellular"),
                    detail: Text("Downloads wait unless you choose Download Anyway.")
                ) {
                    Toggle("Pause on a Personal Hotspot or cellular", isOn: $settings.pauseOnExpensiveNetwork)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingTile(
                    symbol: "leaf.fill", tint: .green, title: Text("Respect Low Data Mode"),
                    detail: Text("Downloads wait on a network that is in Low Data Mode.")
                ) {
                    Toggle("Respect Low Data Mode", isOn: $settings.pauseOnConstrainedNetwork)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            TileSection(
                title: Text("Speed modes"),
                footer: Text("Choose a mode with the button at the bottom of the sidebar. It limits all downloads together. The limit is approximate for small files: the first part of a download can arrive before it takes hold.")
            ) {
                modeTile(.low, limit: $settings.lowLimitKBps)
                modeTile(.normal, limit: $settings.normalLimitKBps)
                SettingTile(symbol: SpeedMode.high.symbol, tint: SpeedMode.high.color, title: Text(SpeedMode.high.title)) {
                    Text("Unlimited").foregroundStyle(.secondary)
                }
            }
            TileSection(title: Text("Requests")) {
                SettingTile(symbol: "person.text.rectangle.fill", tint: .gray, title: Text("Default user agent")) {
                    TextField("Default user agent", text: $settings.defaultUserAgent, prompt: Text("System default"))
                        .insetField(width: 230)
                }
            }
        }
        .padding(.vertical, 8)
        .onChange(of: settings.pauseOnExpensiveNetwork) { Task { await model.applyEngineSettings() } }
        .onChange(of: settings.pauseOnConstrainedNetwork) { Task { await model.applyEngineSettings() } }
    }

    private func modeTile(_ mode: SpeedMode, limit: Binding<Int>) -> some View {
        SettingTile(symbol: mode.symbol, tint: mode.color, title: Text(mode.title)) {
            HStack(spacing: 8) {
                TextField("Speed limit", value: limit, format: .number.grouping(.never), prompt: Text("1"))
                    .insetField(width: 90, alignment: .trailing)
                    // `AppSettings` keeps the number in range (zero would mean unlimited, a huge one would overflow).
                    .onChange(of: limit.wrappedValue) { Task { await model.applyEngineSettings() } }
                Text("KB/s").foregroundStyle(.secondary)
            }
        }
    }
}
