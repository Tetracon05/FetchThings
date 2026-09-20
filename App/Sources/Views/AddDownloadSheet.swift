import DownloadKit
import SwiftUI
import UniformTypeIdentifiers

/// The Add Download sheet, built out of Liquid Glass: a hero header, a glass "well" that takes pasted links and turns each
/// one into a card, tiles for the options, and an Advanced panel that morphs open out of its own button.
struct AddDownloadSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var choosingFolder = false
    @State private var isAdding = false
    @State private var errorText: String?
    @State private var isDropTargeted = false
    @State private var pasteNote: String?
    /// What is being typed or pasted; links in it become cards (`commitPending`) and it clears.
    @State private var pending = ""
    @State private var freeSpace: String?
    /// How tall the scrolling middle of the sheet would be in full, so it can be that tall up to a limit and scroll beyond.
    @State private var middleHeight: CGFloat = 400
    /// The height of the window the sheet hangs from, which limits how tall the sheet may be (see `middleLimit`).
    @State private var parentHeight: CGFloat = 640
    @FocusState private var linksFocused: Bool
    @Namespace private var glassNamespace

    var body: some View {
        VStack(spacing: 16) {
            header
            middle
            if let errorText { errorBanner(errorText) }
            footer
        }
        .padding(22)
        .frame(width: 560)
        // Translucent, so the glass surfaces have something to refract.
        .presentationBackground(.regularMaterial)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.draft.folder = url }
        }
        .interactiveDismissDisabled(isAdding)
        .animation(.smooth(duration: 0.3), value: model.draft.links)
        .animation(.smooth(duration: 0.3), value: errorText)
        .task(id: model.draft.folder) { freeSpace = Self.freeSpaceText(at: model.draft.folder) }
        // What was dropped on the sheet held no links: say so here, where the user is looking.
        .onChange(of: model.sheetNote) { _, text in
            guard let text else { return }
            note(text)
            model.sheetNote = nil
        }
        .background(ParentHeightReader { parentHeight = $0 })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 27, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: readyCount)
                .frame(width: 54, height: 54)
                .glassSurface(.circle, tint: Color.accentColor.opacity(0.8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Downloads")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
    }

    /// Everything between the header and the footer. It scrolls when it is taller than fits (many links, or the Advanced
    /// panel open), so the sheet stays inside a window of ordinary size instead of hanging out of it.
    private var middle: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    linksWell
                    optionTiles
                    advancedSection.id("advanced")
                }
                // Room around the glass inside the scroll view, whose edge would otherwise cut off its rim and shadow;
                // the scroll view is widened by the same amount so the content keeps its place.
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { middleHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(-6)
            .frame(minHeight: 140, idealHeight: min(middleHeight, middleLimit), maxHeight: min(middleHeight, middleLimit))
            .onChange(of: showAdvanced) { _, shown in
                guard shown else { return }
                withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo("advanced", anchor: .bottom) }
            }
        }
    }

    /// The tallest the scrolling middle may be: what is left of the parent window after the toolbar, the header, the
    /// footer and the sheet's padding, so a sheet in a small window does not hang out of it and one in a big window
    /// shows everything.
    private var middleLimit: CGFloat {
        min(max(parentHeight - 250, 260), 640)
    }

    private var subtitle: String {
        let count = readyCount
        return count == 0 ? String(localized: "Paste links or drop a text file to begin") : String(localized: "\(count) links")
    }

    // MARK: Links

    /// Where the links go: a glass well with the text field, a Paste button, and a card for each link it finds. A file,
    /// a link or text dragged onto it is added to the list.
    private var linksWell: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    // The line for the next link. Pasted links (one or many) turn into cards at once, a typed one when
                    // Return is pressed, and Return on an empty line starts the downloads.
                    TextField(
                        "Links", text: $pending,
                        prompt: Text(model.draft.links.isEmpty ? "Paste links here, one per line" : "Add another link…"),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .lineLimit(1...3)
                    .focused($linksFocused)
                    .padding(.top, 3)
                    .onChange(of: pending) { old, new in
                        // A paste brings a whole address in one go, and Option-Return adds a line break.
                        if PasteDetection.looksLikePaste(from: old, to: new) { commitPending() }
                    }
                    .onSubmit(submitField)
                    .accessibilityLabel("Links to download")
                    Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
                        .labelStyle(.titleAndIcon)
                        .glassButton()
                        .controlSize(.small)
                        .help("Add the links on the clipboard")
                }
                if model.draft.links.isEmpty {
                    emptyHint
                } else {
                    linkCards
                }
            }
            .padding(14)
            .glassSurface(
                .rect(cornerRadius: 24, style: .continuous),
                tint: isDropTargeted ? Color.accentColor.opacity(0.35) : (linksFocused ? Color.accentColor.opacity(0.10) : nil)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.9 : 0), lineWidth: 2)
            }
            .animation(.smooth(duration: 0.2), value: isDropTargeted)
            .animation(.smooth(duration: 0.2), value: linksFocused)
            .onDrop(of: [.url, .plainText], delegate: IncomingDropDelegate(model: model, isTargeted: $isDropTargeted))

            Text(pasteNote ?? outsideNote ?? String(localized: "Press Return to add a link, and Return again to start the downloads."))
                .font(.caption)
                .foregroundStyle(pasteNote == nil ? Color.secondary : Color.orange)
                .padding(.horizontal, 8)
        }
    }

    private var emptyHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .symbolRenderingMode(.hierarchical)
            Text("Drop links or a text file here")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityHidden(true)
    }

    /// One card per link.
    private var linkCards: some View {
        LazyVStack(spacing: 6) {
            ForEach(model.draft.links.map(LinkSummary.init)) { link in
                LinkCard(link: link) {
                    withAnimation(.smooth(duration: 0.25)) { model.draft.remove(link.url) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    /// Turns the links in the field into cards and clears it. False when there is no link in it.
    @discardableResult
    private func commitPending() -> Bool {
        let found = LinkParser.urls(in: pending)
        guard !found.isEmpty else { return false }
        withAnimation(.smooth(duration: 0.3)) { model.draft.append(found) }
        pending = ""
        pasteNote = nil
        return true
    }

    /// Return in the field: add the link being typed, or, when there is nothing to add, start the downloads.
    private func submitField() {
        if commitPending() { return }
        if pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if readyCount > 0, !isAdding { add() }
        } else {
            note(String(localized: "That doesn’t look like an http or https link."))
        }
    }

    /// Said under the well while a link that came from outside sits beside cookies or a login: it will not get them.
    private var outsideNote: String? {
        guard model.draft.hasSecrets, !model.draft.linksWithoutSecrets.isEmpty else { return nil }
        return String(localized: "Links that came from outside this window are sent without the cookies, headers or login you entered.")
    }

    /// How many downloads Add would make: the cards, plus a link that is typed but not yet entered.
    private var readyCount: Int {
        let known = Set(model.draft.links)
        return model.draft.links.count + LinkParser.urls(in: pending).filter { !known.contains($0) }.count
    }

    /// A short remark under the well that goes away by itself.
    private func note(_ text: String) {
        pasteNote = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if pasteNote == text { pasteNote = nil }
        }
    }

    private func pasteFromClipboard() {
        let found = LinkParser.urls(in: NSPasteboard.general.string(forType: .string) ?? "")
        if found.isEmpty {
            note(String(localized: "Copy an http or https link first."))
        } else {
            pasteNote = nil
            withAnimation(.smooth(duration: 0.3)) { model.draft.append(found) }
        }
    }

    // MARK: Options

    private var optionTiles: some View {
        GlassGroup(spacing: 4) {
            VStack(spacing: 12) {
                folderTile
                HStack(spacing: 12) {
                    connectionsTile
                    pausedTile
                }
            }
        }
    }

    private var folderTile: some View {
        HStack(spacing: 12) {
            IconChip(symbol: "folder.fill", tint: .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.draft.folder.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(model.draft.folder.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let freeSpace {
                    Text(freeSpace)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Change…") { choosingFolder = true }
                .glassButton()
        }
        .tile()
        .accessibilityElement(children: .combine)
    }

    private var connectionsTile: some View {
        let range = AppSettings.segmentRange
        return HStack(spacing: 10) {
            IconChip(symbol: "arrow.triangle.branch", tint: .purple)
            VStack(alignment: .leading, spacing: 0) {
                Text("Connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(model.draft.segmentCount)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(model.draft.segmentCount)))
            }
            Spacer(minLength: 4)
            StepButton(symbol: "minus", enabled: model.draft.segmentCount > range.lowerBound) { step(-1) }
            StepButton(symbol: "plus", enabled: model.draft.segmentCount < range.upperBound) { step(1) }
        }
        .tile()
        .animation(.snappy(duration: 0.2), value: model.draft.segmentCount)
        // One adjustable control for VoiceOver, like a stepper.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connections")
        .accessibilityValue("\(model.draft.segmentCount)")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 1 : -1)
        }
    }

    private func step(_ delta: Int) {
        let range = AppSettings.segmentRange
        model.draft.segmentCount = min(max(model.draft.segmentCount + delta, range.lowerBound), range.upperBound)
    }

    private var pausedTile: some View {
        HStack(spacing: 10) {
            IconChip(symbol: "pause.fill", tint: .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("Add paused")
                    .font(.callout.weight(.semibold))
                Text("Waits until you start it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("Add paused", isOn: $model.draft.startPaused)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .tile()
    }

    // MARK: Advanced

    /// A button that, when pressed, morphs into the panel of advanced options (and back). A plain button rather than a
    /// `DisclosureGroup`, which did not respond to clicks or VoiceOver inside a grouped form.
    private var advancedSection: some View {
        GlassGroup(spacing: 8) {
            if showAdvanced {
                VStack(spacing: 6) {
                    advancedHeader
                    advancedFields
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                }
                .glassSurface(.rect(cornerRadius: 24, style: .continuous))
                .glassMorph(id: "advanced", in: glassNamespace)
            } else {
                advancedHeader
                    .glassSurface(.rect(cornerRadius: 20, style: .continuous), interactive: true)
                    .glassMorph(id: "advanced", in: glassNamespace)
            }
        }
    }

    private var advancedHeader: some View {
        Button {
            withAnimation(.smooth(duration: 0.4)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 12) {
                IconChip(symbol: "slider.horizontal.3", tint: .gray)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Advanced")
                        .font(.callout.weight(.semibold))
                    Text("File name, headers, login, checksum and more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showAdvanced ? 180 : 0))
            }
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(showAdvanced ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the file name, headers, login and other options")
    }

    @ViewBuilder
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdvancedField(title: "File name", text: $model.draft.filename, prompt: "Use the name the server gives")
                .disabled(model.draft.links.count > 1)
                .opacity(model.draft.links.count > 1 ? 0.5 : 1)
            AdvancedField(title: "Referer", text: $model.draft.referer, prompt: "https://…")
            AdvancedField(title: "User agent", text: $model.draft.userAgent, prompt: "Default")
            AdvancedField(title: "Cookies", text: $model.draft.cookies, prompt: "name=value; other=value")
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom headers")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.draft.headersText)
                    .font(.body.monospaced())
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .fieldBackground()
                    .accessibilityLabel("Custom headers, one per line as Name: value")
                Text("One per line, as Name: value")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                AdvancedField(title: "User name", text: $model.draft.username, prompt: "")
                AdvancedField(title: "Password", text: $model.draft.password, prompt: "", secure: true)
            }
            if model.draft.sendsCredentialsOverPlainHTTP {
                Label("These links use http, so the password is sent without encryption.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            AdvancedField(title: "Checksum", text: $model.draft.checksumText, prompt: "sha256:… or md5:…")
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed limit")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Speed limit", value: $model.draft.speedLimitKBps, format: .number, prompt: Text("0"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fieldBackground()
                    Text("KB/s (0 = unlimited)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(4)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(.rect(cornerRadius: 16, style: .continuous), tint: Color.red.opacity(0.18))
            .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .glassButton()
                .controlSize(.large)
                .disabled(isAdding) // adding cannot be taken back: Cancel would only close the sheet over it
            Button(action: add) {
                Label(addTitle, systemImage: "arrow.down.circle.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
            .controlSize(.large)
            .disabled(readyCount == 0 || isAdding)
            .help("Add (⌘↩)")
            // Return inserts a line break while the links field has focus, so ⌘↩ adds from anywhere.
            .background {
                Button("Add") { add() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(readyCount == 0 || isAdding)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var addTitle: String {
        let count = readyCount
        return count > 1 ? String(localized: "Add \(count) Downloads") : String(localized: "Add Download")
    }

    // MARK: Adding

    private func add() {
        guard !isAdding else { return } // Return in the field is not disabled like the buttons are
        commitPending() // a link typed but not yet entered still counts
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
            if outcome.failures.isEmpty {
                dismiss() // isAdding stays set: the sheet is still on screen while it closes, and a Return then must not add again
            } else {
                isAdding = false
                // Keep only what failed, so adding again cannot duplicate what went through.
                model.draft.linksText = outcome.failedLinks.map(\.absoluteString).joined(separator: "\n")
                errorText = outcome.failures.joined(separator: "\n")
            }
        }
    }

    private static func freeSpaceText(at folder: URL) -> String? {
        guard let bytes = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
              bytes > 0 else { return nil }
        return String(localized: "\(Formatters.bytes(bytes)) available")
    }
}

// MARK: - Pieces

/// A link found in the field, as a card: its file's icon, the file name, the host and whether the trip is encrypted.
private struct LinkCard: View {
    static let height: CGFloat = 50
    let link: LinkSummary
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(forFilename: link.displayName))
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: link.isEncrypted ? "lock.fill" : "lock.open.fill")
                        .font(.caption2)
                        .foregroundStyle(link.isEncrypted ? Color.secondary : Color.orange)
                        .help(link.isEncrypted ? "" : String(localized: "Not encrypted: this link uses http."))
                    Text(link.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.5)
            .accessibilityLabel("Remove link")
            .help("Remove this link")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        // A radius that nests in the well's: its 24 pt less the 14 pt around the cards is 10, and this sits at 12.
        .background(Color.primary.opacity(hovering ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove link", remove)
    }
}

/// A labelled text field on a soft inset, for the Advanced panel.
private struct AdvancedField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey
    var secure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(title, text: $text, prompt: Text(prompt))
                } else {
                    TextField(title, text: $text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fieldBackground()
        }
    }
}

/// Reports the height of the window a sheet is attached to.
private struct ParentHeightReader: NSViewRepresentable {
    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { Reader(report: report) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Reader: NSView {
        let report: (CGFloat) -> Void
        init(report: @escaping (CGFloat) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The window is attached to its parent a moment after the view arrives in it.
            DispatchQueue.main.async { [weak self] in
                guard let parent = self?.window?.sheetParent else { return }
                self?.report(parent.frame.height)
            }
        }
    }
}
