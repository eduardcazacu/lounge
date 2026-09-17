#if canImport(UIKit)
import SwiftUI

struct WhatsNewScreen: View {
    let notes: WhatsNew
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Text("What's new in \(notes.version)")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(InstantStyle.primaryText)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("whatsNew.title")

                        section(notes.features)

                        if !notes.fixes.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Fixed")
                                    .font(.headline)
                                    .foregroundStyle(InstantStyle.secondaryText)
                                    .accessibilityAddTraits(.isHeader)
                                section(notes.fixes)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .background(Color.white)
                .foregroundStyle(.black)
                .clipShape(Capsule())
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .accessibilityIdentifier("whatsNew.continue")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(_ items: [WhatsNew.Item]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(InstantStyle.flame)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(InstantStyle.primaryText)
                        Text(item.detail)
                            .font(.subheadline)
                            .foregroundStyle(InstantStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
#endif
