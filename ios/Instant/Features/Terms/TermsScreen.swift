#if canImport(UIKit)
import SwiftUI

/// The Community Guidelines, agreed to once per account before anything else.
///
/// Guideline 1.2 asks that people accept terms making clear there is no
/// tolerance for objectionable content or abusive users. This cannot be swiped
/// away: the only ways out are agreeing or signing out.
struct TermsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let rules: [(symbol: String, text: String)] = [
        ("exclamationmark.bubble.fill", "No harassment, bullying, threats or hate."),
        ("eye.slash.fill", "Don't share anyone's private information or photos without their consent."),
        ("xmark.shield.fill", "No spam, scams, or anything illegal."),
    ]

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Community Guidelines")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .foregroundStyle(InstantStyle.primaryText)
                                .accessibilityIdentifier("terms.title")
                            Text("Instant is for friends. There is zero tolerance for objectionable content or abusive people.")
                                .font(.body)
                                .foregroundStyle(InstantStyle.secondaryText)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(rules, id: \.text) { rule in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: rule.symbol)
                                        .font(.system(size: 18))
                                        .foregroundStyle(InstantStyle.flame)
                                        .frame(width: 26)
                                    Text(rule.text)
                                        .foregroundStyle(InstantStyle.primaryText)
                                }
                            }
                        }

                        Text("If someone breaks these rules, report them from the photo or from your conversations, and block them if you want. Reports are reviewed within 24 hours, and accounts that break the rules are removed.")
                            .font(.subheadline)
                            .foregroundStyle(InstantStyle.secondaryText)

                        Button("Read the full Terms & Community Guidelines") {
                            openURL(environment.config.webAppURL.appendingPathComponent("terms"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(InstantStyle.primaryText)
                        .accessibilityIdentifier("terms.readFull")
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                }

                VStack(spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(InstantStyle.unread)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await agree() }
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView().tint(.black)
                            } else {
                                Text("I agree").font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        // Hit-tested from the label, not from the capsule the
                        // modifiers below paint — see SignInView.
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("terms.agree")

                    Button("Sign out") {
                        Task { await environment.signOut() }
                    }
                    .font(.footnote)
                    .foregroundStyle(InstantStyle.secondaryText)
                    .accessibilityIdentifier("terms.signOut")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func agree() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await environment.acceptTerms()
        } catch {
            errorMessage = "Couldn't save that. Check your connection and try again."
        }
    }
}
#endif
