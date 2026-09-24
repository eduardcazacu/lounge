#if canImport(UIKit)
import SwiftUI

/// The edit surface: the photo sits in the same rounded 16:9 viewport the camera
/// framed it in, tools sit in a right-hand rail, and "Send To" is bottom-right —
/// the Snapchat arrangement.
struct ComposeScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let capture: Capture
    /// The cross: the capture is thrown away.
    let onDiscard: () -> Void
    /// Sent: the outbox has the capture now, and is what cleans up after it.
    let onSent: () -> Void

    @State private var model: ComposeModel?
    @State private var showsRecipients = false
    @State private var showsFilters = false

    /// The caption the keyboard is typing into. It is drawn by the editor
    /// rather than on the photo while it is, so it is never on screen twice.
    @State private var editingID: UUID?
    @FocusState private var captionFocused: Bool
    /// The photo's width on screen. Captions are sized from it, and the editor
    /// is outside the photo's own geometry, which is where it is measured.
    @State private var photoWidth: CGFloat = 0
    /// Where each caption is drawn, for finding the one a pinch meant.
    @State private var captionFrames: [UUID: CGRect] = [:]
    @State private var dragOrigin: OverlayCompositor.Placement?
    @State private var pinchTarget: GestureTarget?
    @State private var turnTarget: GestureTarget?
    /// The caption under the finger. While there is one, the chrome gives way
    /// to the trash, which is the only thing a dragged caption can be dropped on.
    @State private var draggingID: UUID?
    @State private var trashFrame: CGRect = .zero
    @State private var isOverTrash = false
    /// While on, the photo is a page to draw on: a finger draws instead of
    /// starting a caption, and every other tool steps aside.
    @State private var isDrawing = false
    /// Where the finger went down for the line being drawn. A new start is a
    /// new line; it is not left to `onEnded` alone, which a cancelled touch
    /// never reaches, and the next line would then join on to the last.
    @State private var strokeStart: CGPoint?

    /// The caption a two-finger gesture took hold of, and its value when it
    /// did: the gesture reports a total since it began, not a step.
    private struct GestureTarget {
        let id: UUID
        let start: Double
    }

    private static let photoSpace = "compose.photo"
    private static let prompt = "Add a caption"

    var body: some View {
        ZStack {
            InstantStyle.background.ignoresSafeArea()

            if let model {
                // The same rounded 16:9 rectangle the camera framed the shot
                // in, in the same place on screen: reviewing a photo in a
                // different window from the one it was taken through is how the
                // sender ends up surprised by what they sent.
                GeometryReader { proxy in
                    let frame = Self.fittedRect(size: model.contentSize, in: proxy.size)

                    ZStack(alignment: .topLeading) {
                        // The filtered copy, not the original: a look chosen
                        // against a picture that is not the one being sent is
                        // not a choice at all.
                        if let clip = model.clip {
                            LoopingVideoView(
                                url: clip.url,
                                filter: model.filter,
                                grain: model.grain,
                                isMuted: !model.includesSound
                            )
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .accessibilityElement()
                                .accessibilityLabel("Your video")
                                .accessibilityIdentifier("compose.video")
                        } else {
                            Image(uiImage: model.preview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .accessibilityIdentifier("compose.preview")
                        }

                        DrawingLayer(model: model, frame: frame)

                        ForEach(model.captions.filter { $0.id != editingID && !$0.trimmed.isEmpty }) {
                            captionOverlay($0, model, in: frame)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .coordinateSpace(.named(Self.photoSpace))
                    // Anywhere that is not already a caption starts a new one.
                    // A caption's own tap is nearer, so it wins on the caption.
                    //
                    // Drawing switches every other gesture off with `isEnabled`
                    // rather than outranking them. A tap that is merely
                    // outranked is still waited on, and it only fails when the
                    // finger lifts, so the whole line arrived at once.
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            beginEditing(model.addCaption(at: placement(of: value.location, in: frame)))
                        },
                        isEnabled: !isDrawing
                    )
                    // On the photo rather than on each caption: two fingers
                    // rarely both land on a line of text, so the pinch goes to
                    // the caption it started nearest.
                    .simultaneousGesture(pinch(model), isEnabled: !isDrawing)
                    .simultaneousGesture(turn(model), isEnabled: !isDrawing)
                    .gesture(draw(model, in: frame), isEnabled: isDrawing)
                    .onChange(of: frame.width, initial: true) { _, width in
                        photoWidth = width
                    }
                }
                .aspectRatio(InstantStyle.viewportAspectRatio, contentMode: .fit)
                .clipShape(InstantStyle.viewportShape)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

                if let editingID {
                    captionEditor(model, id: editingID)
                }

                ViewportOverlay {
                    VStack {
                        // Top-aligned, so the cross sits on the viewport's top
                        // line with the first tool opposite it — the line the
                        // camera's own controls are on, which is what makes the
                        // two screens read as one surface.
                        if draggingID != nil {
                            trash
                        } else {
                            HStack(alignment: .top) {
                                if editingID == nil && !isDrawing {
                                    CircleIconButton(systemName: "xmark") {
                                        model.close(sent: false)
                                        onDiscard()
                                    }
                                        .accessibilityIdentifier("compose.discard")
                                }
                                Spacer()
                                if isDrawing {
                                    UndoButton(model: model)
                                }
                                toolRail(model)
                            }
                        }
                        Spacer()
                        // While typing, the text button is the only control:
                        // everything else would be a way to leave the caption
                        // half-written.
                        if editingID == nil && draggingID == nil && !isDrawing {
                            if showsFilters {
                                filterStrip(model)
                                    .padding(.bottom, 14)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            bottomBar(model)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: showsFilters)
                    .animation(.easeOut(duration: 0.2), value: isDrawing)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: isOverTrash)
        .task {
            if model == nil {
                model = ComposeModel(
                    capture: capture,
                    recipient: environment.aimedAt,
                    preferences: environment.preferences,
                    photos: environment.photos
                )
            }
            // The look every capture starts in, drawn here rather than in the
            // model's initialiser: that runs inside the black the shutter
            // holds up, and a look costs a render.
            model?.showDefaultLook()
        }
        .sheet(isPresented: $showsRecipients) {
            if let model {
                SendToScreen(model: model, onSent: {
                    model.close(sent: true)
                    onSent()
                })
            }
        }
    }

    // MARK: - Pieces

    private func toolRail(_ model: ComposeModel) -> some View {
        VStack(spacing: 12) {
            if isDrawing {
                drawButton
                inkBar(model)
            } else {
                textButton(model)

                if editingID == nil {
                    drawButton
                    otherTools(model)
                }
            }
        }
    }

    /// Swaps the style of the caption being typed. With nothing being typed
    /// there is no style to swap, so it starts a caption in the middle of the
    /// photo — the way in for someone who has not found that the photo itself
    /// takes a tap.
    private func textButton(_ model: ComposeModel) -> some View {
        let editing = editingID.flatMap { model.caption($0) }
        // A different glyph while typing, because it is a different button:
        // the one that adds text is not the one that restyles it.
        return CircleIconButton(
            systemName: editing == nil ? "textformat" : "character.textbox",
            isOn: editing?.style == .plate
        ) {
            if let editing {
                model.toggleStyle(of: editing.id)
            } else {
                beginEditing(model.addCaption(at: OverlayCompositor.Placement(x: 0.5, y: 0.5)))
            }
        }
        .accessibilityIdentifier("compose.caption")
        .accessibilityLabel(editing == nil ? "Add text" : "Text style")
        .accessibilityValue(editing?.style.rawValue ?? "")
    }

    @ViewBuilder
    private func otherTools(_ model: ComposeModel) -> some View {
        CircleIconButton(systemName: "camera.filters", isOn: showsFilters) {
            // The renders happen here, on the tap that asks for them,
            // rather than on every capture.
            if !showsFilters { model.prepareThumbnails() }
            showsFilters.toggle()
        }
        .accessibilityIdentifier("compose.filters")
        .accessibilityLabel("Filters")
        .accessibilityValue(model.filter.name)

        if model.canMakeParallax {
            parallaxButton(model)
        }

        // A clip's sound, for the preview and for what is sent alike: off is
        // not a volume, it is the audio left out of the file.
        if model.hasSound {
            CircleIconButton(
                systemName: model.includesSound ? "speaker.wave.2.fill" : "speaker.slash.fill"
            ) {
                model.toggleSound()
            }
            .accessibilityIdentifier("compose.sound")
            .accessibilityLabel(model.includesSound ? "Send without sound" : "Send with sound")
            .accessibilityValue(model.includesSound ? "on" : "off")
        }

        Button {
            model.cycleDuration()
        } label: {
            // "Once" and "Loop" are words, not a figure, and get a size that
            // fits them in the same circle.
            Text(model.duration.label)
                .font(.system(size: model.isVideo ? 12 : 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("compose.duration")
        .accessibilityLabel(model.isVideo ? "Playback" : "Duration")
        .accessibilityValue(model.duration.rawValue)
    }

    /// Keeps a copy in the person's own library, composed exactly as it
    /// would be sent. A tick when it is there, because a save that says
    /// nothing is a save you make twice. It sits on the bottom line rather
    /// than in the rail because it is not a choice about the picture; it is
    /// one of the two things that can become of it.
    private func saveButton(_ model: ComposeModel) -> some View {
        let saved = model.saveState == .saved
        let failed = if case .failed = model.saveState { true } else { false }
        return Button {
            model.save()
        } label: {
            ZStack {
                Circle().fill(saved ? Color.white : Color.black.opacity(0.35))
                if model.saveState == .saving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : (saved ? "checkmark" : "square.and.arrow.down"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(saved ? .black : .white)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(model.saveState == .saving)
        .accessibilityIdentifier("compose.save")
        .accessibilityLabel("Save to Photos")
        .accessibilityValue(model.saveValue)
    }

    /// Turns the photo into its 3D clip and back. The first tap estimates the
    /// depth and renders the views, a second or two with a spinner in the
    /// button; after that it is instant either way.
    private func parallaxButton(_ model: ComposeModel) -> some View {
        Button {
            model.toggleParallax()
        } label: {
            ZStack {
                Circle().fill(model.isParallax ? Color.white : Color.black.opacity(0.35))
                if model.isRenderingParallax {
                    ProgressView().tint(.white)
                } else {
                    Text("3D")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(model.isParallax ? .black : .white)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(model.isRenderingParallax)
        .accessibilityIdentifier("compose.parallax")
        .accessibilityLabel("3D")
        .accessibilityValue(model.isRenderingParallax ? "rendering" : model.isParallax ? "on" : "off")
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
            // Bottom left, opposite Send: the rail above decides what the
            // capture *is*, and the bottom line is what becomes of it — a copy
            // kept on one side, sent on the other. The camera's bottom bar is
            // the same shape.
            saveButton(model)

            Spacer()

            // An aimed capture still has to be redirectable: the only other way
            // out of a wrong recipient would be discarding the photo.
            if model.recipient != nil {
                CircleIconButton(systemName: "person.2.fill") { showsRecipients = true }
                    .disabled(model.isRenderingParallax)
                    .accessibilityIdentifier("compose.changeRecipient")
                    .accessibilityLabel("Send to somebody else")
                    .padding(.trailing, 10)
            }

            Button {
                if let recipient = model.recipient {
                    send(model, to: recipient)
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
                    Image(systemName: "paperplane.fill")
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            // Until the 3D clip exists there is nothing to send that matches
            // what the button promised.
            .disabled(model.isRenderingParallax)
            .opacity(model.isRenderingParallax ? 0.5 : 1)
            .accessibilityIdentifier("compose.sendTo")
        }
    }

    /// The one-tap path, for a capture that already knows who it is for. The
    /// picker's own send goes through `SendToScreen`, and both finish the same
    /// way: the photo goes to the outbox, the aim is spent, and the camera comes
    /// back at once. The outbox reports how it went.
    private func send(_ model: ComposeModel, to recipient: InstantRecipient) {
        environment.send(model.draft, to: [recipient])
        model.close(sent: true)
        onSent()
    }

    // MARK: - Drawing

    /// The only way out of drawing, so while drawing it is the only tool left
    /// in the rail, at the top, with the colours under it.
    private var drawButton: some View {
        CircleIconButton(systemName: "pencil", isOn: isDrawing) {
            isDrawing.toggle()
        }
        .accessibilityIdentifier("compose.draw")
        .accessibilityLabel("Draw")
        .accessibilityValue(isDrawing ? "on" : "off")
    }

    private func inkBar(_ model: ComposeModel) -> some View {
        VStack(spacing: 6) {
            ForEach(OverlayCompositor.Ink.allCases, id: \.self) { ink in
                let isSelected = model.ink == ink
                Button {
                    model.ink = ink
                } label: {
                    Circle()
                        .fill(Color(uiColor: ink.color))
                        .frame(width: 24, height: 24)
                        // White and black each vanish against half of all
                        // photos, so every swatch carries a ring.
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: isSelected ? 3 : 1.5))
                        .scaleEffect(isSelected ? 1.25 : 1)
                        .frame(width: 44, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("compose.ink.\(ink.rawValue)")
                .accessibilityLabel(ink.rawValue.capitalized)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .animation(.spring(duration: 0.2), value: model.ink)
    }

    /// Read in the photo's own space, which stays put while a line is drawn —
    /// unlike a caption, nothing under the finger moves, so there is nothing
    /// for the reading to chase. No minimum distance, so a tap leaves a dot.
    private func draw(_ model: ComposeModel, in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = fraction(of: value.location, in: frame)
                if strokeStart == value.startLocation {
                    model.extendStroke(to: point)
                } else {
                    strokeStart = value.startLocation
                    model.beginStroke(at: point)
                }
            }
            .onEnded { _ in strokeStart = nil }
    }

    /// Unclamped, unlike a caption's placement: a line may run off the edge.
    private func fraction(of point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    // MARK: - Captions

    /// Positioned against the *image* rect, not the container. Anchoring to the
    /// container puts a caption somewhere different once the photo is
    /// letterboxed, so what the sender framed is not what arrives.
    private func captionOverlay(
        _ caption: OverlayCompositor.Caption,
        _ model: ComposeModel,
        in frame: CGRect
    ) -> some View {
        let metrics = OverlayCompositor.metrics(
            for: caption.style, scale: caption.scale, width: Double(frame.width)
        )
        let size = OverlayCompositor.textSize(caption.trimmed, metrics: metrics)
        return Text(caption.trimmed)
            .font(Font(OverlayCompositor.font(for: metrics)))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(width: size.width)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(CaptionBacking(style: caption.style, metrics: metrics, photoWidth: frame.width))
            // Faded while it is over the trash: letting go now removes it.
            .opacity(draggingID == caption.id && isOverTrash ? 0.4 : 1)
            // The hit area is set before the turn, so it turns with the
            // caption instead of staying a level box around it.
            .contentShape(Rectangle())
            .rotationEffect(.radians(caption.drawnRotation))
            .onTapGesture { beginEditing(caption.id) }
            .gesture(drag(caption, model, in: frame))
            // While drawing, a finger on a caption draws over it rather than
            // moving it.
            .allowsHitTesting(!isDrawing)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.photoSpace))
            } action: {
                captionFrames[caption.id] = $0
            }
            .position(
                x: caption.style == .bar
                    ? frame.midX
                    : frame.minX + frame.width * caption.placement.x,
                y: frame.minY + frame.height * caption.placement.y
            )
            .accessibilityIdentifier("compose.captionOverlay")
            .accessibilityValue(caption.style.rawValue)
    }

    /// Relative to where the drag began rather than to the finger, so taking
    /// hold of a caption by its edge does not snap its centre to the fingertip.
    ///
    /// Measured in global space, never the caption's own. The caption moves
    /// under the finger, so its local space moves with it, and every move
    /// changes the next reading; the two chase each other and the caption
    /// shudders back and forth. Global is also the space the trash is found in.
    private func drag(
        _ caption: OverlayCompositor.Caption,
        _ model: ComposeModel,
        in frame: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? caption.placement
                dragOrigin = origin
                draggingID = caption.id
                isOverTrash = trashFrame.insetBy(dx: -16, dy: -16).contains(value.location)
                model.move(caption.id, to: OverlayCompositor.Placement(
                    x: origin.x + value.translation.width / frame.width,
                    y: origin.y + value.translation.height / frame.height
                ))
            }
            .onEnded { _ in
                if isOverTrash {
                    model.removeCaption(caption.id)
                    captionFrames[caption.id] = nil
                }
                dragOrigin = nil
                draggingID = nil
                isOverTrash = false
            }
    }

    /// Top and centre, where nothing else is while a caption is held — the
    /// chrome is hidden for the length of the drag.
    private var trash: some View {
        Image(systemName: "trash")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isOverTrash ? .black : .white)
            .frame(width: 52, height: 52)
            .background(Circle().fill(isOverTrash ? Color.white : Color.black.opacity(0.45)))
            .scaleEffect(isOverTrash ? 1.25 : 1)
            .animation(.spring(duration: 0.2), value: isOverTrash)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                trashFrame = $0
            }
            .accessibilityIdentifier("compose.trash")
            .accessibilityLabel("Delete text")
            .frame(maxWidth: .infinity)
    }

    /// Pinch and turn are two gestures, each with its own start, so either can
    /// begin and end without the other: a pinch that never turns far enough to
    /// count as a turn still scales, and the reverse.
    private func pinch(_ model: ComposeModel) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchTarget == nil, let caption = pinchedCaption(model, near: value.startLocation) {
                    pinchTarget = GestureTarget(id: caption.id, start: caption.scale)
                }
                guard let pinchTarget else { return }
                model.rescale(pinchTarget.id, to: pinchTarget.start * value.magnification)
            }
            .onEnded { _ in pinchTarget = nil }
    }

    private func turn(_ model: ComposeModel) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                if turnTarget == nil, let caption = pinchedCaption(model, near: value.startLocation) {
                    turnTarget = GestureTarget(id: caption.id, start: caption.rotation)
                }
                guard let turnTarget else { return }
                model.rotate(turnTarget.id, to: turnTarget.start + value.rotation.radians)
            }
            .onEnded { _ in turnTarget = nil }
    }

    /// The topmost plate under the pinch, with a finger's width of slack around
    /// it: a small caption is narrower than two fingers held apart.
    private func pinchedCaption(_ model: ComposeModel, near point: CGPoint) -> OverlayCompositor.Caption? {
        model.captions.reversed().first { caption in
            caption.style == .plate
                && caption.id != editingID
                && captionFrames[caption.id]?.insetBy(dx: -44, dy: -44).contains(point) == true
        }
    }

    private func placement(of point: CGPoint, in frame: CGRect) -> OverlayCompositor.Placement {
        guard frame.width > 0, frame.height > 0 else { return .default }
        return OverlayCompositor.Placement(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    private func beginEditing(_ id: UUID) {
        if let editingID, editingID != id, let model {
            model.finishEditing(editingID)
        }
        editingID = id
        captionFocused = true
    }

    private func finishEditing() {
        guard let editingID else { return }
        captionFocused = false
        self.editingID = nil
        model?.finishEditing(editingID)
    }

    /// The caption as it will land, typed into in place: the same font, the
    /// same wrap width and the same backing as the one on the photo, so
    /// swapping the style while typing shows exactly what the swap does.
    ///
    /// One field for both styles, with only its measurements changing. Two
    /// fields behind an `if` would be two views, and the swap would take the
    /// keyboard away mid-sentence.
    private func captionEditor(_ model: ComposeModel, id: UUID) -> some View {
        let caption = model.caption(id) ?? OverlayCompositor.Caption(id: id)
        let metrics = OverlayCompositor.metrics(
            for: caption.style, scale: caption.scale, width: Double(max(photoWidth, 1))
        )
        let measured = OverlayCompositor.textSize(
            caption.text.isEmpty ? Self.prompt : caption.text, metrics: metrics
        )
        // A plate hugs its text, plus room for the caret at the end of a line.
        let fieldWidth = caption.style == .bar
            ? metrics.maxTextWidth
            : min(metrics.maxTextWidth, measured.width + metrics.fontSize * 0.2)

        return ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { finishEditing() }

            TextField(
                "",
                text: Binding(
                    get: { model.caption(id)?.text ?? "" },
                    set: { text in
                        // A vertical field turns Return into a newline rather
                        // than a submit. A caption is one paragraph that wraps,
                        // so Return means done.
                        if text.contains("\n") {
                            model.setText(text.replacingOccurrences(of: "\n", with: ""), of: id)
                            finishEditing()
                        } else {
                            model.setText(text, of: id)
                        }
                    }
                ),
                prompt: Text(Self.prompt).foregroundStyle(Color(white: 0.7)),
                axis: .vertical
            )
            .focused($captionFocused)
            .font(Font(OverlayCompositor.font(for: metrics)))
            .foregroundStyle(.white)
            .tint(.white)
            .multilineTextAlignment(.center)
            .submitLabel(.done)
            .frame(width: fieldWidth)
            .modifier(CaptionBacking(style: caption.style, metrics: metrics, photoWidth: photoWidth))
            .accessibilityIdentifier("compose.captionField")
            .onAppear { captionFocused = true }
        }
    }

    /// Where a `.scaledToFit` image actually lands inside its container.
    static func fittedRect(image: UIImage, in container: CGSize) -> CGRect {
        fittedRect(size: image.size, in: container)
    }

    /// The same for anything of `content`'s shape — a clip, which a player
    /// lays out aspect-fit exactly as the image is.
    static func fittedRect(size content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0
        else { return CGRect(origin: .zero, size: container) }

        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Stroked from `OverlayCompositor.path`, at the photo's size on screen, with
/// the width it takes from that size — the compositor does the same at full
/// resolution, which is what puts the line where it was drawn. Beneath the
/// captions, as it is in the pixels.
///
/// Its own view so that a line being drawn redraws this layer alone, not the
/// whole compose screen, sixty to a hundred and twenty times a second. The
/// strokes are read here in `body` and handed to the canvas as a value:
/// `Canvas` runs its closure after `body`, where reading the model is not
/// observed, so a line read there would appear only when the finger lifted.
private struct DrawingLayer: View {
    let model: ComposeModel
    let frame: CGRect

    var body: some View {
        let strokes = model.strokes
        Canvas { context, size in
            let style = StrokeStyle(
                lineWidth: OverlayCompositor.strokeWidth(forWidth: Double(size.width)),
                lineCap: .round,
                lineJoin: .round
            )
            for stroke in strokes {
                context.stroke(
                    Path(OverlayCompositor.path(for: stroke, size: size)),
                    with: .color(Color(uiColor: stroke.ink.color)),
                    style: style
                )
            }
        }
        .frame(width: frame.width, height: frame.height)
        // A letterboxed photo has bars beside it, and nothing drawn over them
        // is sent.
        .clipped()
        .offset(x: frame.minX, y: frame.minY)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityIdentifier("compose.drawing")
        .accessibilityValue("\(strokes.count)")
    }
}

/// Its own view for the same reason as `DrawingLayer`: it reads the strokes,
/// and read in the compose screen's body, every point of a line would rebuild
/// the whole screen.
private struct UndoButton: View {
    let model: ComposeModel

    var body: some View {
        let isEmpty = model.strokes.isEmpty
        CircleIconButton(systemName: "arrow.uturn.backward") {
            model.undoStroke()
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.4 : 1)
        .accessibilityIdentifier("compose.undo")
        .accessibilityLabel("Undo")
    }
}

/// The band or the plate behind a caption, drawn from the same measurements
/// `OverlayCompositor` burns in.
private struct CaptionBacking: ViewModifier {
    let style: OverlayCompositor.Caption.Style
    let metrics: OverlayCompositor.Metrics
    let photoWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(width: style == .bar ? photoWidth : nil)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius)
                    .fill(Color(uiColor: OverlayCompositor.backing(for: style)))
            )
    }
}
#endif
