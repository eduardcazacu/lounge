#if canImport(UIKit)
import PhotosUI
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: SettingsModel?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsDeleteAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                InstantStyle.background.ignoresSafeArea()

                if let model {
                    Form {
                        identitySection(model)
                        profileSection(model)
                        notificationsSection(model)
                        safetySection
                        deviceSection
                        aboutSection
                        accountSection
                    }
                    .scrollContentBackground(.hidden)
                    .tint(.white)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Refresh the shared account afterwards so the camera's
                    // profile button reflects the change straight away.
                    Button("Save") {
                        Task {
                            await model?.save()
                            await environment.loadAccount()
                        }
                    }
                        .tint(.white)
                        .fontWeight(.semibold)
                        .disabled(model?.isSaving ?? true)
                        .accessibilityIdentifier("settings.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsDeleteAccount) { DeleteAccountScreen() }
        .task {
            if model == nil { model = SettingsModel(userAPI: environment.userAPI) }
            await model?.load()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await model?.uploadProfilePicture(image)
                    await environment.loadAccount()
                }
                pickerItem = nil
            }
        }
    }

    private func identitySection(_ model: SettingsModel) -> some View {
        Section {
            HStack(spacing: 14) {
                AvatarView(
                    name: model.profile?.name ?? "",
                    themeKey: model.themeKey,
                    url: model.profilePictureUrl,
                    size: 62
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.profile?.name ?? "—")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(InstantStyle.primaryText)
                        .accessibilityIdentifier("settings.name")
                    Text(model.profile?.email ?? "")
                        .font(.caption)
                        .foregroundStyle(InstantStyle.secondaryText)
                }
                Spacer()
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Change picture")
            }
            .accessibilityIdentifier("settings.changePicture")

            if model.profilePictureUrl != nil {
                Button("Remove picture", role: .destructive) {
                    Task {
                        await model.removeProfilePicture()
                        await environment.loadAccount()
                    }
                }
            }
        } footer: {
            // Worth saying rather than letting someone hunt for a field that
            // does not exist: the API has no endpoint that changes `name`.
            Text("Your display name is set when your account is created and can't be changed here.")
        }
        .listRowBackground(InstantStyle.surface)
    }

    private func profileSection(_ model: SettingsModel) -> some View {
        Section("Profile") {
            TextField(
                "Bio",
                text: Binding(get: { model.bio }, set: { model.bio = String($0.prefix(100)) }),
                axis: .vertical
            )
            .lineLimit(1...3)
            .foregroundStyle(InstantStyle.primaryText)
            .accessibilityIdentifier("settings.bio")

            Picker("Theme", selection: Binding(get: { model.themeKey }, set: { model.themeKey = $0 })) {
                ForEach(ThemePalette.all, id: \.key) { palette in
                    HStack {
                        Circle().fill(palette.accent).frame(width: 14, height: 14)
                        Text(palette.label)
                    }
                    .tag(palette.key)
                }
            }
            .accessibilityIdentifier("settings.theme")

            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(InstantStyle.unread)
            }
        }
        .listRowBackground(InstantStyle.surface)
    }

    private func notificationsSection(_ model: SettingsModel) -> some View {
        Section {
            Toggle(
                "Push notifications",
                isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { enabled in Task { await model.setNotifications(enabled) } }
                )
            )
            // Its own tint, not the form's white: an "on" switch fills its
            // track with the tint, and a white track swallows the white knob.
            .tint(.green)
            .accessibilityIdentifier("settings.notifications")
        } footer: {
            Text("A notification tells you an instant arrived and who sent it. It never carries the photo — the server can't read it either.")
        }
        .listRowBackground(InstantStyle.surface)
    }

    /// Guideline 1.2 asks for published contact information alongside the
    /// tools for reporting and blocking, so all of it lives together.
    private var safetySection: some View {
        Section {
            NavigationLink {
                BlockedPeopleScreen()
            } label: {
                Label("Blocked people", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settings.blocked")

            Link(destination: environment.config.webAppURL.appendingPathComponent("terms")) {
                Label("Community Guidelines", systemImage: "doc.text")
            }
            Link(destination: environment.config.webAppURL.appendingPathComponent("privacy")) {
                Label("Privacy Policy", systemImage: "lock.shield")
            }
            Link(destination: URL(string: "mailto:\(AppConfig.supportEmail)")!) {
                Label("Contact support", systemImage: "envelope")
            }
            .accessibilityIdentifier("settings.support")
        } header: {
            Text("Safety & support")
        } footer: {
            Text("To report someone, press and hold them in your conversations, or tap ••• on a photo they sent.")
        }
        .foregroundStyle(InstantStyle.primaryText)
        .listRowBackground(InstantStyle.surface)
    }

    private var deviceSection: some View {
        Section {
            if let device = environment.store.device {
                LabeledContent("Device key") {
                    Text(device.isSecureEnclaveBacked ? "Secure Enclave" : "This device only")
                        .foregroundStyle(InstantStyle.secondaryText)
                }
                .accessibilityIdentifier("settings.deviceKey")
                LabeledContent("Device ID") {
                    Text(device.deviceId.prefix(8) + "…")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(InstantStyle.secondaryText)
                }
            }
        } header: {
            Text("This device")
        } footer: {
            Text("Instant's private key is made on this device and never leaves it. There is no recovery: reinstalling makes a new key, and anything already sent to the old one can't be opened.")
        }
        .listRowBackground(InstantStyle.surface)
    }

    /// The update notes are shown once and then gone, so this is the way back
    /// to them.
    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                WhatsNewScreen(notes: environment.whatsNew.notes)
                    .toolbarBackground(InstantStyle.background, for: .navigationBar)
            } label: {
                Label("What's new in \(environment.whatsNew.notes.version)", systemImage: "sparkles")
            }
            .accessibilityIdentifier("settings.whatsNew")

            LabeledContent("Version") {
                Text(Self.appVersion)
                    .foregroundStyle(InstantStyle.secondaryText)
            }
        }
        .foregroundStyle(InstantStyle.primaryText)
        .listRowBackground(InstantStyle.surface)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var accountSection: some View {
        Section {
            Button("Sign out", role: .destructive) {
                Task {
                    await environment.signOut()
                    dismiss()
                }
            }
            .accessibilityIdentifier("settings.signOut")

            Button("Delete account", role: .destructive) {
                showsDeleteAccount = true
            }
            .accessibilityIdentifier("settings.deleteAccount")
        }
        .listRowBackground(InstantStyle.surface)
    }
}
#endif
