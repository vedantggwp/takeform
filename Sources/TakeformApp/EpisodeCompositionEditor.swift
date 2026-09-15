import SwiftUI
import TakeformCore
import TakeformWorkspace

enum WorkspaceCommandCompletion {
    case applied(ProjectDocument)
    case conflict(Revision)
    case rejected(String)
    case failure(WorkspaceFailure)

    init(_ outcome: CommandOutcome) {
        switch outcome {
        case .applied(let document): self = .applied(document)
        case .conflict(let revision): self = .conflict(revision)
        case .rejected(let reason): self = .rejected(reason)
        }
    }
}

@MainActor
final class EpisodeCompositionEditorState: ObservableObject {
    struct Context: Equatable {
        let packageURL: URL
        let episodeID: UUID
        let revision: Revision
    }

    struct Clip: Identifiable, Equatable {
        let id: UUID
        let assetID: UUID
        let assetDigest: String
        let filename: String
        let mediaType: String
        var sourceStart: Double
        var sourceDuration: Double
        var outputStart: Double
        var outputDuration: Double
        var layer: Int
        var order: Int
        var cropX: Double
        var cropY: Double
        var cropWidth: Double
        var cropHeight: Double
        /// Normalized destination position, with a top-left canvas origin.
        var positionX: Double
        var positionY: Double
        var positionWidth: Double
        var positionHeight: Double
    }

    struct Caption: Identifiable, Equatable {
        let id: UUID
        var text: String
        var outputStart: Double
        var outputDuration: Double
        var layer: Int
        var order: Int
    }

    struct Draft: Equatable {
        let episodeID: UUID
        var outputDuration: Double
        var clips: [Clip]
        var captions: [Caption]

        init(document: ProjectDocument, episode: Episode) {
            episodeID = episode.id
            if let composition = document.episodeCompositions.first(where: { $0.episodeID == episode.id }) {
                outputDuration = Self.seconds(composition.output.duration)
                clips = composition.occurrences.compactMap { occurrence in
                    guard let asset = document.assets.first(where: { $0.id == occurrence.assetID }) else { return nil }
                    let sourceRange: CompositionRange
                    switch occurrence.source {
                    case .still: sourceRange = CompositionRange(start: Self.zero, duration: Self.zero)
                    case .video(let range): sourceRange = range
                    }
                    return Clip(
                        id: occurrence.id,
                        assetID: occurrence.assetID,
                        assetDigest: occurrence.assetDigest,
                        filename: asset.filename,
                        mediaType: asset.mediaType,
                        sourceStart: Self.seconds(sourceRange.start),
                        sourceDuration: Self.seconds(sourceRange.duration),
                        outputStart: Self.seconds(occurrence.outputRange.start),
                        outputDuration: Self.seconds(occurrence.outputRange.duration),
                        layer: occurrence.layer,
                        order: occurrence.order,
                        cropX: Self.seconds(occurrence.crop.x),
                        cropY: Self.seconds(occurrence.crop.y),
                        cropWidth: Self.seconds(occurrence.crop.width),
                        cropHeight: Self.seconds(occurrence.crop.height),
                        positionX: Self.seconds(occurrence.outputRect.x),
                        positionY: Self.seconds(occurrence.outputRect.y),
                        positionWidth: Self.seconds(occurrence.outputRect.width),
                        positionHeight: Self.seconds(occurrence.outputRect.height)
                    )
                }
                captions = composition.captions.map {
                    Caption(
                        id: $0.id,
                        text: $0.text,
                        outputStart: Self.seconds($0.outputRange.start),
                        outputDuration: Self.seconds($0.outputRange.duration),
                        layer: $0.layer,
                        order: $0.order
                    )
                }
            } else {
                outputDuration = 10
                clips = []
                captions = []
            }
        }

        mutating func add(asset: ManagedAsset) {
            let nextOrder = (clips.map(\.order).max() ?? -1) + 1
            let duration = Self.defaultDuration(for: asset)
            let sourceDuration = asset.mediaType == "video" ? duration : 0
            clips.append(
                Clip(
                    id: UUID(),
                    assetID: asset.id,
                    assetDigest: asset.digest,
                    filename: asset.filename,
                    mediaType: asset.mediaType,
                    sourceStart: 0,
                    sourceDuration: sourceDuration,
                    outputStart: 0,
                    outputDuration: min(duration, outputDuration),
                    layer: (clips.map(\.layer).max() ?? -1) + 1,
                    order: nextOrder,
                    cropX: 0,
                    cropY: 0,
                    cropWidth: 1,
                    cropHeight: 1,
                    positionX: 0,
                    positionY: 0,
                    positionWidth: 1,
                    positionHeight: 1
                )
            )
        }

