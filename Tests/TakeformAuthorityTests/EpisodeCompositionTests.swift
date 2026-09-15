import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TakeformAuthorityAppServiceCore
import TakeformCore

final class EpisodeCompositionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("takeform-composition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCompositionPersistsCanonicallyAndReplaysItsCommand() throws {
        let package = root.appendingPathComponent("Recipe.takeform")
        let credential = "creator"
        let authority = try ProjectAuthority(packageURL: package)
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        let channel = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Harbor", initialRecipe: [:])), credential: credential)
        guard case let .applied(channelDocument) = channel.outcome else { return XCTFail("channel command failed") }
        let episode = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: channelDocument.revision, command: .createEpisode(name: "Recap", recipeVersion: 1)), credential: credential)
        guard case let .applied(episodeDocument) = episode.outcome, let target = episodeDocument.episodes.first else { return XCTFail("episode command failed") }

        let source = root.appendingPathComponent("still.png")
        try png().write(to: source)
        let imported = try authority.importManagedSources([source], credential: credential)
        guard case let .imported(asset) = imported.first else { return XCTFail("image import failed") }
        let current = try authority.open().document
        let invalid = try makeComposition(episodeID: target.id, asset: asset, second: asset, secondLayer: 0)
        let rejected = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: current.revision, command: .replaceEpisodeComposition(episodeID: target.id, composition: invalid)), credential: credential)
        XCTAssertEqual(rejected.outcome, .rejected(reason: CompositionValidationFailure.sameLayerOverlap.reason))
        XCTAssertEqual(try authority.open().document.revision, current.revision)
        XCTAssertTrue(try authority.open().document.episodeCompositions.isEmpty)
        let composition = try makeComposition(episodeID: target.id, asset: asset)
        let envelope = CommandEnvelope(expectedRevision: current.revision, command: .replaceEpisodeComposition(episodeID: target.id, composition: composition))

        let applied = try authority.executeForAuthenticatedCreator(envelope, credential: credential)
        let replay = try authority.executeForAuthenticatedCreator(envelope, credential: credential)
        guard case let .applied(saved) = applied.outcome else { return XCTFail("composition command failed") }
        XCTAssertEqual(replay, applied)
        XCTAssertEqual(saved.episodeCompositions, [composition])
        XCTAssertEqual(try authority.open().document.episodeCompositions, [composition])
        XCTAssertEqual(try composition.canonicalData(), try equivalentComposition(composition, asset: asset).canonicalData())

        let stale = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: current.revision, command: .replaceEpisodeComposition(episodeID: target.id, composition: composition)), credential: credential)
        XCTAssertEqual(stale.outcome, .conflict(currentRevision: saved.revision))
        XCTAssertEqual(try authority.open().document.episodeCompositions, [composition])
    }

    func testCompositionValidationPermitsCrossLayerPanelsAndRejectsAmbiguity() throws {
        let episode = Episode(name: "Panels", recipeVersion: 1)
        let image = ManagedAsset(digest: String(repeating: "a", count: 64), byteLength: 10, filename: "still.png", mediaType: "image", probe: imageProbe)
        let second = ManagedAsset(digest: String(repeating: "b", count: 64), byteLength: 11, filename: "second.png", mediaType: "image", probe: imageProbe)
        let composition = try makeComposition(episodeID: episode.id, asset: image, second: second, secondLayer: 1)
        XCTAssertNoThrow(try composition.validate(episodes: [episode], assets: [image, second]))

        let ambiguous = try makeComposition(episodeID: episode.id, asset: image, second: second, secondLayer: 0)
        XCTAssertThrowsError(try ambiguous.validate(episodes: [episode], assets: [image, second])) { XCTAssertEqual($0 as? CompositionValidationFailure, .sameLayerOverlap) }

        let audio = ManagedAsset(digest: String(repeating: "c", count: 64), byteLength: 12, filename: "tone.aiff", mediaType: "audio", probe: ManagedAssetProbe(audio: [.init(codec: "lpcm", channels: 1, sampleRate: 48_000, timeRange: [.init(0, 1), .init(12, 1)])]))
        let audioComposition = try makeComposition(episodeID: episode.id, asset: audio)
        XCTAssertThrowsError(try audioComposition.validate(episodes: [episode], assets: [audio])) { XCTAssertEqual($0 as? CompositionValidationFailure, .unsupportedAssetType) }

        let noProbe = ManagedAsset(digest: String(repeating: "d", count: 64), byteLength: 13, filename: "legacy.png", mediaType: "image")
        let legacyComposition = try makeComposition(episodeID: episode.id, asset: noProbe)
        XCTAssertThrowsError(try legacyComposition.validate(episodes: [episode], assets: [noProbe])) { XCTAssertEqual($0 as? CompositionValidationFailure, .missingProbe) }

        let video = ManagedAsset(digest: String(repeating: "e", count: 64), byteLength: 14, filename: "clip.mov", mediaType: "video", probe: ManagedAssetProbe(durationValue: 8, durationTimescale: 1, video: .init(codec: "avc1", encodedWidth: 1920, encodedHeight: 1080, displayedWidth: 1920, displayedHeight: 1080, transform: [1, 0, 0, 1, 0, 0], nominalFrameRate: 30, timeRange: [.init(0, 1), .init(8, 1)], presentationTimestamps: [.init(0, 1)], observedPresentationDeltaCount: 1, isVariableFrameRate: false)))
        let videoOccurrence = CompositionOccurrence(assetID: video.id, assetDigest: video.digest, source: .video(try range(7, 2)), outputRange: try range(0, 2), layer: 0, order: 0, crop: try crop())
        let badVideoRange = EpisodeComposition(episodeID: episode.id, output: CompositionOutput(width: 1920, height: 1080, frameRate: try time(30), duration: try time(2)), occurrences: [videoOccurrence], captions: [])
        XCTAssertThrowsError(try badVideoRange.validate(episodes: [episode], assets: [video])) { XCTAssertEqual($0 as? CompositionValidationFailure, .rangeOutsideSource) }
        XCTAssertThrowsError(try JSONDecoder().decode(CompositionTime.self, from: Data("{\"value\":1,\"timescale\":0}".utf8)))
    }

    func testLegacyProjectDocumentDecodesWithoutCompositions() throws {
        let document = ProjectDocument()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "episodeCompositions")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertTrue(try JSONDecoder().decode(ProjectDocument.self, from: legacy).episodeCompositions.isEmpty)
    }

    private var imageProbe: ManagedAssetProbe {
        ManagedAssetProbe(imageEncodedWidth: 1920, imageEncodedHeight: 1080, imageDisplayedWidth: 1920, imageDisplayedHeight: 1080, imageOrientation: 1)
    }

    private func makeComposition(episodeID: UUID, asset: ManagedAsset, second: ManagedAsset? = nil, secondLayer: Int = 1) throws -> EpisodeComposition {
        let output = CompositionOutput(width: 1920, height: 1080, frameRate: try time(30), duration: try time(12))
        let first = CompositionOccurrence(assetID: asset.id, assetDigest: asset.digest, source: .still, outputRange: try range(0, 12), layer: 0, order: 0, crop: try crop())
        var occurrences = [first]
        if let second {
            occurrences.append(CompositionOccurrence(assetID: second.id, assetDigest: second.digest, source: .still, outputRange: try range(6, 6), layer: secondLayer, order: 1, crop: try crop()))
        }
        return EpisodeComposition(episodeID: episodeID, output: output, occurrences: occurrences, captions: [CompositionCaption(text: "Harbor recap", outputRange: try range(0, 3), layer: 2)])
    }

    private func equivalentComposition(_ original: EpisodeComposition, asset: ManagedAsset) throws -> EpisodeComposition {
        let output = CompositionOutput(width: 1920, height: 1080, frameRate: try time(60, 2), duration: try time(24, 2))
        let occurrence = CompositionOccurrence(id: original.occurrences[0].id, assetID: asset.id, assetDigest: asset.digest, source: .still, outputRange: try range(0, 24, scale: 2), layer: 0, order: 0, crop: try crop())
        return EpisodeComposition(episodeID: original.episodeID, output: output, occurrences: [occurrence], captions: [CompositionCaption(id: original.captions[0].id, text: "Harbor recap", outputRange: try range(0, 6, scale: 2), layer: 2)])
    }

    private func time(_ value: Int64, _ timescale: Int32 = 1) throws -> CompositionTime {
        guard let result = CompositionTime(value: value, timescale: timescale) else { throw CompositionValidationFailure.invalidRange }
        return result
    }

    private func range(_ start: Int64, _ duration: Int64, scale: Int32 = 1) throws -> CompositionRange { CompositionRange(start: try time(start, scale), duration: try time(duration, scale)) }
    private func crop() throws -> CompositionCrop { CompositionCrop(x: try time(0), y: try time(0), width: try time(1), height: try time(1)) }

    private func png() throws -> Data {
        let data = NSMutableData()
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
