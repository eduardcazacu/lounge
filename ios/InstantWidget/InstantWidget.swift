import SwiftUI
import WidgetKit

@main
struct InstantWidgetBundle: WidgetBundle {
    var body: some Widget {
        InstantWaitingWidget()
    }
}

struct InstantWaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: InstantWidgetStore.widgetKind, provider: WaitingProvider()) { entry in
            InstantWidgetView(entry: entry)
                .containerBackground(InstantStyle.background, for: .widget)
        }
        .configurationDisplayName("Instant")
        .description("Shows who has sent you an instant.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WaitingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaitingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (WaitingEntry) -> Void) {
        completion(WidgetTimeline.entries(from: InstantWidgetStore.load(), now: .now).first ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaitingEntry>) -> Void) {
        let now = Date.now
        let entries = WidgetTimeline.entries(from: InstantWidgetStore.load(), now: now)
        completion(Timeline(
            entries: entries,
            policy: .after(now.addingTimeInterval(WidgetTimeline.refreshWindow))
        ))
    }

}
