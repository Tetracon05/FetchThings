import DownloadKit
import SwiftUI

// The pieces the app's windows are made of: glass tiles with an icon disc, round glass step buttons, soft inset fields
// and inset groups. The Add sheet, the Settings window and the details pane all use them, so they look like one app.

/// A tinted glass disc with a symbol in it: the icon of a tile.
struct IconChip: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassSurface(.circle, tint: tint.opacity(0.75))
            .accessibilityHidden(true)
    }
}

/// A round glass − or + button.
struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassSurface(.circle, interactive: enabled)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// A number with a − and a + beside it, for a whole-number setting. One adjustable element for VoiceOver, like a stepper.
struct StepperControl: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text("\(value)")
                .font(.body.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText(value: Double(value)))
                .frame(minWidth: 24, alignment: .trailing)
            StepButton(symbol: "minus", enabled: value > range.lowerBound) { step(-1) }
            StepButton(symbol: "plus", enabled: value < range.upperBound) { step(1) }
        }
        .animation(.snappy(duration: 0.2), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
    }

    private func step(_ delta: Int) {
        value = range.clamp(value + delta)
    }
}

/// One setting as a glass tile: an icon disc, a title with an optional line under it, and the control on the right.
struct SettingTile<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: Text
    var detail: Text?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconChip(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.callout.weight(.semibold))
                if let detail {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .tile()
    }
}

/// A caption, the tiles under it, and an optional note below them.
struct TileSection<Content: View>: View {
    let title: Text
    var footer: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title.sectionCaption()
            GlassGroup(spacing: 4) {
                VStack(spacing: 10) { content }
            }
            if let footer {
                footer
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Rows on a soft inset, separated by hairlines, under a small caption: for a pane that is itself glass, where a second
/// glass layer would only muddy it. Its 12 pt corners nest in a 22 pt card with 10 pt of padding.
struct InsetGroup<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.sectionCaption()
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { index in
                        rows[index]
                        if index < rows.count - 1 { Divider().padding(.leading, 12) }
                    }
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A label and its value on one line, or the value under the label when it is long.
struct DetailRow<Value: View>: View {
    let title: Text
    var stacked = false
    @ViewBuilder var value: Value

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 3) {
                    title.font(.caption).foregroundStyle(.secondary)
                    value.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    value.font(.callout).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension DetailRow where Value == Text {
    init(_ title: Text, value: String) {
        self.init(title: title) { Text(value) }
    }
}

extension View {
    /// The look of a tile: padding and a glass rounded rectangle.
    func tile(cornerRadius: CGFloat = 20) -> some View {
        padding(12)
            .glassSurface(.rect(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A soft inset behind a text field.
    func fieldBackground() -> some View {
        background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
    }

    /// A one-line text field on a soft inset. `width` is that of the whole inset, padding included.
    func insetField(width: CGFloat? = nil, alignment: TextAlignment = .leading) -> some View {
        labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width)
            .fieldBackground()
    }
}

extension Text {
    /// The small grey caption over a group of tiles or rows.
    func sectionCaption() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
    }
}

/// A small caption over a control, for the fields of a form.
struct CaptionedField<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
    }
}

extension DownloadSnapshot {
    /// The colour that stands for the download's state: its progress bar and its status pill.
    var stateTint: Color {
        switch state {
        case .failed: .red
        case .completed: .green
        case .paused, .queued: .gray
        default: .accentColor
        }
    }
}
