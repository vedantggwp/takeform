import Foundation

/// A canonical rational used by portable episode-composition state.
public struct CompositionTime: Codable, Equatable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public init?(value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        let divisor = Self.greatestCommonDivisor(value.magnitude, UInt64(timescale))
        self.value = value / Int64(divisor)
        self.timescale = timescale / Int32(divisor)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let value = try values.decode(Int64.self, forKey: .value)
        let timescale = try values.decode(Int32.self, forKey: .timescale)
        guard let canonical = Self(value: value, timescale: timescale) else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: values, debugDescription: "Composition time has an invalid timescale")
        }
        self = canonical
    }

    fileprivate static func checkedCompare(_ lhs: Self, _ rhs: Self) throws -> ComparisonResult {
        let left = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let right = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        guard !left.overflow, !right.overflow else { throw CompositionValidationFailure.rationalOverflow }
        if left.partialValue < right.partialValue { return .orderedAscending }
        if left.partialValue > right.partialValue { return .orderedDescending }
        return .orderedSame
    }

    fileprivate func checkedCompare(_ other: Self) throws -> ComparisonResult {
        try Self.checkedCompare(self, other)
    }

    fileprivate static func checkedAdd(_ lhs: Self, _ rhs: Self) throws -> Self {
        let gcd = greatestCommonDivisor(UInt64(lhs.timescale), UInt64(rhs.timescale))
        let lhsMultiplier = Int64(rhs.timescale) / Int64(gcd)
        let rhsMultiplier = Int64(lhs.timescale) / Int64(gcd)
        let left = lhs.value.multipliedReportingOverflow(by: lhsMultiplier)
        let right = rhs.value.multipliedReportingOverflow(by: rhsMultiplier)
        guard !left.overflow, !right.overflow else { throw CompositionValidationFailure.rationalOverflow }
        let sum = left.partialValue.addingReportingOverflow(right.partialValue)
        guard !sum.overflow else { throw CompositionValidationFailure.rationalOverflow }
        let scale = Int64(lhs.timescale).multipliedReportingOverflow(by: lhsMultiplier)
        guard !scale.overflow, let result = Self(value: sum.partialValue, timescale: Int32(exactly: scale.partialValue) ?? 0) else {
            throw CompositionValidationFailure.rationalOverflow
        }
        return result
    }

    fileprivate func checkedAdd(_ other: Self) throws -> Self {
        try Self.checkedAdd(self, other)
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 { let remainder = lhs % rhs; lhs = rhs; rhs = remainder }
        return max(lhs, 1)
    }
}

public struct CompositionRange: Codable, Equatable, Sendable {
    public let start: CompositionTime
    public let duration: CompositionTime
    public init(start: CompositionTime, duration: CompositionTime) { self.start = start; self.duration = duration }

    fileprivate func end() throws -> CompositionTime { try CompositionTime.checkedAdd(start, duration) }
}

public struct CompositionCrop: Codable, Equatable, Sendable {
    public let x: CompositionTime
    public let y: CompositionTime
    public let width: CompositionTime
    public let height: CompositionTime
    public init(x: CompositionTime, y: CompositionTime, width: CompositionTime, height: CompositionTime) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// A normalized destination rectangle on the composition canvas. Coordinates
/// use a top-left origin: x grows right and y grows down. This is distinct from
/// `CompositionCrop`, which selects a source region.
public struct CompositionOutputRect: Codable, Equatable, Sendable {
    public let x: CompositionTime
    public let y: CompositionTime
    public let width: CompositionTime
    public let height: CompositionTime
    public init(x: CompositionTime, y: CompositionTime, width: CompositionTime, height: CompositionTime) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let fullCanvas = CompositionOutputRect(
        x: CompositionTime(value: 0, timescale: 1)!,
        y: CompositionTime(value: 0, timescale: 1)!,
        width: CompositionTime(value: 1, timescale: 1)!,
        height: CompositionTime(value: 1, timescale: 1)!
    )
}

public struct CompositionOutput: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Frames per second, represented as a canonical positive rational.
    public let frameRate: CompositionTime
    public let duration: CompositionTime
    public init(width: Int, height: Int, frameRate: CompositionTime, duration: CompositionTime) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.duration = duration
    }
}

public enum CompositionSource: Codable, Equatable, Sendable {
    case still
    case video(CompositionRange)
}

/// Clip audio is deliberately muted for the first visual-montage contract.
/// Later audio routing must add a declared policy rather than silently change it.
public enum CompositionAudioPolicy: String, Codable, Equatable, Sendable { case muted }

