#if canImport(UIKit)
import SwiftUI

/// How the outbox is doing, in one small capsule.
///
/// Small on purpose: sending is the normal case, and the pill is there so a
/// send that has left the screen is not also out of mind. A spinner while it
/// goes, a tick for a moment when it has gone, and — the only state that stays
/// — what went wrong, with a way to try again.
struct SendStatusPill: View {
    @Environment(AppEnvironment.self) private var environment

    /// The shutter's height plus a gap, so the pill sits just above the
    /// camera's bottom bar rather than on it.
    static let bottomClearance: CGFloat = 78 + 14

    private var outbox: Outbox { environment.outbox }

    var body: some View {
        ZStack {
            if let item = outbox.headline {
                pill(for: item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: outbox.headline)
    }

    @ViewBuilder
    private func pill(for item: Outbox.Item) -> some View {
        switch item.phase {
        case .sending:
            capsule {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(sendingText(item))
                    .accessibilityIdentifier("sendStatus.sending")
                    // Whether a force quit would still lose it. Nothing to see,
                    // but it is what the relaunch test waits on.
                    .accessibilityValue(item.isSaved ? "saved" : "preparing")
            }

        case .sent:
            capsule {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text(sentText(item))
                    .accessibilityIdentifier("sendStatus.sent")
            }

        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Couldn't send to \(item.recipient.name)")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityIdentifier("sendStatus.failed")
                    Text(message)
                        .font(.system(size: 12))
                        .opacity(0.85)
                        .lineLimit(2)
                }
                Button("Retry") { outbox.retry(item.id) }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sendStatus.retry")
                Button {
                    outbox.dismiss(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .padding(5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sendStatus.dismiss")
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(Capsule().fill(InstantStyle.unread.opacity(0.92)))
        }
    }

    /// Names the person when there is one send, and counts when there are
    /// several — the pill is not the place for a list.
    private func sendingText(_ item: Outbox.Item) -> String {
        let count = outbox.inFlight.count
        return count > 1 ? "Sending \(count)…" : "Sending to \(item.recipient.name)…"
    }

    /// A photo sent to several people lands as several confirmations a moment
    /// apart; naming only the last would read as though it went to one.
    private func sentText(_ item: Outbox.Item) -> String {
        let count = outbox.items.filter { $0.phase == .sent }.count
        return count > 1 ? "Sent to \(count) people" : "Sent to \(item.recipient.name)"
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
#endif
