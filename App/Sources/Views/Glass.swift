import SwiftUI

// Liquid Glass arrived in macOS 26, and the app still runs on macOS 15. These wrappers use glass where it exists and
// fall back to a material (or the plain button styles) before that, so no view has to repeat the availability check.

extension View {
    /// Draws the view on a glass surface of the given shape. `tint` colours the glass; `interactive` makes it react to
    /// the pointer like a control.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            // The tint goes behind the content: as an overlay it sat in front of the buttons inside the surface and
            // swallowed their clicks. It is drawn at the strength the caller chose for glass, so a white glyph or dark
            // ink chosen for a strongly tinted surface stays readable.
            background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint) }
            }
        }
    }

    /// Lets this glass shape morph into another one that carries the same id, inside a `GlassGroup`, when one replaces
    /// the other. Nothing happens where glass is not available.
    @ViewBuilder
    func glassMorph(id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// The glass button style, or the ordinary bordered one where glass is not available.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Lets nearby glass shapes blend and share one rendering pass. Just the content where glass is not available.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
