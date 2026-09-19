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

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 18) {
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
    }
}

private struct NetworkSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 18) {
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
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(width: 230)
                        .fieldBackground()
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func modeTile(_ mode: SpeedMode, limit: Binding<Int>) -> some View {
        SettingTile(symbol: mode.symbol, tint: mode.color, title: Text(mode.title)) {
            HStack(spacing: 8) {
                TextField("Speed limit", value: limit, format: .number.grouping(.never), prompt: Text("1"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 90)
                    .fieldBackground()
                    .onChange(of: limit.wrappedValue) {
                        // Zero would mean unlimited, and a huge number would overflow: keep it in range.
                        let clamped = AppSettings.limit(limit.wrappedValue, default: 1)
                        if clamped != limit.wrappedValue { limit.wrappedValue = clamped }
                        Task { await model.applyEngineSettings() }
                    }
                Text("KB/s").foregroundStyle(.secondary)
            }
        }
    }
}
