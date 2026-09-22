import SwiftUI

/// The eight Eddie's Lounge themes, mirroring `frontend/src/themes.ts`.
///
/// `themeKey` rides along on every user, sender and streak payload, so it is the
/// natural accent source — the app tints each person in their own colour rather
/// than borrowing Snapchat's yellow.
public struct ThemePalette: Equatable, Sendable {
    public let key: String
    public let label: String
    public let accent: Color
    public let border: Color

    static let all: [ThemePalette] = [
        ThemePalette(key: "boring-grey", label: "Boring Grey", accent: .hex(0x64748B), border: .hex(0xCBD5E1)),
        ThemePalette(key: "sunset", label: "Sunset Ember", accent: .hex(0xDC2626), border: .hex(0xF97316)),
        ThemePalette(key: "purple", label: "Purple Bloom", accent: .hex(0x7E22CE), border: .hex(0xC084FC)),
        ThemePalette(key: "forest", label: "Forest Moss", accent: .hex(0x15803D), border: .hex(0x22C55E)),
        ThemePalette(key: "ocean", label: "Ocean Breeze", accent: .hex(0x0369A1), border: .hex(0x0EA5E9)),
        ThemePalette(key: "rose", label: "Rose Garden", accent: .hex(0xBE185D), border: .hex(0xF472B6)),
        ThemePalette(key: "indigo", label: "Indigo Night", accent: .hex(0x4338CA), border: .hex(0x818CF8)),
        ThemePalette(key: "gold", label: "Golden Hour", accent: .hex(0xA16207), border: .hex(0xEAB308)),
    ]

    public static let defaultKey = "boring-grey"

    public static func palette(for key: String?) -> ThemePalette {
        all.first { $0.key == key } ?? all.first { $0.key == defaultKey }!
    }
}

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Snapchat's chrome is near-black with high-contrast white controls; that is
/// what makes a full-bleed photo the subject of the screen. The palette below
/// keeps that structure without borrowing its brand colours.
enum InstantStyle {
    static let background = Color.black
    static let surface = Color(white: 0.09)
    static let surfaceRaised = Color(white: 0.15)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.62)
    static let unread = Color.hex(0xF43F5E)
    static let flame = Color.hex(0xF59E0B)
    /// The shutter while it records, and the ring of time left around it — red,
    /// because every camera has taught that red means it is rolling.
    static let recording = Color.hex(0xEF4444)

    /// The camera viewport and the compose preview are the same rectangle, and
    /// it is the same shape as the photo that comes out of it: 16:9, standing
    /// up. Framing and reviewing a shot on differently shaped surfaces means
    /// the sender never quite knows what they took.
    static let viewportAspectRatio: CGFloat = 9.0 / 16.0
    /// Enough to read as a card against the black, not so much that it reads as
    /// a widget.
    static let viewportCornerRadius: CGFloat = 22

    /// Defined once because the camera and the compose screen have to clip to
    /// the same outline — a corner that changes between framing and reviewing
    /// is a corner the eye catches.
    static var viewportShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: viewportCornerRadius, style: .continuous)
    }

    /// How far the controls sit inside the viewport's edge. Clear of the corner
    /// radius, and clear of the photo's own edge.
    static let viewportInset: CGFloat = 16

    /// Where the viewport lands on a screen of this size: as wide as the screen
    /// until 16:9 would run off the bottom, then as tall as the screen, centred
    /// either way.
    ///
    /// The controls are positioned from this rather than from the screen's own
    /// margins — on a tall phone those margins are the black band outside the
    /// photo, which is not where a control for the photo belongs.
    static func viewportRect(in screen: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        let width = min(screen.width, screen.height * viewportAspectRatio)
        let height = width / viewportAspectRatio
        return CGRect(
            x: (screen.width - width) / 2,
            y: (screen.height - height) / 2,
            width: width,
            height: height
        )
    }
}
