#if canImport(UIKit)
import SwiftUI

struct SignInView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: SignInModel?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(InstantStyle.primaryText)
                    Text("Instant")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(InstantStyle.primaryText)
                        .accessibilityIdentifier("signIn.header")
                    Text("Eddie's Lounge")
                        .font(.subheadline)
                        .foregroundStyle(InstantStyle.secondaryText)
                }

                if let model {
                    VStack(spacing: 12) {
                        field("Email", text: Binding(get: { model.email }, set: { model.email = $0 }))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .accessibilityIdentifier("signIn.email")

                        secureField(
                            "Password",
                            text: Binding(get: { model.password }, set: { model.password = $0 })
                        )
                        .focused($focus, equals: .password)
                        .accessibilityIdentifier("signIn.password")

                        if let message = model.errorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(InstantStyle.unread)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityIdentifier("signIn.error")
                        }

                        Button {
                            focus = nil
                            Task { await signIn(model) }
                        } label: {
                            Group {
                                if model.isSubmitting {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Log In").font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.plain)
                        .background(model.canSubmit ? Color.white : Color(white: 0.3))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("signIn.submit")
                    }
                    .padding(.horizontal, 28)
                }

                Spacer()

                // Signing up needs an email verification link and then admin
                // approval, both of which happen on the web. Sending people
                // there beats an in-app form that can only ever end on a
                // "waiting for approval" screen.
                VStack(spacing: 6) {
                    Link("Create an account", destination: environment.config.webAppURL.appendingPathComponent("signup"))
                    Link("Forgot password", destination: environment.config.webAppURL.appendingPathComponent("forgot-password"))
                }
                .font(.footnote)
                .foregroundStyle(InstantStyle.secondaryText)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            if model == nil { model = SignInModel(userAPI: environment.userAPI) }
        }
    }

    private func signIn(_ model: SignInModel) async {
        guard let token = await model.submit() else { return }
        await environment.handleSignIn(token: token)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(title).foregroundStyle(InstantStyle.secondaryText))
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(InstantStyle.surfaceRaised)
            .foregroundStyle(InstantStyle.primaryText)
            .clipShape(Capsule())
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField("", text: text, prompt: Text(title).foregroundStyle(InstantStyle.secondaryText))
            .textContentType(.password)
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(InstantStyle.surfaceRaised)
            .foregroundStyle(InstantStyle.primaryText)
            .clipShape(Capsule())
    }
}
#endif
