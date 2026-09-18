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
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(settings.downloadFolder.displayPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { choosingFolder = true }
                }
            }
            Stepper(value: $settings.segmentCount, in: AppSettings.segmentRange) {
                LabeledContent("Connections per download", value: "\(settings.segmentCount)")
            }
            Stepper(value: $settings.maxConcurrentDownloads, in: AppSettings.concurrencyRange) {
                LabeledContent("Downloads at once", value: "\(settings.maxConcurrentDownloads)")
            }
            Section {
                Toggle("Look for links on the clipboard", isOn: $settings.detectClipboard)
            } footer: {
                Text("Off by default. When on, Downloader offers to add web links you copy while it is the frontmost app. It never adds them by itself.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        Form {
            LabeledContent("Speed limit") {
                HStack {
                    TextField("Speed limit", value: $settings.speedLimitKBps, format: .number, prompt: Text("0"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("KB/s")
                }
            }
            Text("Shared by all downloads. 0 means no limit. The limit is approximate for small files: the first part of a download can arrive before it takes hold.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Default user agent", text: $settings.defaultUserAgent, prompt: Text("System default"))
        }
        .formStyle(.grouped)
        .onChange(of: settings.speedLimitKBps) {
            let clamped = SpeedLimit.clamp(settings.speedLimitKBps)
            if clamped != settings.speedLimitKBps { settings.speedLimitKBps = clamped }
            Task { await model.applyEngineSettings() }
        }
    }
}
