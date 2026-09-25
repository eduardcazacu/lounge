#if canImport(UIKit)
import SwiftUI

/// What the journey timings say, and the way to get them off the phone.
///
/// The export is the point. The summary here is only enough to tell at a
/// glance whether there is anything worth exporting; the real reading is done
/// on a Mac by `ios/tools/journey-report.swift`, which splits each journey by
/// the attributes that change it (cold or warm, photo or clip).
struct TimingsScreen: View {
    @State private var records: [JourneyRecord] = []
    @State private var confirmsClear = false

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()
            List {
                Section {
                    if summaries.isEmpty {
                        Text("Nothing timed yet. Open the app from a notification, take a photo, send it — then come back.")
                            .foregroundStyle(InstantStyle.secondaryText)
                    }
                    ForEach(summaries, id: \.name) { summary in
                        LabeledContent(summary.name) {
                            Text("n=\(summary.count) · p50 \(summary.p50) ms · p90 \(summary.p90) ms")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(InstantStyle.secondaryText)
                        }
                    }
                } header: {
                    Text("Completed journeys")
                } footer: {
                    Text("Kept on this device only, and never sent anywhere. Export shares the raw file.")
                }
                .listRowBackground(InstantStyle.surface)

                if !records.isEmpty {
                    Section("Most recent") {
                        ForEach(Array(records.suffix(30).reversed().enumerated()), id: \.offset) { _, record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(record.journey.rawValue) · \(record.outcome) · \(record.totalMs) ms")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(InstantStyle.primaryText)
                                Text(record.marks.map { "\($0.name) \($0.ms)" }.joined(separator: " → "))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(InstantStyle.secondaryText)
                            }
                        }
                    }
                    .listRowBackground(InstantStyle.surface)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Timings")
        .toolbarBackground(InstantStyle.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = JourneyLog.shared.exportURL, !records.isEmpty {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export timings")
                    .accessibilityIdentifier("timings.export")
                }
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(records.isEmpty)
                .accessibilityLabel("Clear timings")
            }
        }
        .confirmationDialog("Clear every recorded timing?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                JourneyLog.shared.clear()
                records = []
            }
        }
        .task {
            // Reads the whole file; kept off the main actor.
            records = await Task.detached(priority: .userInitiated) {
                JourneyLog.shared.records()
            }.value
        }
    }

    private struct Summary {
        let name: String
        let count: Int
        let p50: Int
        let p90: Int
    }

    /// Successful journeys only (`JourneyLog.successes`), per kind.
    private var summaries: [Summary] {
        let grouped = Dictionary(grouping: records.filter { JourneyLog.successes.contains($0.outcome) }, by: \.journey)
        return Journey.allCases.compactMap { journey in
            guard let totals = grouped[journey]?.map(\.totalMs).sorted(), !totals.isEmpty else { return nil }
            return Summary(
                name: journey.rawValue,
                count: totals.count,
                p50: Self.percentile(totals, 0.5),
                p90: Self.percentile(totals, 0.9)
            )
        }
    }

    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
}
#endif
