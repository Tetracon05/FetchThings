import SwiftUI

/// The curves of the control and of the list it opens. The popover's own corners come from the system, so the rows are
/// given a radius that nests inside them: the popover's radius minus the gap between it and the rows. Rows with a
/// bigger radius (full capsules) look pinched against the popover's corners.
private enum SpeedModeShape {
    /// The system popover's corner radius: about 20 pt with Liquid Glass (measured on macOS 26), about 10 before it.
    static var popoverRadius: CGFloat {
        if #available(macOS 26.0, *) { 20 } else { 10 }
    }
    /// The gap around and between the rows in the popover.
    static let inset: CGFloat = 8
    static var rowRadius: CGFloat { max(popoverRadius - inset, 4) }
    static var row: RoundedRectangle { RoundedRectangle(cornerRadius: rowRadius, style: .continuous) }
}

/// The speed mode as one pop-up control at the bottom of the sidebar. Closed, it is a rounded button of tinted Liquid
/// Glass in the colour of the current mode (red, yellow or green); opened, it lists Low, Normal and High as buttons of
/// their own colours, the chosen one in full colour with a check mark. It is drawn by hand instead of as a plain pop-up
/// menu because menu items cannot carry colour or glass.
struct SpeedModePicker: View {
    let model: AppModel
    @State private var isOpen = false

    var body: some View {
        let mode = model.settings.speedMode
        let limit = model.settings.limitKBps(for: mode)
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                SpeedModeContent(mode: mode, limitKBps: limit, chosen: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mode.ink(chosen: true).opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(SpeedModeShape.row)
        }
        .buttonStyle(.plain)
        .glassSurface(SpeedModeShape.row, tint: mode.color.opacity(0.85), interactive: true)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            SpeedModeOptions(model: model) { isOpen = false }
        }
        .accessibilityLabel("Speed mode")
        .accessibilityValue("\(String(localized: mode.title)), \(mode.accessibleLimit(kbps: limit))")
        .help(mode.help(kbps: limit))
    }
}

/// The three modes to choose from, each a button in its own colour.
private struct SpeedModeOptions: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: SpeedModeShape.inset) {
            ForEach(SpeedMode.allCases) { mode in
                let limit = model.settings.limitKBps(for: mode)
                let chosen = model.settings.speedMode == mode
                Button {
                    model.selectSpeedMode(mode)
                    close()
                } label: {
                    HStack(spacing: 8) {
                        SpeedModeContent(mode: mode, limitKBps: limit, chosen: chosen)
                        Spacer(minLength: 12)
                        if chosen { Image(systemName: "checkmark").font(.callout.weight(.semibold)) }
                    }
                    .foregroundStyle(mode.ink(chosen: chosen))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(width: 210)
                    .contentShape(SpeedModeShape.row)
                }
                .buttonStyle(.plain)
                // Separate glass shapes, not one container: shapes in a container blend into each other.
                .glassSurface(SpeedModeShape.row, tint: mode.color.opacity(chosen ? 0.85 : 0.28), interactive: true)
                .accessibilityLabel(mode.title)
                .accessibilityValue(mode.accessibleLimit(kbps: limit))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .help(mode.help(kbps: limit))
            }
        }
        .padding(SpeedModeShape.inset)
    }
}

/// The symbol, the name and the limit of a mode.
private struct SpeedModeContent: View {
    let mode: SpeedMode
    let limitKBps: Int
    let chosen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.symbol)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.title)
                    .font(.callout.weight(.semibold))
                Text(mode.limitText(kbps: limitKBps))
                    .font(.caption)
                    .foregroundStyle(mode.ink(chosen: chosen).opacity(chosen ? 0.9 : 0.7)) // `.secondary` washes out on the tinted glass
            }
        }
        .foregroundStyle(mode.ink(chosen: chosen))
    }
}

extension SpeedMode {
    var title: LocalizedStringResource {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    var symbol: String {
        switch self {
        case .low: "tortoise.fill"
        case .normal: "gauge.with.dots.needle.50percent"
        case .high: "hare.fill"
        }
    }

    var color: Color {
        switch self {
        case .low: .red
        case .normal: .yellow
        case .high: .green
        }
    }

    /// White on saturated yellow is hard to read in dark mode, so the chosen yellow gets dark text.
    func ink(chosen: Bool) -> Color { chosen && self == .normal ? .black : .primary }

    func limitText(kbps: Int) -> String {
        kbps > 0 ? String(localized: "\(kbps.formatted(.number.grouping(.never))) KB/s") : String(localized: "Unlimited")
    }

    func accessibleLimit(kbps: Int) -> String {
        kbps > 0 ? String(localized: "Limited to \(kbps.formatted(.number.grouping(.never))) kilobytes per second") : String(localized: "No limit")
    }

    func help(kbps: Int) -> String {
        let limit = limitText(kbps: kbps)
        return switch self {
        case .low: String(localized: "Low speed: \(limit) for all downloads together")
        case .normal: String(localized: "Normal speed: \(limit) for all downloads together")
        case .high: String(localized: "High speed: no limit")
        }
    }
}
