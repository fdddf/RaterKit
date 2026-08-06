import SwiftUI

/// Appearance of the prompt and the feedback form. The defaults follow the system,
/// which is usually all you need.
public struct RaterTheme: Sendable {
    /// Primary button and accent color. Defaults to `.accentColor`, so it picks up
    /// the host app's tint automatically.
    public var accent: Color
    /// Corner radius of the prompt card.
    public var cornerRadius: CGFloat
    /// Font for the prompt title.
    public var titleFont: Font
    /// Font for the prompt body.
    public var messageFont: Font
    /// Icon above the pre-prompt. Pass nil to hide it.
    public var promptIcon: Image?
    /// Opacity of the dimming layer behind the card.
    public var scrimOpacity: Double

    public init(
        accent: Color = .accentColor,
        cornerRadius: CGFloat = 16,
        titleFont: Font = .headline,
        messageFont: Font = .subheadline,
        promptIcon: Image? = Image(systemName: "star.bubble"),
        scrimOpacity: Double = 0.35
    ) {
        self.accent = accent
        self.cornerRadius = cornerRadius
        self.titleFont = titleFont
        self.messageFont = messageFont
        self.promptIcon = promptIcon
        self.scrimOpacity = scrimOpacity
    }
}
