import DownloadKit
import SwiftUI

struct InspectorView: View {
    let model: AppModel

    var body: some View {
        if let download = model.inspectedDownload {
            DetailForm(download: download, model: model)
        } else if model.selection.count > 1 {
            MultipleSelection(downloads: model.selectedDownloads, model: model)
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a download to see its details."))
        }
    }
}

/// Several downloads selected: their pictures piled up, and how many and how big they are together.
private struct MultipleSelection: View {
    let downloads: [DownloadSnapshot]
    let model: AppModel

    var body: some View {
        let total = downloads.compactMap(\.totalBytes).reduce(0, +)
        VStack(spacing: 6) {
            DownloadStack(downloads: downloads)
                // Drag the pile to take every selected file along.
                .overlay { FileDragSource { FileDragSource.items(for: downloads, in: model, box: DownloadStack.cardBox) } }
                .padding(.bottom, 14)
            Text("\(downloads.count) Downloads Selected")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if total > 0 {
                Text("\(Formatters.bytes(total)) in total")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailForm: View {
    let download: DownloadSnapshot
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                InsetGroup(title: Text("General")) {
                    DetailRow(title: Text("Address"), stacked: true) {
                        Text(download.url.absoluteString)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                    DetailRow(title: Text("Saved In"), stacked: true) {
                        Button {
                            model.revealInFinder([download.id])
                        } label: {
                            Text(download.destinationDirectory.displayPath)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help("Show in Finder")
                    }
                    if let failure = download.failure {
                        DetailRow(title: Text("Error"), stacked: true) {
                            Text(failure)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }

                InsetGroup(title: Text("Transfer")) {
                    DetailRow(Text("Size"), value: Formatters.size(download.totalBytes))
                    DetailRow(Text("Downloaded"), value: Formatters.bytes(download.receivedBytes))
                    DetailRow(Text("Speed"), value: Formatters.speed(download.bytesPerSecond))
                    DetailRow(Text("Time Left"), value: Formatters.eta(download.eta))
                    DetailRow(Text("Connections"), value: download.state == .downloading ? "\(download.activeConnections)" : "—")
                    if download.state != .completed {
                        DetailRow(Text("Can Resume"), value: download.mode == nil ? "—" : (download.supportsResume ? String(localized: "Yes") : String(localized: "No")))
                    }
                }

                if !download.segments.isEmpty, let total = download.totalBytes, total > 0 {
                    InsetGroup(title: Text("Connections")) {
                        SegmentMap(segments: download.segments, total: total)
                            .padding(8)
                    }
                }

                InsetGroup(title: Text("Details")) {
                    if let position = model.queuePositions[download.id] {
                        DetailRow(Text("Queue Position"), value: "\(position)")
                        DetailRow(Text("Priority"), value: download.priority.title)
                    }
                    DetailRow(Text("Added"), value: download.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let completed = download.completedAt {
                        DetailRow(Text("Completed"), value: completed.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let verified = download.checksumVerified {
                        DetailRow(Text("Checksum"), value: verified ? String(localized: "Verified") : String(localized: "Not verified"))
                    }
                    if let limit = download.speedLimit {
                        DetailRow(Text("Speed Limit"), value: Formatters.perSecond(limit))
                    }
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The file's picture, its name, where it stands and, while it is not finished, a progress bar.
    private var header: some View {
        VStack(spacing: 10) {
            // A preview of the contents once the file is there (a video frame, a photo), its icon before that.
            DownloadPicture(download: download, box: DownloadPicture.headerBox, iconSide: 112)
                // A new picture for each download: its state starts from what is already drawn (no flash of the icon
                // while arrowing through files) and cannot carry over a preview made for another file, or an old
                // version of this one.
                .id(download.id)
                // Drag the picture to take the file along.
                .overlay { FileDragSource { FileDragSource.items(for: [download], in: model, box: DownloadPicture.headerBox) } }
            VStack(spacing: 6) {
                Text(download.displayName)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(model.statusText(of: download))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassSurface(.capsule, tint: download.stateTint.opacity(0.3))
            }
            if download.state != .completed {
                VStack(spacing: 6) {
                    if let fraction = download.fraction {
                        ProgressBar(fraction: fraction, tint: download.stateTint, selected: false)
                    } else if download.state.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(progressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.top, 6)
    }

    private var progressLine: String {
        var parts: [String] = []
        if let total = download.totalBytes, total > 0 {
            parts.append(String(localized: "\(Formatters.bytes(download.receivedBytes)) of \(Formatters.size(total))"))
        } else {
            parts.append(Formatters.bytes(download.receivedBytes))
        }
        if download.state == .downloading {
            if download.bytesPerSecond >= 1 { parts.append(Formatters.speed(download.bytesPerSecond)) }
            if let eta = download.eta { parts.append(Formatters.eta(eta)) }
        }
        return parts.joined(separator: " · ")
    }
}

/// The file as one bar: what each connection has fetched so far, drawn where it sits in the file.
private struct SegmentMap: View {
    let segments: [SegmentSnapshot]
    let total: Int64

    var body: some View {
        Canvas { context, size in
            let fullWidth = size.width
            let scale = fullWidth / Double(total)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.18)))
            for segment in segments where segment.received > 0 {
                let rect = CGRect(x: Double(segment.start) * scale, y: 0, width: max(1, Double(segment.received) * scale), height: size.height)
                context.fill(Path(rect), with: .color(segment.isActive ? Color.accentColor : Color.accentColor.opacity(0.55)))
            }
            // Thin separators show where one connection's range ends and the next begins.
            for segment in segments.sorted(by: { $0.start < $1.start }).dropFirst() {
                let x = Double(segment.start) * scale
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .style(.background))
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .padding(4)
        .glassSurface(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection map")
        .accessibilityValue("Parts: \(segments.count), \(Formatters.percent(Double(segments.reduce(0) { $0 + $1.received }) / Double(total))) fetched")
    }
}
