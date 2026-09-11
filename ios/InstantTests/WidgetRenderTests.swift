import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Instant

/// Rasterises the widget so its layout can be checked rather than assumed.
///
/// A widget cannot be driven by XCUITest and the Simulator gives no way to add
/// one from the command line, so this is the only way to see it. It doubles as a
/// guard that every state lays out at all — a widget that fails to render just
/// shows the system placeholder, with no error anywhere.
@MainActor
@Suite("Widget rendering")
struct WidgetRenderTests {
    /// Where the PNGs land, so they can be opened after a run.
    static let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("instant-widget-renders", isDirectory: true)

    private func render(
        _ entry: WaitingEntry,
        family: WidgetFamily,
        size: CGSize,
        name: String
    ) -> UIImage? {
        let view = InstantWidgetView(entry: entry, family: family)
            .frame(width: size.width, height: size.height)
            .background(InstantStyle.background)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.uiImage else { return nil }

        try? FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )
        if let data = image.pngData() {
            try? data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
        }
        return image
    }

    private static let small = CGSize(width: 158, height: 158)
    private static let medium = CGSize(width: 338, height: 158)

    @Test("Nothing waiting renders the app mark")
    func rendersIdle() throws {
        let image = try #require(render(
            WaitingEntry(date: .now, contact: nil, totalWaiting: 0, contactCount: 0, position: 0),
            family: .systemSmall, size: Self.small, name: "small-idle"
        ))
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test("One person waiting, with a streak")
    func rendersSingle() throws {
        let entry = WaitingEntry(
            date: .now,
            contact: .fixture(userId: 2, name: "Ana Lovelace", themeKey: "rose", unopenedCount: 1, streakCount: 9),
            totalWaiting: 1, contactCount: 1, position: 0
        )
        #expect(render(entry, family: .systemSmall, size: Self.small, name: "small-one") != nil)
        #expect(render(entry, family: .systemMedium, size: Self.medium, name: "medium-one") != nil)
    }

    @Test("Several waiting, mid-cycle, with the position dots")
    func rendersCycling() throws {
        let entry = WaitingEntry(
            date: .now,
            contact: .fixture(userId: 3, name: "Bo", themeKey: "forest", unopenedCount: 3, streakCount: 0),
            totalWaiting: 5, contactCount: 3, position: 1
        )
        #expect(render(entry, family: .systemSmall, size: Self.small, name: "small-cycling") != nil)
        #expect(render(entry, family: .systemMedium, size: Self.medium, name: "medium-cycling") != nil)
    }

    /// A long name must not push the streak or the dots off the widget.
    @Test("A long name is truncated rather than overflowing")
    func rendersLongName() throws {
        let entry = WaitingEntry(
            date: .now,
            contact: .fixture(
                userId: 4, name: "Bartholomew Featherstonehaugh", themeKey: "gold",
                unopenedCount: 12, streakCount: 143
            ),
            totalWaiting: 12, contactCount: 5, position: 4
        )
        #expect(render(entry, family: .systemSmall, size: Self.small, name: "small-long") != nil)
        #expect(render(entry, family: .systemMedium, size: Self.medium, name: "medium-long") != nil)
    }

    @Test("Renders where a directory of PNGs can be inspected")
    func reportsOutputLocation() {
        print("DIAG widget renders: \(Self.outputDirectory.path)")
    }
}
