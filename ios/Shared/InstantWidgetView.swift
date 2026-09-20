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

    /// The picture is the widget — it is drawn behind all of this by
    /// `InstantWidgetBackground`, so everything here is type stacked at the
    /// bottom, where the scrim is heaviest. Both sizes share the layout and
    /// differ only in how big the type is; a small widget holds the same four
    /// things a medium one does.
    private func waitingBody(_ contact: InstantWidgetSnapshot.Contact) -> some View {
        let medium = family == .systemMedium
        return VStack(alignment: .leading, spacing: medium ? 6 : 4) {
            Spacer(minLength: 0)
            if contact.hasStreak { streak(contact) }
            Text(contact.name)
                .font(.system(size: medium ? 22 : 17, weight: .bold))
                .foregroundStyle(InstantStyle.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 8) {
                Text(waitingLine(contact))
                    .font(.system(size: medium ? 14 : 12, weight: .semibold))
                    .foregroundStyle(InstantStyle.unread)
                Spacer(minLength: 0)
                if entry.contactCount > 1 { dots }
            }
        }
        // A photograph can be any colour at all. The scrim carries most of the
        // legibility, and the shadow covers the bright corner it does not.
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(contact))
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
        .background(Capsule().fill(.black.opacity(0.45)))
    }

    /// One dot per person waiting, the current one filled — otherwise a widget
    /// that changes every 30 seconds looks like it is glitching.
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(entry.contactCount, 5), id: \.self) { index in
                Circle()
                    .fill(index == entry.position ? InstantStyle.primaryText : Color.white.opacity(0.45))
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

/// The sender's picture, edge to edge, with a scrim over it.
///
/// It is a separate view because it belongs in `containerBackground` rather
/// than in `InstantWidgetView.body`: a widget's content is inset by the
/// system's margins, so a picture drawn inside the body would sit in a black
/// frame a few points short of every edge instead of filling the widget.
public struct InstantWidgetBackground: View {
    let entry: WaitingEntry

    /// The picture is read from the App Group at draw time, which a test
    /// process has no container for. Passing one in is what makes the
    /// full-bleed path renderable, the same way `family` is overridable above.
    private let avatarOverride: UIImage?

    public init(entry: WaitingEntry, avatar: UIImage? = nil) {
        self.entry = entry
        self.avatarOverride = avatar
    }

    public var body: some View {
        ZStack {
            InstantStyle.background
            if let contact = entry.contact {
                if let image = avatarOverride ?? WidgetAvatarCache.image(for: contact) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    initials(contact)
                }
                scrim
            }
        }
        .clipped()
    }

    /// No picture cached yet: initials on the person's own theme colour, the
    /// same fallback the app's avatar uses, blown up to fill the widget so the
    /// two states are the same shape.
    private func initials(_ contact: InstantWidgetSnapshot.Contact) -> some View {
        let palette = ThemePalette.palette(for: contact.themeKey)
        return GeometryReader { proxy in
            LinearGradient(
                colors: [palette.border, palette.accent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Sat high rather than centred: the name and the counts are along
            // the bottom, and two pieces of type on top of each other read as
            // neither.
            .overlay(alignment: .top) {
                Text(contact.initials)
                    .font(.system(
                        size: min(proxy.size.width, proxy.size.height) * 0.46,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, proxy.size.height * 0.08)
            }
        }
    }

    /// White type over an arbitrary photograph is otherwise a coin toss. The
    /// gradient is darkest at the bottom, where the name and the counts are.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.05), location: 0),
                .init(color: .black.opacity(0.20), location: 0.5),
                .init(color: .black.opacity(0.85), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Decoded pictures, kept for as long as the extension's process lives.
///
/// A cycling timeline renders about 120 entries in one pass, and a picture that
/// fills the widget is an order of magnitude more pixels than an avatar-sized
/// one. Decoding one off disk per entry is how a render pass runs out of the
/// memory and the time WidgetKit allows it, and a render that dies shows the
/// system placeholder with no error anywhere.
enum WidgetAvatarCache {
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    static func image(for contact: InstantWidgetSnapshot.Contact) -> UIImage? {
        guard let file = contact.avatarFile,
              let url = InstantWidgetStore.avatarURL(named: file)
        else { return nil }

        // Keyed by modification date as well as name, because the app rewrites
        // a person's picture under the same filename: a key of the name alone
        // would pin whatever this process decoded first.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let key = "\(file)@\(modified.timeIntervalSince1970)" as NSString

        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
