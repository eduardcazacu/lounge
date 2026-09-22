#if canImport(UIKit)
import SwiftUI

/// Report someone. Presented from the viewer (with the photo available to
/// attach) and from a conversation row (without).
struct ReportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var model: ReportModel
    let termsURL: URL
    /// Called once the report is in, with whether the person was blocked too.
    let onSubmitted: (_ blocked: Bool) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                InstantStyle.background.ignoresSafeArea()

                Form {
                    Section {
                        ForEach(ReportReason.allCases) { reason in
                            Button {
                                model.reason = reason
                            } label: {
                                HStack {
                                    Text(reason.label)
                                        .foregroundStyle(InstantStyle.primaryText)
                                    Spacer()
                                    if model.reason == reason {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(InstantStyle.primaryText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("report.reason.\(reason.rawValue)")
                            .accessibilityAddTraits(model.reason == reason ? .isSelected : [])
                        }
                    } header: {
                        Text("What's wrong?")
                    }
                    .listRowBackground(InstantStyle.surface)

                    Section {
                        TextField("Anything else we should know (optional)", text: $model.details, axis: .vertical)
                            .lineLimit(2...5)
                            .foregroundStyle(InstantStyle.primaryText)
                            .accessibilityIdentifier("report.details")
                    }
                    .listRowBackground(InstantStyle.surface)

                    Section {
                        if model.canAttachPhoto {
                            Toggle(model.attachLabel, isOn: $model.includesPhoto)
                                .tint(.green)
                                .accessibilityIdentifier("report.includePhoto")
                        }
                        Toggle("Also block \(model.reportedName)", isOn: $model.alsoBlock)
                            .tint(.green)
                            .accessibilityIdentifier("report.alsoBlock")
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.canAttachPhoto {
                                Text("Photos are end-to-end encrypted, so we can't see them. Including it sends a copy to the moderators, who delete it once the report is dealt with.")
                            }
                            Text("Blocking stops you from seeing or sending to each other. Reports are reviewed within 24 hours.")
                        }
                    }
                    .listRowBackground(InstantStyle.surface)

                    if let error = model.errorMessage {
                        Section {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(InstantStyle.unread)
                                .accessibilityIdentifier("report.error")
                        }
                        .listRowBackground(InstantStyle.surface)
                    }

                    Section {
                        Button("Community Guidelines") { openURL(termsURL) }
                            .foregroundStyle(InstantStyle.secondaryText)
                    }
                    .listRowBackground(InstantStyle.background)
                }
                .scrollContentBackground(.hidden)
                .tint(.white)
            }
            .navigationTitle("Report \(model.reportedName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(InstantStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(.white)
                        .accessibilityIdentifier("report.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Button("Send") {
                            Task {
                                if await model.submit() {
                                    onSubmitted(model.alsoBlock)
                                    dismiss()
                                }
                            }
                        }
                        .tint(.white)
                        .fontWeight(.semibold)
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("report.send")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isSubmitting)
    }
}
#endif

#if canImport(UIKit)
extension ReportModel: @MainActor Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
#endif
