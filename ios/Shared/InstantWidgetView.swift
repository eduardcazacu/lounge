import SwiftUI
import WidgetKit

/// Lives in Shared rather than in the extension so it can be rendered — and
/// therefore actually looked at — from a test. An extension's views are not
/// reachable from the app's test bundle.
public struct InstantWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: WaitingEntry

    /// `widgetFamily` is read-only in the environment, so a test cannot set it.
    /// Overriding it here is what makes each size renderable and checkable.
    private let familyOverride: WidgetFamily?
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    public init(entry: WaitingEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = family
    }

    public var body: some View {
        if let contact = entry.contact {
            waiting(contact)
        } else {
            idle
        }
    }

    // MARK: - Nothing waiting

    /// The app mark, matching the sign-in screen so the widget reads as Instant
    /// rather than as an empty state that has gone wrong.
    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: family == .systemSmall ? 42 : 36))
                .foregroundStyle(InstantStyle.primaryText)
            Text("Instant")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(InstantStyle.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Instant. Nothing waiting.")
    }

    // MARK: - Someone is waiting

    /// The tap lands in the inbox rather than on the camera: a widget showing
    /// that someone is waiting is a promise about where it goes. The idle
    /// widget carries no URL and opens the app where it normally opens.
    @ViewBuilder
    private func waiting(_ contact: InstantWidgetSnapshot.Contact) -> some View {
        waitingBody(contact)
            .widgetURL(DeepLink.inbox(instantId: nil).url)
    }

    @ViewBuilder
    private func waitingBody(_ contact: InstantWidgetSnapshot.Contact) -> some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 14) {
                avatar(contact, size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    Text(contact.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(InstantStyle.primaryText)
                        .lineLimit(1)
                    Text(waitingLine(contact))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(InstantStyle.unread)
                    if contact.hasStreak { streak(contact) }
                }
                Spacer(minLength: 0)
                if entry.contactCount > 1 { dots }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(contact))

        default:
            VStack(spacing: 8) {
                avatar(contact, size: 56)
                Text(contact.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(InstantStyle.primaryText)
                    .lineLimit(1)
                Text(waitingLine(contact))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InstantStyle.unread)
                if contact.hasStreak { streak(contact) }
                if entry.contactCount > 1 { dots }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(contact))
        }
    }

    /// The cached picture if the app managed to fetch one, otherwise initials on
    /// the person's own theme colour — the same fallback the app's avatar uses.
    private func avatar(_ contact: InstantWidgetSnapshot.Contact, size: CGFloat) -> some View {
        let palette = ThemePalette.palette(for: contact.themeKey)
        return ZStack {
            Circle().fill(palette.accent)
            if let image = cachedAvatar(contact) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(contact.initials)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(palette.border.opacity(0.7), lineWidth: 2))
    }

    private func cachedAvatar(_ contact: InstantWidgetSnapshot.Contact) -> UIImage? {
        guard let file = contact.avatarFile,
              let url = InstantWidgetStore.avatarURL(named: file),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }

    private func streak(_ contact: InstantWidgetSnapshot.Contact) -> some View {
        HStack(spacing: 3) {
            Text("🔥").font(.system(size: 11))
            Text("\(contact.streakCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(InstantStyle.flame)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(InstantStyle.flame.opacity(0.16)))
    }

    /// One dot per person waiting, the current one filled — otherwise a widget
    /// that changes every 30 seconds looks like it is glitching.
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(entry.contactCount, 5), id: \.self) { index in
                Circle()
                    .fill(index == entry.position ? InstantStyle.primaryText : InstantStyle.secondaryText.opacity(0.4))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func waitingLine(_ contact: InstantWidgetSnapshot.Contact) -> String {
        contact.unopenedCount > 1 ? "\(contact.unopenedCount) waiting" : "New Instant"
    }

    private func accessibilityLabel(_ contact: InstantWidgetSnapshot.Contact) -> String {
        var parts = [contact.name, waitingLine(contact)]
        if contact.hasStreak { parts.append("\(contact.streakCount) day streak") }
        if entry.contactCount > 1 {
            parts.append("\(entry.position + 1) of \(entry.contactCount)")
        }
        return parts.joined(separator: ", ")
    }
}
