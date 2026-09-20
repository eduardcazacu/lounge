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
                // The picture goes here rather than inside the view: a widget's
                // content is inset by the system's margins, and only the
                // container background reaches the widget's own edges.
                .containerBackground(for: .widget) { InstantWidgetBackground(entry: entry) }
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
        let policy: TimelineReloadPolicy = WidgetTimeline.nextRefresh(after: entries).map { .after($0) } ?? .never
        completion(Timeline(entries: entries, policy: policy))
    }
}
