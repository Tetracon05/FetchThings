import DownloadKit
import SwiftUI
import UniformTypeIdentifiers

struct AddDownloadSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var choosingFolder = false
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    linksEditor
                } header: {
                    Text("Links")
                } footer: {
                    Text(linkSummary)
                }

                Section("Save To") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.draft.folder.displayPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { choosingFolder = true }
                        }
                    }
                    Stepper(value: $model.draft.segmentCount, in: AppSettings.segmentRange) {
                        LabeledContent("Connections", value: "\(model.draft.segmentCount)")
                    }
                    Toggle("Add paused", isOn: $model.draft.startPaused)
                }

                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedFields
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 540)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.draft.folder = url }
        }
        .interactiveDismissDisabled(isAdding)
    }

    // MARK: Pieces

    private var linksEditor: some View {
        TextEditor(text: $model.draft.linksText)
            .font(.body.monospaced())
            .frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if model.draft.linksText.isEmpty {
                    Text("Paste links here, one per line")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Links to download")
    }

    @ViewBuilder
    private var advancedFields: some View {
        TextField("File name", text: $model.draft.filename, prompt: Text("Use the name the server gives"))
            .disabled(model.draft.links.count > 1)
        TextField("Referer", text: $model.draft.referer, prompt: Text("https://…"))
        TextField("User agent", text: $model.draft.userAgent, prompt: Text("Default"))
        TextField("Cookies", text: $model.draft.cookies, prompt: Text("name=value; other=value"))
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom headers")
            TextEditor(text: $model.draft.headersText)
                .font(.body.monospaced())
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Custom headers, one per line as Name: value")
            Text("One per line, as Name: value").font(.caption).foregroundStyle(.secondary)
        }
        TextField("User name", text: $model.draft.username)
        SecureField("Password", text: $model.draft.password)
        if model.draft.sendsCredentialsOverPlainHTTP {
            Label("These links use http, so the password is sent without encryption.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        TextField("Checksum", text: $model.draft.checksumText, prompt: Text("sha256:… or md5:…"))
        LabeledContent("Speed limit") {
            HStack {
                TextField("Speed limit", value: $model.draft.speedLimitKBps, format: .number, prompt: Text("0"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("KB/s (0 = unlimited)").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addTitle) { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.draft.links.isEmpty || isAdding)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var linkSummary: String {
        let count = model.draft.links.count
        switch count {
        case 0: return "One link per line. You can also drop links or a .txt file onto the window."
        case 1: return "1 link"
        default: return "\(count) links"
        }
    }

    private var addTitle: String {
        let count = model.draft.links.count
        return count > 1 ? "Add \(count) Downloads" : "Add Download"
    }

    // MARK: Adding

    private func add() {
        errorText = nil
        let requests: [NewDownload]
        do {
            requests = try model.draft.makeRequests()
        } catch {
            errorText = error.localizedDescription
            return
        }
        isAdding = true
        Task {
            let outcome = await model.add(requests)
            isAdding = false
            if outcome.failures.isEmpty {
                dismiss()
            } else {
                // Keep only what failed, so adding again cannot duplicate what went through.
                model.draft.linksText = outcome.failedLinks.map(\.absoluteString).joined(separator: "\n")
                errorText = outcome.failures.joined(separator: "\n")
            }
        }
    }
}