public struct CompositionOccurrence: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let assetID: UUID
    public let assetDigest: String
    public let source: CompositionSource
    public let outputRange: CompositionRange
    public let layer: Int
    public let order: Int
    public let crop: CompositionCrop
    public let outputRect: CompositionOutputRect
    public init(id: UUID = UUID(), assetID: UUID, assetDigest: String, source: CompositionSource, outputRange: CompositionRange, layer: Int, order: Int, crop: CompositionCrop, outputRect: CompositionOutputRect = .fullCanvas) {
        self.id = id; self.assetID = assetID; self.assetDigest = assetDigest; self.source = source; self.outputRange = outputRange; self.layer = layer; self.order = order; self.crop = crop; self.outputRect = outputRect
    }

    private enum CodingKeys: String, CodingKey { case id, assetID, assetDigest, source, outputRange, layer, order, crop, outputRect }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            assetID: try values.decode(UUID.self, forKey: .assetID),
            assetDigest: try values.decode(String.self, forKey: .assetDigest),
            source: try values.decode(CompositionSource.self, forKey: .source),
            outputRange: try values.decode(CompositionRange.self, forKey: .outputRange),
            layer: try values.decode(Int.self, forKey: .layer),
            order: try values.decode(Int.self, forKey: .order),
            crop: try values.decode(CompositionCrop.self, forKey: .crop),
            outputRect: try values.decodeIfPresent(CompositionOutputRect.self, forKey: .outputRect) ?? .fullCanvas
        )
    }
}

public struct CompositionCaption: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let outputRange: CompositionRange
    public let layer: Int
    /// Captions are a fixed overlay phase above all visual occurrences.
    /// Higher order paints later inside the same caption layer.
    public let order: Int
    public init(id: UUID = UUID(), text: String, outputRange: CompositionRange, layer: Int, order: Int) { self.id = id; self.text = text; self.outputRange = outputRange; self.layer = layer; self.order = order }
}

public struct EpisodeComposition: Codable, Equatable, Sendable, Identifiable {
    public let episodeID: UUID
    public let output: CompositionOutput
    public let clipAudioPolicy: CompositionAudioPolicy
    public let occurrences: [CompositionOccurrence]
    public let captions: [CompositionCaption]
    public var id: UUID { episodeID }
    public init(episodeID: UUID, output: CompositionOutput, clipAudioPolicy: CompositionAudioPolicy = .muted, occurrences: [CompositionOccurrence], captions: [CompositionCaption]) {
        self.episodeID = episodeID; self.output = output; self.clipAudioPolicy = clipAudioPolicy
        self.occurrences = occurrences.sorted { $0.order < $1.order }
        self.captions = captions.sorted { ($0.layer, $0.order) < ($1.layer, $1.order) }
    }