        mutating func moveClip(id: UUID, by delta: Int) {
            guard let current = clips.firstIndex(where: { $0.id == id }) else { return }
            let next = current + delta
            guard clips.indices.contains(next) else { return }
            clips.swapAt(current, next)
            normalizeClipOrders()
        }

        mutating func removeClip(id: UUID) {
            clips.removeAll { $0.id == id }
            normalizeClipOrders()
        }

        mutating func addCaption() {
            captions.append(Caption(id: UUID(), text: "New caption", outputStart: 0, outputDuration: min(3, outputDuration), layer: (captions.map(\.layer).max() ?? 0) + 1, order: (captions.map(\.order).max() ?? -1) + 1))
        }

        mutating func removeCaption(id: UUID) {
            captions.removeAll { $0.id == id }
            normalizeCaptionOrders()
        }

        func composition(assets: [ManagedAsset]) throws -> EpisodeComposition {
            guard let duration = Self.time(outputDuration) else { throw CompositionEditorFailure.invalidDuration }
            let output = CompositionOutput(width: 1920, height: 1080, frameRate: Self.frameRate, duration: duration)
            let occurrences = try clips.map { clip in
                let outputRange = try Self.range(start: clip.outputStart, duration: clip.outputDuration)
                let crop = try Self.crop(x: clip.cropX, y: clip.cropY, width: clip.cropWidth, height: clip.cropHeight)
                let outputRect = try Self.outputRect(x: clip.positionX, y: clip.positionY, width: clip.positionWidth, height: clip.positionHeight)
                let source: CompositionSource
                if clip.mediaType == "video" {
                    source = .video(try Self.range(start: clip.sourceStart, duration: clip.sourceDuration))
                } else {
                    source = .still
                }
                return CompositionOccurrence(id: clip.id, assetID: clip.assetID, assetDigest: clip.assetDigest, source: source, outputRange: outputRange, layer: clip.layer, order: clip.order, crop: crop, outputRect: outputRect)
            }
            let cues = try captions.map {
                CompositionCaption(id: $0.id, text: $0.text, outputRange: try Self.range(start: $0.outputStart, duration: $0.outputDuration), layer: $0.layer, order: $0.order)
            }
            let composition = EpisodeComposition(episodeID: episodeID, output: output, occurrences: occurrences, captions: cues)
            try composition.validate(episodes: [Episode(id: episodeID, name: "Selected episode", recipeVersion: 1)], assets: assets)
            return composition
        }

        private mutating func normalizeClipOrders() {
            for index in clips.indices { clips[index].order = index }
        }

        private mutating func normalizeCaptionOrders() {
            for index in captions.indices { captions[index].order = index }
        }

        private static let frameRate = CompositionTime(value: 30, timescale: 1)!
        private static let zero = CompositionTime(value: 0, timescale: 1)!

        private static func defaultDuration(for asset: ManagedAsset) -> Double {
            guard asset.mediaType == "video" else { return 3 }
            guard let video = asset.probe?.video,
                  let range = video.timeRange,
                  range.count == 2,
                  range[1].timescale > 0 else { return 3 }
            return min(3, Double(range[1].value) / Double(range[1].timescale))
        }

        private static func seconds(_ time: CompositionTime) -> Double {
            Double(time.value) / Double(time.timescale)
        }

        private static func time(_ seconds: Double) -> CompositionTime? {
            guard seconds.isFinite else { return nil }
            let scaled = (seconds * 600).rounded()
            guard scaled >= Double(Int64.min), scaled <= Double(Int64.max) else { return nil }
            return CompositionTime(value: Int64(scaled), timescale: 600)
        }

        private static func range(start: Double, duration: Double) throws -> CompositionRange {
            guard let start = time(start), let duration = time(duration) else { throw CompositionEditorFailure.invalidTime }
            return CompositionRange(start: start, duration: duration)
        }

        private static func crop(x: Double, y: Double, width: Double, height: Double) throws -> CompositionCrop {
            guard let x = time(x), let y = time(y), let width = time(width), let height = time(height) else { throw CompositionEditorFailure.invalidCrop }
            return CompositionCrop(x: x, y: y, width: width, height: height)
        }

        private static func outputRect(x: Double, y: Double, width: Double, height: Double) throws -> CompositionOutputRect {
            guard let x = time(x), let y = time(y), let width = time(width), let height = time(height) else { throw CompositionEditorFailure.invalidPosition }
            return CompositionOutputRect(x: x, y: y, width: width, height: height)
        }
    }

