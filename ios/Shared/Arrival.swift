import Foundation

/// The parts of an Instant push the widget needs.
///
/// A streak-warning push carries no sender, so it parses to nil and is passed
/// straight through.
public struct Arrival {
    public let senderId: Int
    public let name: String
    public let themeKey: String
    public let profilePictureUrl: String?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let data = userInfo["data"] as? [String: Any],
              let senderId = Arrival.integer(data["senderId"])
        else { return nil }

        self.senderId = senderId
        self.name = (data["senderName"] as? String) ?? "Someone"
        self.themeKey = (data["senderThemeKey"] as? String) ?? ""
        self.profilePictureUrl = data["senderProfilePictureUrl"] as? String
    }

    /// APNs JSON can hand back a number as either, depending on the encoder.
    public static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