    private enum CodingKeys: String, CodingKey { case episodeID, output, clipAudioPolicy, occurrences, captions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            episodeID: try values.decode(UUID.self, forKey: .episodeID),
            output: try values.decode(CompositionOutput.self, forKey: .output),
            clipAudioPolicy: try values.decode(CompositionAudioPolicy.self, forKey: .clipAudioPolicy),
            occurrences: try values.decode([CompositionOccurrence].self, forKey: .occurrences),
            captions: try values.decode([CompositionCaption].self, forKey: .captions)
        )
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum CompositionValidationFailure: Error, Equatable, Sendable {
    case missingEpisode
    case episodeMismatch
    case duplicateOccurrence
    case duplicateCaption
    case duplicateOrder
    case duplicateCaptionOrder
    case missingAsset
    case assetDigestMismatch
    case missingProbe
    case unsupportedAssetType
    case invalidOutput
    case invalidRange
    case rangeOutsideSource
    case rangeOutsideOutput
    case invalidCrop
    case invalidOutputRect
    case invalidLayer
    case sameLayerOverlap
    case emptyCaption
    case rationalOverflow

    public var reason: String {
        switch self {
        case .missingEpisode: "composition-missing-episode"
        case .episodeMismatch: "composition-episode-mismatch"
        case .duplicateOccurrence: "composition-duplicate-occurrence"
        case .duplicateCaption: "composition-duplicate-caption"
        case .duplicateOrder: "composition-duplicate-order"
        case .duplicateCaptionOrder: "composition-duplicate-caption-order"
        case .missingAsset: "composition-missing-asset"
        case .assetDigestMismatch: "composition-asset-digest-mismatch"
        case .missingProbe: "composition-missing-probe"
        case .unsupportedAssetType: "composition-unsupported-asset-type"
        case .invalidOutput: "composition-invalid-output"
        case .invalidRange: "composition-invalid-range"
        case .rangeOutsideSource: "composition-range-outside-source"
        case .rangeOutsideOutput: "composition-range-outside-output"
        case .invalidCrop: "composition-invalid-crop"
        case .invalidOutputRect: "composition-invalid-output-rect"
        case .invalidLayer: "composition-invalid-layer"
        case .sameLayerOverlap: "composition-same-layer-overlap"
        case .emptyCaption: "composition-empty-caption"
        case .rationalOverflow: "composition-rational-overflow"
        }
    }
}

public extension EpisodeComposition {
    func validate(episodes: [Episode], assets: [ManagedAsset]) throws {
        guard episodes.contains(where: { $0.id == episodeID }) else { throw CompositionValidationFailure.missingEpisode }
        guard output.width > 0, output.height > 0,
              try output.frameRate.checkedCompare(zero) == .orderedDescending,
              try output.duration.checkedCompare(zero) == .orderedDescending else { throw CompositionValidationFailure.invalidOutput }

        var ids = Set<UUID>()
        var orders = Set<Int>()
        var byLayer: [Int: [CompositionRange]] = [:]
        for occurrence in occurrences {
            guard ids.insert(occurrence.id).inserted else { throw CompositionValidationFailure.duplicateOccurrence }
            guard orders.insert(occurrence.order).inserted else { throw CompositionValidationFailure.duplicateOrder }
            guard occurrence.layer >= 0 else { throw CompositionValidationFailure.invalidLayer }
            try validate(range: occurrence.outputRange, within: output.duration, outside: .rangeOutsideOutput)
            try validate(crop: occurrence.crop)
            try validate(outputRect: occurrence.outputRect)
            guard let asset = assets.first(where: { $0.id == occurrence.assetID }) else { throw CompositionValidationFailure.missingAsset }
            guard asset.digest == occurrence.assetDigest else { throw CompositionValidationFailure.assetDigestMismatch }
            guard let probe = asset.probe else { throw CompositionValidationFailure.missingProbe }
            switch occurrence.source {
            case .still:
                guard probe.imageDisplayedWidth != nil, probe.imageDisplayedHeight != nil else { throw CompositionValidationFailure.unsupportedAssetType }
            case .video(let range):
                guard let video = probe.video,
                      let sourceRange = video.timeRange,
                      sourceRange.count == 2,
                      let sourceStart = CompositionTime(value: sourceRange[0].value, timescale: sourceRange[0].timescale),
                      let sourceDuration = CompositionTime(value: sourceRange[1].value, timescale: sourceRange[1].timescale) else { throw CompositionValidationFailure.unsupportedAssetType }
                guard let durationValue = probe.durationValue,
                      let durationTimescale = probe.durationTimescale,
                      CompositionTime(value: durationValue, timescale: durationTimescale) != nil else { throw CompositionValidationFailure.missingProbe }
                try validate(range: range, within: CompositionRange(start: sourceStart, duration: sourceDuration).end(), outside: .rangeOutsideSource)
            }
            byLayer[occurrence.layer, default: []].append(occurrence.outputRange)
        }
        for ranges in byLayer.values {
            let ordered = try ranges.sorted { try $0.start.checkedCompare($1.start) == .orderedAscending }
            for pair in zip(ordered, ordered.dropFirst()) {
                if try pair.1.start.checkedCompare(pair.0.end()) == .orderedAscending { throw CompositionValidationFailure.sameLayerOverlap }
            }
        }
        var captions = Set<UUID>()
        var captionOrders = Set<Int>()
        for caption in self.captions {
            guard captions.insert(caption.id).inserted else { throw CompositionValidationFailure.duplicateCaption }
            guard captionOrders.insert(caption.order).inserted else { throw CompositionValidationFailure.duplicateCaptionOrder }
            guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompositionValidationFailure.emptyCaption }
            guard caption.layer >= 0 else { throw CompositionValidationFailure.invalidLayer }
            try validate(range: caption.outputRange, within: output.duration, outside: .rangeOutsideOutput)
        }
    }

    private var zero: CompositionTime { CompositionTime(value: 0, timescale: 1)! }

    private func validate(range: CompositionRange, within limit: CompositionTime, outside: CompositionValidationFailure) throws {
        guard try range.start.checkedCompare(zero) != .orderedAscending,
              try range.duration.checkedCompare(zero) == .orderedDescending else { throw CompositionValidationFailure.invalidRange }
        guard try range.end().checkedCompare(limit) != .orderedDescending else { throw outside }
    }

    private func validate(crop: CompositionCrop) throws {
        guard try crop.x.checkedCompare(zero) != .orderedAscending,
              try crop.y.checkedCompare(zero) != .orderedAscending,
              try crop.width.checkedCompare(zero) == .orderedDescending,
              try crop.height.checkedCompare(zero) == .orderedDescending else { throw CompositionValidationFailure.invalidCrop }
        let one = CompositionTime(value: 1, timescale: 1)!
        guard try crop.x.checkedAdd(crop.width).checkedCompare(one) != .orderedDescending,
              try crop.y.checkedAdd(crop.height).checkedCompare(one) != .orderedDescending else { throw CompositionValidationFailure.invalidCrop }
    }

    private func validate(outputRect: CompositionOutputRect) throws {
        guard try outputRect.x.checkedCompare(zero) != .orderedAscending,
              try outputRect.y.checkedCompare(zero) != .orderedAscending,
              try outputRect.width.checkedCompare(zero) == .orderedDescending,
              try outputRect.height.checkedCompare(zero) == .orderedDescending else { throw CompositionValidationFailure.invalidOutputRect }
        let one = CompositionTime(value: 1, timescale: 1)!
        guard try outputRect.x.checkedAdd(outputRect.width).checkedCompare(one) != .orderedDescending,
              try outputRect.y.checkedAdd(outputRect.height).checkedCompare(one) != .orderedDescending else { throw CompositionValidationFailure.invalidOutputRect }
    }
}
