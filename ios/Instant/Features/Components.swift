#if canImport(UIKit)
import SwiftUI

/// A person's avatar, tinted with their Lounge theme when they have no picture.
struct AvatarView: View {
    let name: String
    let themeKey: String
    let url: String?
    var size: CGFloat = 52

    /// `nil` while the name is still unknown, so the placeholder can be a person
    /// glyph rather than a "?" that reads like an error.
    private var initials: String? {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return letters.isEmpty ? nil : letters.uppercased()
    }

    @ViewBuilder
    private var placeholder: some View {
        if let initials {
            Text(initials)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    var body: some View {
        let palette = ThemePalette.palette(for: themeKey)
        return ZStack {
            Circle().fill(palette.accent)
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
                .clipShape(Circle())
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(palette.border.opacity(0.7), lineWidth: 2))
        .accessibilityLabel(name.isEmpty ? "Profile" : name)
    }
}

/// Snapchat shows a flame and a day count; a streak about to lapse is the one
/// thing in the list worth shouting about, so it gets colour and a countdown.
struct StreakBadge: View {
    let streak: InstantStreakSummary

    var body: some View {
        HStack(spacing: 3) {
            Text("🔥").font(.system(size: 13))
            Text("\(streak.count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(streak.atRisk ? InstantStyle.unread : InstantStyle.flame)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                (streak.atRisk ? InstantStyle.unread : InstantStyle.flame).opacity(0.16)
            )
        )
        .accessibilityLabel(
            streak.atRisk
                ? "\(streak.count) day streak, about to end"
                : "\(streak.count) day streak"
        )
    }
}

struct CircleIconButton: View {
    let systemName: String
    var diameter: CGFloat = 44
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(isOn ? Color.white : Color.black.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
    }
}
#endif