    enum CompositionEditorFailure: LocalizedError {
        case invalidDuration
        case invalidTime
        case invalidCrop
        case invalidPosition

        var errorDescription: String? {
            switch self {
            case .invalidDuration: "Enter a finite output duration in seconds."
            case .invalidTime: "Enter finite clip and caption times in seconds."
            case .invalidCrop: "Enter finite normalized crop values."
            case .invalidPosition: "Enter finite normalized position values."
            }
        }
    }

    @Published private(set) var context: Context?
    @Published private(set) var draft: Draft?
    @Published private(set) var baseline: Draft?
    @Published var message: String?
    @Published var needsResolution = false
    @Published var isSaving = false

    var isDirty: Bool { draft != baseline }

    func synchronize(document: ProjectDocument, packageURL: URL, episode: Episode) {
        let incoming = Context(packageURL: packageURL, episodeID: episode.id, revision: document.revision)
        guard let context else {
            load(document: document, packageURL: packageURL, episode: episode)
            return
        }
        guard context.packageURL == incoming.packageURL, context.episodeID == incoming.episodeID else {
            load(document: document, packageURL: packageURL, episode: episode)
            return
        }
        guard context.revision != incoming.revision else { return }
        if isDirty {
            needsResolution = true
            message = "The committed composition changed. Reload to resolve it, or keep this local draft and adjust it."
        } else {
            load(document: document, packageURL: packageURL, episode: episode)
        }
    }

    func updateClip(_ clip: Clip) {
        guard var draft, let index = draft.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        draft.clips[index] = clip
        self.draft = draft
    }

    func updateCaption(_ caption: Caption) {
        guard var draft, let index = draft.captions.firstIndex(where: { $0.id == caption.id }) else { return }
        draft.captions[index] = caption
        self.draft = draft
    }

    func add(asset: ManagedAsset) {
        guard var draft else { return }
        draft.add(asset: asset)
        self.draft = draft
    }

    func moveClip(id: UUID, by delta: Int) {
        guard var draft else { return }
        draft.moveClip(id: id, by: delta)
        self.draft = draft
    }

    func removeClip(id: UUID) {
        guard var draft else { return }
        draft.removeClip(id: id)
        self.draft = draft
    }

    func addCaption() {
        guard var draft else { return }
        draft.addCaption()
        self.draft = draft
    }

    func removeCaption(id: UUID) {
        guard var draft else { return }
        draft.removeCaption(id: id)
        self.draft = draft
    }

    func reload(document: ProjectDocument, packageURL: URL, episode: Episode) {
        load(document: document, packageURL: packageURL, episode: episode)
    }

    func keepDraftForResolution() {
        needsResolution = false
        message = "Keeping your draft. Reload the committed project before saving again if another edit changed it."
    }

    func save(using model: WorkspaceModel, document: ProjectDocument, packageURL: URL, episode: Episode) {
        synchronize(document: document, packageURL: packageURL, episode: episode)
        guard let context, context.packageURL == packageURL, context.episodeID == episode.id, let draft else { return }
        do {
            let composition = try draft.composition(assets: document.assets)
            isSaving = true
            message = nil
            model.submit(.replaceEpisodeComposition(episodeID: episode.id, composition: composition)) { [weak self] completion in
                self?.receive(completion, for: context, packageURL: packageURL, episode: episode)
            }
        } catch let failure as CompositionValidationFailure {
            message = validationMessage(for: failure)
            needsResolution = true
        } catch {
            message = error.localizedDescription
            needsResolution = true
        }
    }

    func receive(_ completion: WorkspaceCommandCompletion, for request: Context, packageURL: URL, episode: Episode) {
        guard context?.packageURL == request.packageURL, context?.episodeID == request.episodeID else { return }
        isSaving = false
        switch completion {
        case .applied(let document):
            load(document: document, packageURL: packageURL, episode: episode)
            message = "Composition saved at revision \(document.revision.value)."
        case .conflict(let revision):
            needsResolution = true
            message = "This composition was not saved because revision \(revision.value) changed first. Your draft is still here."
        case .rejected(let reason):
            needsResolution = true
            message = "The composition was not saved: \(reason). Your draft is still here."
        case .failure(let failure):
            needsResolution = true
            message = failure.errorDescription ?? "The composition was not saved. Your draft is still here."
        }
    }

    private func load(document: ProjectDocument, packageURL: URL, episode: Episode) {
        let loaded = Draft(document: document, episode: episode)
        context = Context(packageURL: packageURL, episodeID: episode.id, revision: document.revision)
        draft = loaded
        baseline = loaded
        needsResolution = false
        isSaving = false
        message = nil
    }

