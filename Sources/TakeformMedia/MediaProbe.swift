import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import CoreMedia
import Darwin

/// Read-only facts observed from one source file. This module does not select,
/// copy, deduplicate, transcode, or alter the source file.
public struct MediaSourceFacts: Sendable, Equatable {
    public let source: SourceIdentity
    public let containerIdentifier: String?
    public let image: ImageFacts?
    public let video: VideoFacts?
    public let audio: [AudioFacts]
    public let duration: RationalTime?
    public let livePhotoContentIdentifier: LivePhotoContentIdentifier?
    public let measurement: ProbeMeasurement

    public init(
        source: SourceIdentity,
        containerIdentifier: String?,
        image: ImageFacts?,
        video: VideoFacts?,
        audio: [AudioFacts],
        duration: RationalTime?,
        livePhotoContentIdentifier: LivePhotoContentIdentifier?,
        measurement: ProbeMeasurement
    ) {
        self.source = source
        self.containerIdentifier = containerIdentifier
        self.image = image
        self.video = video
        self.audio = audio
        self.duration = duration
        self.livePhotoContentIdentifier = livePhotoContentIdentifier
        self.measurement = measurement
    }
}

public struct SourceIdentity: Sendable, Equatable {
    public let byteLength: UInt64
    public let sha256: String

