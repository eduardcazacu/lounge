import UserNotifications
import WidgetKit

/// Runs on delivery of every Instant push, before the banner is shown.
///
/// Its only job is to keep the home-screen widget honest while the app is
/// closed. Nothing else can: an alert push does not wake the app, and the widget
/// cannot fetch for itself — it has no access token and no way to renew one.
///
/// It reads no media and decrypts nothing. Everything it uses is in the payload,
/// which carries the sender's name and theme but never key material.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        handler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        content = mutable

        if let arrival = Arrival(userInfo: request.content.userInfo) {
            let updated = InstantWidgetStore.load().addingArrival(
                senderId: arrival.senderId,
                name: arrival.name,
                themeKey: arrival.themeKey,
                profilePictureUrl: arrival.profilePictureUrl,
                now: Date()
            )
            try? InstantWidgetStore.save(updated)
            WidgetCenter.shared.reloadTimelines(ofKind: InstantWidgetStore.widgetKind)
        }

        // The banner is passed through untouched either way. A widget that could
        // not be updated must never cost someone their notification.
        contentHandler(mutable ?? request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content {
            handler(content)
        }
    }
}
