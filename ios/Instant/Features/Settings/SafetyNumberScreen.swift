#if canImport(UIKit)
import SwiftUI

struct SafetyNumberScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let peerUserId: Int
    let peerName: String

    @State private var model: SafetyNumberModel?

    var body: some View {
        NavigationStack {
            ZStack {
                InstantStyle.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let model {
                            if model.keysChanged {
                                banner(
                                    "\(peerName)'s keys changed",
                                    detail: "That happens when someone reinstalls or adds a device. If they didn't, compare the number below out loud before sending anything private."
                                )
                            }

                            if let number = model.safetyNumber {
                                Text(number)
                                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(InstantStyle.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 14).fill(InstantStyle.surfaceRaised)
                                    )
                                    .accessibilityIdentifier("safety.number")
                            }

                            if let error = model.errorMessage {
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(InstantStyle.unread)
                            }

                            Text(
                                """
                                Read these digits to \(peerName) in person or over a call you trust. \
                                If they match, nobody is sitting between you.

                                Instant asks the server for everyone's public keys, and a server \
                                that wanted to read your photos could hand out its own key instead. \
                                Comparing this number is the only thing that catches that.
                                """
                            )
                            .font(.footnote)
                            .foregroundStyle(InstantStyle.secondaryText)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Safety number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if model == nil, let userId = environment.session.currentUserId {
                model = SafetyNumberModel(
                    api: environment.instantAPI,
                    fingerprints: PeerFingerprintStore(),
                    currentUserId: userId,
                    peerUserId: peerUserId
                )
            }
            await model?.load()
        }
    }

    private func banner(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(detail).font(.footnote)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(InstantStyle.unread.opacity(0.22)))
        .accessibilityIdentifier("safety.changed")
    }
}
#endif
