#if canImport(UIKit)
import SwiftUI

/// The edit surface: the photo sits in the same rounded 16:9 viewport the camera
/// framed it in, tools sit in a right-hand rail, and "Send To" is bottom-right —
/// the Snapchat arrangement.
struct ComposeScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let image: UIImage
    let onDiscard: () -> Void

    @State private var model: ComposeModel?
    @State private var isEditingCaption = false
    @State private var showsRecipients = false
    @State private var showsFilters = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            if let model {
                // The same rounded 16:9 rectangle the camera framed the shot
                // in, in the same place on screen: reviewing a photo in a
                // different window from the one it was taken through is how the
                // sender ends up surprised by what they sent.
                GeometryReader { proxy in
                    let frame = Self.fittedRect(image: model.preview, in: proxy.size)

                    ZStack(alignment: .topLeading) {
                        // The filtered copy, not the original: a look chosen
                        // against a picture that is not the one being sent is
                        // not a choice at all.
                        Image(uiImage: model.preview)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .accessibilityIdentifier("compose.preview")

                        if !model.caption.isEmpty {
                            captionOverlay(model, in: frame)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .aspectRatio(InstantStyle.viewportAspectRatio, contentMode: .fit)
                .clipShape(InstantStyle.viewportShape)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

                ViewportOverlay {
                    VStack {
                        // Top-aligned, so the cross sits on the viewport's top
                        // line with the first tool opposite it — the line the
                        // camera's own controls are on, which is what makes the
                        // two screens read as one surface.
                        HStack(alignment: .top) {
                            CircleIconButton(systemName: "xmark") { onDiscard() }
                                .accessibilityIdentifier("compose.discard")
                            Spacer()
                            toolRail(model)
                        }
                        Spacer()
                        if showsFilters {
                            filterStrip(model)
                                .padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        bottomBar(model)
                    }
                    .animation(.easeOut(duration: 0.2), value: showsFilters)
                }

                if isEditingCaption {
                    captionEditor(model)
                }
            }
        }
        .task {
            if model == nil {
                model = ComposeModel(
                    image: image,
                    instantAPI: environment.instantAPI,
                    senderUserId: environment.session.currentUserId ?? 0,
                    recipient: environment.aimedAt
                )
            }
        }
        .sheet(isPresented: $showsRecipients) {
            if let model {
                SendToScreen(model: model, onSent: onDiscard)
            }
        }
    }

    // MARK: - Pieces

    private func toolRail(_ model: ComposeModel) -> some View {
        VStack(spacing: 12) {
            CircleIconButton(systemName: "textformat") {
                isEditingCaption = true
                captionFocused = true
            }
            .accessibilityIdentifier("compose.caption")

            CircleIconButton(systemName: "camera.filters", isOn: showsFilters) {
                // The renders happen here, on the tap that asks for them,
                // rather than on every capture.
                if !showsFilters { model.prepareThumbnails() }
                showsFilters.toggle()
            }
            .accessibilityIdentifier("compose.filters")
            .accessibilityLabel("Filters")
            .accessibilityValue(model.filter.name)

            Button {
                model.cycleDuration()
            } label: {
                Text(model.duration.label)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("compose.duration")
            .accessibilityValue(model.duration.rawValue)
        }
    }

    /// The looks, as thumbnails of this photo rather than swatches — the only
    /// way to pick one without applying it first. Horizontal, under the photo
    /// and over the bottom bar, so the picture stays the biggest thing on
    /// screen while it is being chosen.
    private func filterStrip(_ model: ComposeModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.filterThumbnails) { thumbnail in
                    Button {
                        model.select(thumbnail.filter)
                    } label: {
                        filterSwatch(thumbnail, isSelected: model.filter == thumbnail.filter)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compose.filter.\(thumbnail.filter.rawValue)")
                    .accessibilityLabel(thumbnail.filter.name)
                    .accessibilityAddTraits(
                        model.filter == thumbnail.filter ? [.isSelected] : []
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(height: 96)
        .accessibilityIdentifier("compose.filterStrip")
    }

    private func filterSwatch(
        _ thumbnail: ComposeModel.FilterThumbnail,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 5) {
            Image(uiImage: thumbnail.image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white : Color.white.opacity(0.25),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
            Text(thumbnail.filter.name)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .white : Color(white: 0.72))
        }
        // The strip sits over the photo, which can be any colour.
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
    }

    private func bottomBar(_ model: ComposeModel) -> some View {
        HStack {
            if case .failed(let message) = model.sendState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(InstantStyle.unread.opacity(0.85)))
                    .accessibilityIdentifier("compose.error")
            }

            Spacer()

            // An aimed capture still has to be redirectable: the only other way
            // out of a wrong recipient would be discarding the photo.
            if model.recipient != nil {
                CircleIconButton(systemName: "person.2.fill") { showsRecipients = true }
                    .disabled(model.isSending)
                    .accessibilityIdentifier("compose.changeRecipient")
                    .accessibilityLabel("Send to somebody else")
                    .padding(.trailing, 10)
            }

            Button {
                if let recipient = model.recipient {
                    Task { await send(model, to: recipient.userId) }
                } else {
                    showsRecipients = true
                }
            } label: {
                HStack(spacing: 8) {
                    // Named rather than "Send To" when the camera was opened
                    // from a conversation: the recipient was chosen before the
                    // photo existed, so the button confirms it instead of
                    // asking the question again.
                    Text(model.recipient.map { "Send to \($0.name)" } ?? "Send To")
                        .font(.system(size: 16, weight: .bold))
                    if model.isSending {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(model.isSending)
            .accessibilityIdentifier("compose.sendTo")
        }
    }

    /// The one-tap path, for a capture that already knows who it is for. The
    /// picker's own send goes through `SendToScreen`, and both finish the same
    /// way: the aim is spent, the send is recorded so the inbox reorders without
    /// waiting on the server, and the camera comes back.
    private func send(_ model: ComposeModel, to recipientId: Int) async {
        await model.send(to: recipientId)
        guard case .sent = model.sendState else { return }
        environment.clearAim()
        environment.store.noteSent(toUserId: recipientId)
        await environment.store.refreshHistory()
        onDiscard()
    }

    /// The overlay is positioned against the *image* rect, not the container.
    /// Anchoring to the container puts the caption somewhere different once the
    /// photo is letterboxed, so what the sender framed is not what arrives.
    private func captionOverlay(_ model: ComposeModel, in frame: CGRect) -> some View {
        let fontSize = OverlayCompositor.fontSize(forWidth: Double(frame.width))
        return Text(model.caption)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(fontSize * 0.4)
            .background(
                RoundedRectangle(cornerRadius: fontSize * 0.3)
                    .fill(Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255).opacity(0.55))
            )
            .frame(maxWidth: frame.width * 0.9)
            .position(
                x: frame.minX + frame.width * model.placement.x,
                y: frame.minY + frame.height * model.placement.y
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        model.placement = OverlayCompositor.Placement(
                            x: (value.location.x - frame.minX) / frame.width,
                            y: (value.location.y - frame.minY) / frame.height
                        )
                    }
            )
            .accessibilityIdentifier("compose.captionOverlay")
    }

    private func captionEditor(_ model: ComposeModel) -> some View {
        VStack {
            Spacer()
            TextField(
                "",
                text: Binding(get: { model.caption }, set: { model.setCaption($0) }),
                prompt: Text("Add a caption").foregroundStyle(Color(white: 0.7))
            )
            .focused($captionFocused)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
            .background(Color.black.opacity(0.75))
            .submitLabel(.done)
            .onSubmit { isEditingCaption = false }
            .accessibilityIdentifier("compose.captionField")
            Spacer()
        }
        .background(Color.black.opacity(0.45).ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { isEditingCaption = false }
    }

    /// Where a `.scaledToFit` image actually lands inside its container.
    static func fittedRect(image: UIImage, in container: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0
        else { return CGRect(origin: .zero, size: container) }

        let scale = min(container.width / image.size.width, container.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
#endif