    private func validationMessage(for failure: CompositionValidationFailure) -> String {
        switch failure {
        case .invalidRange, .rangeOutsideOutput:
            "Check clip and caption times. Each range must have a positive length and fit the episode output."
        case .rangeOutsideSource:
            "Check the clip source range. It must fit the selected video's measured duration."
        case .invalidCrop:
            "Check the crop. Its normalized X, Y, width, and height must stay inside the source image."
        case .invalidOutputRect:
            "Check the position. Its normalized X, Y, width, and height must stay inside the composition canvas."
        case .sameLayerOverlap:
            "Clips on the same layer cannot overlap. Move one clip or place it on another layer."
        case .emptyCaption:
            "Enter caption text or remove the empty caption."
        default:
            "The composition has invalid values. Review the highlighted clip or caption and try again."
        }
    }
}

struct EpisodeCompositionEditor: View {
    @ObservedObject var model: WorkspaceModel
    let episode: Episode
    @StateObject private var state = EpisodeCompositionEditorState()

    var body: some View {
        Group {
            if let document = model.document, let packageURL = model.packageURL, let draft = state.draft {
                Section("Episode composition") {
                    Text(episode.name)
                        .accessibilityIdentifier("composition-selected-episode")
                    Text("Edit source and output time in seconds. Clip audio is muted for this first visual montage.")
                        .foregroundStyle(.secondary)
                    if state.needsResolution, let message = state.message {
                        resolutionControls(document: document, packageURL: packageURL, message: message)
                    } else if let message = state.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("composition-message")
                    }

                    Menu("Add managed clip") {
                        ForEach(visualAssets(in: document)) { asset in
                            Button(asset.filename) { state.add(asset: asset) }
                                .accessibilityIdentifier("composition-asset-\(asset.id.uuidString)")
                        }
                    }
                    .disabled(visualAssets(in: document).isEmpty)
                    .accessibilityIdentifier("composition-asset-picker")

                    if draft.clips.isEmpty {
                        Text("Choose an imported still or video to build this episode.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.clips) { clip in
                        ClipEditorRow(
                            clip: clipBinding(clip.id),
                            canMoveEarlier: draft.clips.first?.id != clip.id,
                            canMoveLater: draft.clips.last?.id != clip.id,
                            move: { state.moveClip(id: clip.id, by: $0) },
                            remove: { state.removeClip(id: clip.id) }
                        )
                    }
                }

                Section("Captions") {
                    ForEach(draft.captions) { caption in
                        CaptionEditorRow(caption: captionBinding(caption.id), remove: { state.removeCaption(id: caption.id) })
                    }
                    Button("Add caption") { state.addCaption() }
                        .accessibilityIdentifier("composition-add-caption")
                }

                Section {
                    HStack {
                        Button(state.isSaving ? "Saving…" : "Save composition") {
                            state.save(using: model, document: document, packageURL: packageURL, episode: episode)
                        }
                        .disabled(state.isSaving || draft.clips.isEmpty)
                        .accessibilityIdentifier("composition-save")
                        Text(state.isDirty ? "Unsaved changes" : "Saved draft")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("composition-editor")
            } else {
                ContentUnavailableView("Choose an episode", systemImage: "timeline.selection", description: Text("Select an episode in the sidebar to compose its imported media."))
            }
        }
        .onAppear { synchronize() }
        .onChange(of: model.packageURL) { _, _ in synchronize() }
        .onChange(of: model.document?.revision) { _, _ in synchronize() }
        .onChange(of: episode.id) { _, _ in synchronize() }
    }

    private func resolutionControls(document: ProjectDocument, packageURL: URL, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.red)
                .accessibilityIdentifier("composition-error")
            HStack {
                Button("Reload committed") {
                    state.reload(document: document, packageURL: packageURL, episode: episode)
                    model.reloadCurrentProject()
                }
                .accessibilityIdentifier("composition-reload")
                Button("Keep my draft") { state.keepDraftForResolution() }
                    .accessibilityIdentifier("composition-keep-draft")
                Button("Discard draft", role: .destructive) {
                    state.reload(document: document, packageURL: packageURL, episode: episode)
                }
                .accessibilityIdentifier("composition-discard")
            }
        }
    }

    private func synchronize() {
        guard let document = model.document, let packageURL = model.packageURL else { return }
        state.synchronize(document: document, packageURL: packageURL, episode: episode)
    }

    private func visualAssets(in document: ProjectDocument) -> [ManagedAsset] {
        document.assets.filter { $0.mediaType == "image" || $0.mediaType == "video" }
    }

