#if canImport(UIKit)
import Foundation
import UIKit
import WidgetKit

public protocol WidgetSnapshotPublishing: Sendable {
    /// Caches whatever the widget needs on disk, writes the snapshot, and asks
    /// WidgetKit to redraw.
    func publish(_ snapshot: InstantWidgetSnapshot) async
    func clear() async
}

public struct WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let session: URLSession
    private let reload: @Sendable () -> Void

    public init(
        session: URLSession = .shared,
        reload: @escaping @Sendable () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: InstantWidgetStore.widgetKind)
        }
    ) {
        self.session = session
        self.reload = reload
    }

    public func publish(_ snapshot: InstantWidgetSnapshot) async {
        var cached = snapshot
        var contacts: [InstantWidgetSnapshot.Contact] = []
        contacts.reserveCapacity(snapshot.contacts.count)

        for var contact in snapshot.contacts {
            // Fetched here rather than in the widget: widgets render
            // synchronously off whatever is already on disk, so an image loaded
            // at draw time would simply never appear.
            if let file = await cacheAvatar(for: contact) {
                contact.avatarFile = file
            }
            contacts.append(contact)
        }

        cached = InstantWidgetSnapshot(contacts: contacts, updatedAt: snapshot.updatedAt)
        InstantWidgetStore.pruneAvatars(keeping: Set(contacts.map(\.userId)))
        try? InstantWidgetStore.save(cached)
        reload()
    }

    public func clear() async {
        InstantWidgetStore.clear()
        reload()
    }

    private func cacheAvatar(for contact: InstantWidgetSnapshot.Contact) async -> String? {
        guard let raw = contact.profilePictureUrl, let url = URL(string: raw) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              // Decoded once here so the widget never has to reject a bad file
              // mid-render, and downsized because a widget avatar is tiny.
              let image = UIImage(data: data),
              let encoded = Self.downsized(image).pngData()
        else { return nil }
        return InstantWidgetStore.writeAvatar(encoded, for: contact.userId)
    }

    static func downsized(_ image: UIImage, to edge: CGFloat = 160) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > edge else { return image }
        let scale = edge / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Test double.
public final class RecordingWidgetPublisher: WidgetSnapshotPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var published: [InstantWidgetSnapshot] = []
    private var clears = 0

    public init() {}

    public var snapshots: [InstantWidgetSnapshot] { lock.withLock { published } }
    public var latest: InstantWidgetSnapshot? { lock.withLock { published.last } }
    public var clearCount: Int { lock.withLock { clears } }

    public func publish(_ snapshot: InstantWidgetSnapshot) async {
        lock.withLock { published.append(snapshot) }
    }

    public func clear() async {
        lock.withLock { clears += 1 }
    }
}
#endif
