#if canImport(UIKit)
import SwiftUI

/// The edit surface: the photo fills the screen, tools sit in a right-hand rail,
/// and "Send To" is bottom-right — the Snapchat arrangement.
struct ComposeScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let image: UIImage
    let onDiscard: () -> Void

    @State private var model: ComposeModel?
    @State private var isEditingCaption = false
    @State private var showsRecipients = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                GeometryReader { proxy in
                    let frame = Self.fittedRect(image: image, in: proxy.size)

                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)

                        if !model.caption.isEmpty {
                            captionOverlay(model, in: frame)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()

                VStack {
                    HStack {
                        CircleIconButton(systemName: "xmark") { onDiscard() }
                            .accessibilityIdentifier("compose.discard")
                        Spacer()
                        toolRail(model)
                    }
                    Spacer()
                    bottomBar(model)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)

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
                    senderUserId: environment.session.currentUserId ?? 0
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

            Button {
                showsRecipients = true
            } label: {
                HStack(spacing: 8) {
                    Text("Send To").font(.system(size: 16, weight: .bold))
                    Image(systemName: "paperplane.fill")
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