    private func clipBinding(_ id: UUID) -> Binding<EpisodeCompositionEditorState.Clip> {
        Binding(
            get: { state.draft!.clips.first(where: { $0.id == id })! },
            set: { state.updateClip($0) }
        )
    }

    private func captionBinding(_ id: UUID) -> Binding<EpisodeCompositionEditorState.Caption> {
        Binding(
            get: { state.draft!.captions.first(where: { $0.id == id })! },
            set: { state.updateCaption($0) }
        )
    }
}

private struct ClipEditorRow: View {
    @Binding var clip: EpisodeCompositionEditorState.Clip
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(clip.filename, systemImage: clip.mediaType == "video" ? "film" : "photo")
                Spacer()
                Text("Layer \(clip.layer + 1)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("Move earlier") { move(-1) }
                    .disabled(!canMoveEarlier)
                Button("Move later") { move(1) }
                    .disabled(!canMoveLater)
                Button("Remove", role: .destructive) { remove() }
            }
            .accessibilityIdentifier("composition-clip-\(clip.id.uuidString)")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if clip.mediaType == "video" {
                    GridRow {
                        Text("Source")
                        secondsField("Start", value: $clip.sourceStart, identifier: "composition-clip-\(clip.id.uuidString)-source-start")
                        secondsField("Length", value: $clip.sourceDuration, identifier: "composition-clip-\(clip.id.uuidString)-source-duration")
                    }
                }
                GridRow {
                    Text("Output")
                    secondsField("Start", value: $clip.outputStart, identifier: "composition-clip-\(clip.id.uuidString)-output-start")
                    secondsField("Length", value: $clip.outputDuration, identifier: "composition-clip-\(clip.id.uuidString)-output-duration")
                }
                GridRow {
                    Text("Layer")
                    Stepper(value: $clip.layer, in: 0...20) { Text("Layer \(clip.layer + 1)") }
                        .accessibilityIdentifier("composition-clip-\(clip.id.uuidString)-layer")
                    EmptyView()
                }
                GridRow {
                    Text("Crop")
                    cropFields
                    EmptyView()
                }
                GridRow {
                    Text("Position")
                    positionFields
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var cropFields: some View {
        HStack(spacing: 8) {
            labeledField("X", value: $clip.cropX, identifier: "composition-clip-\(clip.id.uuidString)-crop-x")
            labeledField("Y", value: $clip.cropY, identifier: "composition-clip-\(clip.id.uuidString)-crop-y")
            labeledField("W", value: $clip.cropWidth, identifier: "composition-clip-\(clip.id.uuidString)-crop-width")
            labeledField("H", value: $clip.cropHeight, identifier: "composition-clip-\(clip.id.uuidString)-crop-height")
        }
    }

    private var positionFields: some View {
        HStack(spacing: 8) {
            labeledField("X", value: $clip.positionX, identifier: "composition-clip-\(clip.id.uuidString)-position-x")
            labeledField("Y", value: $clip.positionY, identifier: "composition-clip-\(clip.id.uuidString)-position-y")
            labeledField("W", value: $clip.positionWidth, identifier: "composition-clip-\(clip.id.uuidString)-position-width")
            labeledField("H", value: $clip.positionHeight, identifier: "composition-clip-\(clip.id.uuidString)-position-height")
        }
        .accessibilityLabel("Position from top left")
    }

    private func secondsField(_ label: String, value: Binding<Double>, identifier: String) -> some View {
        TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
            .frame(width: 88)
            .accessibilityIdentifier(identifier)
    }

    private func labeledField(_ label: String, value: Binding<Double>, identifier: String) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 56)
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct CaptionEditorRow: View {
    @Binding var caption: EpisodeCompositionEditorState.Caption
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Caption", text: $caption.text)
                .accessibilityIdentifier("composition-caption-\(caption.id.uuidString)-text")
            secondsField("Start", value: $caption.outputStart, identifier: "composition-caption-\(caption.id.uuidString)-start")
            secondsField("Length", value: $caption.outputDuration, identifier: "composition-caption-\(caption.id.uuidString)-duration")
            Stepper(value: $caption.layer, in: 0...20) { Text("Layer \(caption.layer + 1)") }
                .accessibilityIdentifier("composition-caption-\(caption.id.uuidString)-layer")
            Button("Remove", role: .destructive) { remove() }
        }
        .accessibilityIdentifier("composition-caption-\(caption.id.uuidString)")
    }

    private func secondsField(_ label: String, value: Binding<Double>, identifier: String) -> some View {
        TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
            .frame(width: 72)
            .accessibilityIdentifier(identifier)
    }
}
