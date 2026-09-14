#if canImport(UIKit)
import SwiftUI

struct BlockedPeopleScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: BlockedPeopleModel?

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            if let model {
                List {
                    if model.hasLoaded && model.blocked.isEmpty {
                        Text("You haven't blocked anyone.")
                            .foregroundStyle(InstantStyle.secondaryText)
                            .listRowBackground(InstantStyle.surface)
                            .accessibilityIdentifier("blocked.empty")
                    }

                    ForEach(model.blocked) { user in
                        HStack(spacing: 12) {
                            AvatarView(
                                name: user.displayName,
                                themeKey: user.themeKey,
                                url: user.profilePictureUrl,
                                size: 40
                            )
                            Text(user.displayName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(InstantStyle.primaryText)
                            Spacer()
                            Button("Unblock") {
                                Task {
                                    await model.unblock(user)
                                    // They can show up in conversations again.
                                    await environment.store.refreshHistory()
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .accessibilityIdentifier("blocked.unblock.\(user.displayName)")
                        }
                        .listRowBackground(InstantStyle.surface)
                    }

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(InstantStyle.unread)
                            .listRowBackground(InstantStyle.surface)
                    }
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if model.isLoading && !model.hasLoaded {
                        ProgressView().tint(.white)
                    }
                }
            }
        }
        .navigationTitle("Blocked people")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = BlockedPeopleModel(api: environment.moderationAPI) }
            await model?.load()
        }
    }
}
#endif
