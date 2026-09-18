import DownloadKit
import SwiftUI

struct InspectorView: View {
    let model: AppModel

    var body: some View {
        if let download = model.inspectedDownload {
            DetailForm(download: download, model: model)
        } else if model.selection.count > 1 {
            let selected = model.selectedDownloads
            let total = selected.compactMap(\.totalBytes).reduce(0, +)
            ContentUnavailableView(
                "\(selected.count) Downloads Selected", systemImage: "square.stack",
                description: Text(total > 0 ? "\(Formatters.bytes(total)) in total" : "")
            )
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a download to see its details."))
        }
    }
}

private struct DetailForm: View {
    let download: DownloadSnapshot
    let model: AppModel

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Name") { Text(download.displayName).textSelection(.enabled) }
                LabeledContent("Address") {
                    Text(download.url.absoluteString)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
                LabeledContent("Saved In") {
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
                LabeledContent("Status") {
                    Text(download.statusText).foregroundStyle(download.state == .failed ? Color.red : Color.primary)
                }
                if let failure = download.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Transfer") {
                LabeledContent("Size", value: Formatters.size(download.totalBytes))
                LabeledContent("Downloaded", value: Formatters.bytes(download.receivedBytes))
                LabeledContent("Speed", value: Formatters.speed(download.bytesPerSecond))
                LabeledContent("Time Left", value: Formatters.eta(download.eta))
                LabeledContent("Connections", value: download.state == .downloading ? "\(download.activeConnections)" : "—")
                LabeledContent("Can Resume", value: download.mode == nil ? "—" : (download.supportsResume ? "Yes" : "No"))
            }

            if !download.segments.isEmpty, let total = download.totalBytes, total > 0 {
                Section("Connections") {
                    SegmentMap(segments: download.segments, total: total)
                }
            }

            Section("Details") {
                LabeledContent("Added", value: download.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let completed = download.completedAt {
                    LabeledContent("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                }
                if let verified = download.checksumVerified {
                    LabeledContent("Checksum", value: verified ? "Verified" : "Not verified")
                }
                if let limit = download.speedLimit {
                    LabeledContent("Speed Limit", value: "\(Formatters.bytes(limit))/s")
                }
            }
        }
        .formStyle(.grouped)
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
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection map")
        .accessibilityValue("\(segments.count) parts, \(Formatters.percent(Double(segments.reduce(0) { $0 + $1.received }) / Double(total))) fetched")
    }
}
