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

/// Lays content out inside the camera viewport — the rounded 16:9 rectangle the
/// preview and the compose preview share — rather than against the edges of the
/// screen.
///
/// The controls used to sit on the screen's own margins, which on a tall phone
/// is the black band *outside* the photo. A control for the frame belongs on
/// the frame.
struct ViewportOverlay<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let viewport = InstantStyle.viewportRect(in: proxy.size)
            content
                .padding(insets(viewport: viewport, screen: proxy.size, safeArea: proxy.safeAreaInsets))
                .frame(width: viewport.width, height: viewport.height)
                .offset(x: viewport.minX, y: viewport.minY)
        }
        .ignoresSafeArea()
    }

    /// The inset from the viewport's own edge, opened up wherever the status bar
    /// or the home indicator got there first. On a 16:9 phone the viewport is
    /// the whole screen, so the two overlap; on a tall one they never do.
    private func insets(viewport: CGRect, screen: CGSize, safeArea: EdgeInsets) -> EdgeInsets {
        let inset = InstantStyle.viewportInset
        return EdgeInsets(
            top: max(inset, safeArea.top - viewport.minY),
            leading: max(inset, safeArea.leading - viewport.minX),
            bottom: max(inset, safeArea.bottom - (screen.height - viewport.maxY)),
            trailing: max(inset, safeArea.trailing - (screen.width - viewport.maxX))
        )
    }
}

/// The way into settings, and the one piece of chrome that belongs to neither
/// page: it is drawn above the pager so that swiping between the camera and the
/// inbox leaves it exactly where it was.
struct AccountButton: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showsSettings = false

    /// `CircleIconButton`'s diameter, so the avatar sits on the same line as the
    /// flash and flip buttons opposite it.
    static let size: CGFloat = 44

    var body: some View {
        Button { showsSettings = true } label: {
            // The signed-in account, not a placeholder: their picture if they
            // have one, their initials if not.
            AvatarView(
                name: environment.account?.name ?? "",
                themeKey: environment.account?.themeKey ?? ThemePalette.defaultKey,
                url: environment.account?.profilePictureUrl,
                size: Self.size
            )
        }
        .buttonStyle(.plain)
        // Named for the camera from when it lived there, and left alone: it is
        // the same button, reachable from one more place.
        .accessibilityIdentifier("camera.profile")
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
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
