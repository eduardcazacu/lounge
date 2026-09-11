import Foundation

/// What the widget draws, written by the app into a shared App Group container.
///
/// The widget cannot fetch this for itself. Access tokens live 15 minutes and
/// renewing one needs the `refresh_token` cookie, which lives in the app's own
/// URLSession container — extensions get neither. So the app publishes and the
/// widget reads, which also keeps every credential out of the extension.
public struct InstantWidgetSnapshot: Codable, Equatable, Sendable {
    public struct Contact: Codable, Equatable, Sendable, Identifiable {
        public let userId: Int
        public let name: String
        public let themeKey: String
        /// Remote URL, used by the app to fetch the picture. The widget never
        /// loads it — see `avatarFile`.
        public let profilePictureUrl: String?
        /// Filename inside the shared container. Widgets render synchronously
        /// and have no reliable network, so the picture has to be on disk
        /// before the timeline is built.
        public var avatarFile: String?
        public let unopenedCount: Int
        public let streakCount: Int

        public var id: Int { userId }
        public var hasStreak: Bool { streakCount > 0 }

        public init(
            userId: Int,
            name: String,
            themeKey: String,
            profilePictureUrl: String?,
            avatarFile: String? = nil,
            unopenedCount: Int,
            streakCount: Int
        ) {
            self.userId = userId
            self.name = name
            self.themeKey = themeKey
            self.profilePictureUrl = profilePictureUrl
            self.avatarFile = avatarFile
            self.unopenedCount = unopenedCount
            self.streakCount = streakCount
        }

        /// Same rule the in-app avatar uses, so the widget and the app agree.
        public var initials: String {
            let letters = name
                .split(separator: " ")
                .prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
            return letters.isEmpty ? "?" : letters.uppercased()
        }
    }

    public let contacts: [Contact]
    public let updatedAt: Date

    public init(contacts: [Contact], updatedAt: Date) {
        self.contacts = contacts
        self.updatedAt = updatedAt
    }

    public static let empty = InstantWidgetSnapshot(contacts: [], updatedAt: .distantPast)

    public var isEmpty: Bool { contacts.isEmpty }
    public var totalWaiting: Int { contacts.reduce(0) { $0 + $1.unopenedCount } }
}

/// The shared container the app writes to and the widget reads from.
public enum InstantWidgetStore {
    public static let appGroup = "group.com.eduardcazacu.instant"
    public static let widgetKind = "InstantWaitingWidget"

    static let snapshotName = "widget-snapshot.json"
    static let avatarsDirectory = "widget-avatars"

    /// Overridable so tests can exercise the read/write path without an App
    /// Group container, which a test process does not necessarily have.
    public nonisolated(unsafe) static var containerOverride: URL?

    public static func containerURL(
        fileManager: FileManager = .default
    ) -> URL? {
        containerOverride ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    public static func avatarURL(named file: String, fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?
            .appendingPathComponent(avatarsDirectory, isDirectory: true)
            .appendingPathComponent(file)
    }

    public static func load(fileManager: FileManager = .default) -> InstantWidgetSnapshot {
        guard let url = containerURL(fileManager: fileManager)?.appendingPathComponent(snapshotName),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(InstantWidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    public static func save(
        _ snapshot: InstantWidgetSnapshot,
        fileManager: FileManager = .default
    ) throws {
        guard let container = containerURL(fileManager: fileManager) else { return }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: container.appendingPathComponent(snapshotName), options: .atomic)
    }

    public static func avatarFileName(for userId: Int) -> String { "\(userId).img" }

    @discardableResult
    public static func writeAvatar(
        _ data: Data,
        for userId: Int,
        fileManager: FileManager = .default
    ) -> String? {
        guard let container = containerURL(fileManager: fileManager) else { return nil }
        let directory = container.appendingPathComponent(avatarsDirectory, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = avatarFileName(for: userId)
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Drops cached pictures for people who are no longer waiting, so the
    /// container does not grow without bound.
    public static func pruneAvatars(keeping userIds: Set<Int>, fileManager: FileManager = .default) {
        guard let container = containerURL(fileManager: fileManager) else { return }
        let directory = container.appendingPathComponent(avatarsDirectory, isDirectory: true)
        let keep = Set(userIds.map(avatarFileName(for:)))
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !keep.contains(file) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    public static func clear(fileManager: FileManager = .default) {
        try? save(.empty, fileManager: fileManager)
        pruneAvatars(keeping: [], fileManager: fileManager)
    }
}