    public init(byteLength: UInt64, sha256: String) {
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

public struct RationalTime: Sendable, Equatable, Comparable {
    public let value: Int64
    public let timescale: Int32

    public init?(value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        self.value = value
        self.timescale = timescale
    }

    init?(_ time: CMTime) {
        guard time.isValid, !time.isIndefinite, !time.isPositiveInfinity, !time.isNegativeInfinity else {
            return nil
        }
        self.init(value: time.value, timescale: time.timescale)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        lhs.value * Int64(rhs.timescale) < rhs.value * Int64(lhs.timescale)
    }
}

public struct ImageFacts: Sendable, Equatable {
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let displayedWidth: Int
    public let displayedHeight: Int
    /// EXIF/CGImagePropertyOrientation raw value when supplied by the source.
    public let orientation: Int?
}

public struct VideoFacts: Sendable, Equatable {
    public let codecFourCC: String?
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let displayedWidth: Int
    public let displayedHeight: Int
    public let preferredTransform: [Double]
    public let nominalFrameRate: Double?
    public let timeRange: RationalTimeRange?
    /// Bounded measured PTS samples from the source stream, not inferred FPS.
    public let presentationTimestamps: [RationalTime]
    public let observedPresentationDeltaCount: Int
    public let isVariableFrameRate: Bool?
}

public struct RationalTimeRange: Sendable, Equatable {
    public let start: RationalTime
    public let duration: RationalTime
}

public struct AudioFacts: Sendable, Equatable {
    public let codecFourCC: String?
    public let channels: Int?
    public let sampleRate: Double?
    public let timeRange: RationalTimeRange?
}

public struct LivePhotoContentIdentifier: Sendable, Equatable {
    public enum Provenance: String, Sendable, Equatable {
        case imageIOMakerApple17
        case quickTimeContentIdentifier
    }

    public enum Normalization: String, Sendable, Equatable {
        case none
        /// The generated HEIC fixture stores a short ASCII identifier in a
        /// fixed-width MakerApple field and pads the unused bytes with dots.
        /// The observed raw value remains available in `value`.
        case trailingMakerApplePeriodPadding
    }

    /// The raw value returned by the platform metadata reader.
    public let value: String
    /// Explicit comparison value, separate from the raw observation.
    public let comparisonValue: String
    public let provenance: Provenance
    public let normalization: Normalization

    public init(value: String, provenance: Provenance, comparisonValue: String? = nil, normalization: Normalization = .none) {
        self.value = value
        self.comparisonValue = comparisonValue ?? value
        self.provenance = provenance
        self.normalization = normalization
    }
}

public enum LivePhotoPairEvidence: Sendable, Equatable {
    case confirmed(contentIdentifier: String)
    case candidate(reason: String)
    case unavailable(reason: String)
}

public enum MediaProbeFailure: Error, Sendable, Equatable {
    case cancelled
    case unreadableFile
    case unsupportedOrCorrupt(reason: String)
}

public enum MediaProbeResult: Sendable, Equatable {
    case success(MediaSourceFacts)
    case failure(MediaProbeFailure)
}

public struct ProbeMeasurement: Sendable, Equatable {
    public let elapsedNanoseconds: UInt64
    /// Process-wide peak RSS observed after this probe. It is not attributed
    /// solely to this source when other work shares the process.
    public let processPeakResidentBytes: UInt64?
    public let hashChunkBytes: Int
    public let maximumStoredPresentationTimestamps: Int
    public let presentationSamplesScanned: Int
}

public struct MediaProbe: Sendable {
    enum ProgressPoint: Sendable { case hashChunkRead, presentationSampleRead }

    public static let defaultHashChunkBytes = 64 * 1024
    public static let defaultMaximumStoredPresentationTimestamps = 96

    private let hashChunkBytes: Int
    private let maximumStoredPresentationTimestamps: Int
    private let progress: (@Sendable (ProgressPoint) -> Void)?

    public init(
        hashChunkBytes: Int = MediaProbe.defaultHashChunkBytes,
        maximumStoredPresentationTimestamps: Int = MediaProbe.defaultMaximumStoredPresentationTimestamps
    ) {
        self.init(hashChunkBytes: hashChunkBytes, maximumStoredPresentationTimestamps: maximumStoredPresentationTimestamps, progress: nil)
    }

    init(
        hashChunkBytes: Int,
        maximumStoredPresentationTimestamps: Int,
        progress: (@Sendable (ProgressPoint) -> Void)?
    ) {
        precondition(hashChunkBytes > 0)
        precondition(maximumStoredPresentationTimestamps > 1)
        self.hashChunkBytes = hashChunkBytes
        self.maximumStoredPresentationTimestamps = maximumStoredPresentationTimestamps
        self.progress = progress
    }

    public func inspect(_ url: URL) async -> MediaProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let source = try hash(url)
            try Task.checkCancellation()

            if let image = try imageFacts(url) {
                return .success(MediaSourceFacts(
                    source: source,
                    containerIdentifier: image.containerIdentifier,
                    image: image.facts,
                    video: nil,
                    audio: [],
                    duration: nil,
                    livePhotoContentIdentifier: image.contentIdentifier,
                    measurement: measurement(started: started, presentationSamplesScanned: 0)
                ))
            }

            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let tracks = try await asset.load(.tracks)
            let duration = RationalTime(try await asset.load(.duration))
            guard !tracks.isEmpty else {
                throw MediaProbeFailure.unsupportedOrCorrupt(reason: "No readable media tracks")
            }

            var video: VideoFacts?
            var audio: [AudioFacts] = []
            var scannedPresentationSamples = 0
            for track in tracks {
                try Task.checkCancellation()
                let mediaType = track.mediaType
                switch mediaType {
                case .video where video == nil:
                    let timed = try scanPresentationTimes(asset: asset, track: track)
                    scannedPresentationSamples += timed.scannedCount
                    video = try await makeVideoFacts(track: track, timing: timed)
                case .audio:
                    audio.append(try await makeAudioFacts(track: track))
                default:
                    continue
                }
            }

            let metadata = try await asset.load(.metadata)
            var liveID: LivePhotoContentIdentifier?
            for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        liveID = LivePhotoContentIdentifier(value: trimmed, provenance: .quickTimeContentIdentifier)
                        break
                    }
                }
            }

            return .success(MediaSourceFacts(
                source: source,
                containerIdentifier: containerIdentifier(for: url),
                image: nil,
                video: video,
                audio: audio,
                duration: duration,
                livePhotoContentIdentifier: liveID,
                measurement: measurement(started: started, presentationSamplesScanned: scannedPresentationSamples)
            ))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let failure as MediaProbeFailure {
            return .failure(failure)
        } catch {
            return .failure(.unsupportedOrCorrupt(reason: error.localizedDescription))
        }
    }

    /// Byte equality is a source-identity fact only; it does not decide whether
    /// two assets are the same moment or should be merged.
    public static func hasSameBytes(_ lhs: MediaSourceFacts, _ rhs: MediaSourceFacts) -> Bool {
        lhs.source == rhs.source
    }

    /// Filename and timestamps are deliberately not evidence. A pair is
    /// confirmed only when both independently measured content identifiers agree.
    public static func pairLivePhoto(still: MediaSourceFacts, motion: MediaSourceFacts) -> LivePhotoPairEvidence {
        guard still.image != nil else {
            return .candidate(reason: "Live Photo still must be an image source")
        }
        guard motion.video != nil else {
            return .candidate(reason: "Live Photo motion must be a video source")
        }
        guard let stillID = still.livePhotoContentIdentifier else {
            return .unavailable(reason: "Still has no measured Live Photo content identifier")
        }
        guard let motionID = motion.livePhotoContentIdentifier else {
            return .unavailable(reason: "Motion has no measured Live Photo content identifier")
        }
        guard stillID.comparisonValue == motionID.comparisonValue else {
            return .candidate(reason: "Measured Live Photo content identifiers disagree")
        }
        return .confirmed(contentIdentifier: stillID.comparisonValue)
    }

    private func hash(_ url: URL) throws -> SourceIdentity {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MediaProbeFailure.unreadableFile
        }
        defer { try? handle.close() }

        var digest = SHA256()
        var byteLength: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: hashChunkBytes) ?? Data()
            if data.isEmpty { break }
            progress?(.hashChunkRead)
            try Task.checkCancellation()
            digest.update(data: data)
            byteLength += UInt64(data.count)
        }
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return SourceIdentity(byteLength: byteLength, sha256: sha)
    }

    private func measurement(started: UInt64, presentationSamplesScanned: Int) -> ProbeMeasurement {
        var usage = rusage()
        let rss: UInt64?
        if getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 {
            rss = UInt64(usage.ru_maxrss)
        } else {
            rss = nil
        }
        return ProbeMeasurement(
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            processPeakResidentBytes: rss,
            hashChunkBytes: hashChunkBytes,
            maximumStoredPresentationTimestamps: maximumStoredPresentationTimestamps,
            presentationSamplesScanned: presentationSamplesScanned
        )
    }

    private func imageFacts(_ url: URL) throws -> (containerIdentifier: String?, facts: ImageFacts, contentIdentifier: LivePhotoContentIdentifier?)? {
        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif"]
        guard imageExtensions.contains(ext) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw MediaProbeFailure.unsupportedOrCorrupt(reason: "Image metadata is unreadable")
        }

        let orientation = properties[kCGImagePropertyOrientation] as? Int
        let swapsAxes = orientation.map { [5, 6, 7, 8].contains($0) } ?? false
        let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any]
        let contentID = (maker?["17" as CFString] as? String)
            ?? (maker?["17" as CFString] as? NSString).map(String.init)
        let live = contentID.map { raw -> LivePhotoContentIdentifier in
            let comparison = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let isFixedWidthPadding = comparison != raw
                && !comparison.isEmpty
                && raw.dropFirst(comparison.count).allSatisfy { $0 == "." }
            return LivePhotoContentIdentifier(
                value: raw,
                provenance: .imageIOMakerApple17,
                comparisonValue: isFixedWidthPadding ? comparison : raw,
                normalization: isFixedWidthPadding ? .trailingMakerApplePeriodPadding : .none
            )
        }
        let type = CGImageSourceGetType(source).map { String($0) }
        return (
            type,
            ImageFacts(
                encodedWidth: width,
                encodedHeight: height,
                displayedWidth: swapsAxes ? height : width,
                displayedHeight: swapsAxes ? width : height,
                orientation: orientation
            ),
            live
        )
    }

    private func makeVideoFacts(track: AVAssetTrack, timing: PresentationTiming) async throws -> VideoFacts {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let descriptions = try await track.load(.formatDescriptions)
        let transformed = naturalSize.applying(transform)
        let timeRange = try await track.load(.timeRange)
        let nominal = try await track.load(.nominalFrameRate)
        return VideoFacts(
            codecFourCC: descriptions.first.map(codecFourCC),
            encodedWidth: Int(naturalSize.width.rounded()),
            encodedHeight: Int(naturalSize.height.rounded()),
            displayedWidth: Int(abs(transformed.width).rounded()),
            displayedHeight: Int(abs(transformed.height).rounded()),
            preferredTransform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
            nominalFrameRate: nominal > 0 ? Double(nominal) : nil,
            timeRange: RationalTimeRange(start: RationalTime(timeRange.start)!, duration: RationalTime(timeRange.duration)!),
            presentationTimestamps: timing.stored,
            observedPresentationDeltaCount: timing.deltaCount,
            isVariableFrameRate: timing.deltaCount == 0 ? nil : timing.hasVariableDeltas
        )
    }

    private func makeAudioFacts(track: AVAssetTrack) async throws -> AudioFacts {
        let descriptions = try await track.load(.formatDescriptions)
        let timeRange = try await track.load(.timeRange)
        let basic = descriptions.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }.first
        return AudioFacts(
            codecFourCC: descriptions.first.map(codecFourCC),
            channels: basic.map { Int($0.pointee.mChannelsPerFrame) },
            sampleRate: basic.map { $0.pointee.mSampleRate },
            timeRange: RationalTimeRange(start: RationalTime(timeRange.start)!, duration: RationalTime(timeRange.duration)!)
        )
    }

    private func containerIdentifier(for url: URL) -> String? {
        if let identifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
            return identifier
        }
        let extensionValue = url.pathExtension.lowercased()
        return extensionValue.isEmpty ? nil : "public.\(extensionValue)"
    }

    private func codecFourCC(_ description: CMFormatDescription) -> String {
        let subtype = UInt32(CMFormatDescriptionGetMediaSubType(description))
        let bytes = [24, 16, 8, 0].map { UInt8((subtype >> $0) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return String(format: "0x%08x", subtype)
        }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", subtype)
    }

    private func scanPresentationTimes(asset: AVAsset, track: AVAssetTrack) throws -> PresentationTiming {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaProbeFailure.unsupportedOrCorrupt(reason: "Cannot read video presentation timestamps")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaProbeFailure.unsupportedOrCorrupt(reason: reader.error?.localizedDescription ?? "Cannot start video reader")
        }

        var stored: [RationalTime] = []
        var previous: CMTime?
        var firstDelta: CMTime?
        var hasVariableDeltas = false
        var deltaCount = 0
        var scannedCount = 0
        while let sample = output.copyNextSampleBuffer() {
            // AVAssetReader can emit timing-only boundary buffers. They do not
            // describe a displayed video sample and must not affect stored PTS
            // or cadence classification. Do not require a block buffer here:
            // valid image-backed samples may not expose one.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            progress?(.presentationSampleRead)
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            if let rational = RationalTime(timestamp), stored.count < maximumStoredPresentationTimestamps {
                stored.append(rational)
            }
            if let previous {
                let delta = CMTimeSubtract(timestamp, previous)
                if delta.isValid, delta > .zero {
                    if let firstDelta, CMTimeCompare(delta, firstDelta) != 0 {
                        hasVariableDeltas = true
                    } else if firstDelta == nil {
                        firstDelta = delta
                    }
                    deltaCount += 1
                }
            }
            previous = timestamp
            scannedCount += 1
        }
        guard reader.status == .completed else {
            throw MediaProbeFailure.unsupportedOrCorrupt(reason: reader.error?.localizedDescription ?? "Video timestamp reader did not complete")
        }
        return PresentationTiming(stored: stored, scannedCount: scannedCount, deltaCount: deltaCount, hasVariableDeltas: hasVariableDeltas)
    }
}

private struct PresentationTiming {
    let stored: [RationalTime]
    let scannedCount: Int
    let deltaCount: Int
    let hasVariableDeltas: Bool
}
