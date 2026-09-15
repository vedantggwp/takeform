import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TakeformAuthorityAppServiceCore
import TakeformAppAuthorityWire
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
        XCTAssertEqual(composition.occurrences[0].outputRect, try outputRect(0, 1, 0, 1, width: 1, 2, height: 1, 1))
        XCTAssertEqual(composition.occurrences[1].outputRect, try outputRect(1, 2, 0, 1, width: 1, 2, height: 1, 1))

        let lowerPanel = CompositionOccurrence(id: UUID(), assetID: image.id, assetDigest: image.digest, source: .still, outputRange: try range(0, 1), layer: 0, order: 0, crop: try crop(), outputRect: try outputRect(2, 8, 2, 8, width: 4, 8, height: 4, 8))
        let nonzeroY = EpisodeComposition(episodeID: episode.id, output: CompositionOutput(width: 1920, height: 1080, frameRate: try time(30), duration: try time(1)), occurrences: [lowerPanel], captions: [])
        XCTAssertNoThrow(try nonzeroY.validate(episodes: [episode], assets: [image]))
        let canonicalNonzeroY = try JSONDecoder().decode(EpisodeComposition.self, from: nonzeroY.canonicalData())
        XCTAssertEqual(canonicalNonzeroY.occurrences[0].outputRect, try outputRect(1, 4, 1, 4, width: 1, 2, height: 1, 2))

        let ambiguous = try makeComposition(episodeID: episode.id, asset: image, second: second, secondLayer: 0)
        XCTAssertThrowsError(try ambiguous.validate(episodes: [episode], assets: [image, second])) { XCTAssertEqual($0 as? CompositionValidationFailure, .sameLayerOverlap) }

        let permuted = EpisodeComposition(episodeID: composition.episodeID, output: composition.output, occurrences: Array(composition.occurrences.reversed()), captions: Array(composition.captions.reversed()))
        XCTAssertEqual(try composition.canonicalData(), try permuted.canonicalData())

        let captionA = CompositionCaption(text: "A", outputRange: try range(0, 3), layer: 0, order: 0)
        let captionB = CompositionCaption(text: "B", outputRange: try range(1, 3), layer: 0, order: 1)
        let captionsForward = EpisodeComposition(episodeID: episode.id, output: composition.output, occurrences: composition.occurrences, captions: [captionA, captionB])
        let captionsReverse = EpisodeComposition(episodeID: episode.id, output: composition.output, occurrences: composition.occurrences, captions: [captionB, captionA])
        XCTAssertEqual(try captionsForward.canonicalData(), try captionsReverse.canonicalData())

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

        let overflow = CompositionOccurrence(assetID: image.id, assetDigest: image.digest, source: .still, outputRange: try range(.max, 1), layer: 0, order: 0, crop: try crop())
        let overflowComposition = EpisodeComposition(episodeID: episode.id, output: CompositionOutput(width: 1, height: 1, frameRate: try time(1), duration: try time(.max)), occurrences: [overflow], captions: [])
        XCTAssertThrowsError(try overflowComposition.validate(episodes: [episode], assets: [image])) { XCTAssertEqual($0 as? CompositionValidationFailure, .rationalOverflow) }

        let invalidRect = CompositionOccurrence(assetID: image.id, assetDigest: image.digest, source: .still, outputRange: try range(0, 1), layer: 0, order: 0, crop: try crop(), outputRect: try outputRect(3, 4, 0, 1, width: 1, 2, height: 1, 1))
        let invalidPlacement = EpisodeComposition(episodeID: episode.id, output: CompositionOutput(width: 1, height: 1, frameRate: try time(1), duration: try time(1)), occurrences: [invalidRect], captions: [])
        XCTAssertThrowsError(try invalidPlacement.validate(episodes: [episode], assets: [image])) { XCTAssertEqual($0 as? CompositionValidationFailure, .invalidOutputRect) }
    }

    func testLegacyProjectDocumentDecodesWithoutCompositions() throws {
        let document = ProjectDocument()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "episodeCompositions")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertTrue(try JSONDecoder().decode(ProjectDocument.self, from: legacy).episodeCompositions.isEmpty)
    }

    func testRenderRequestIsAtomicIdempotentAndNeverClaimsMachineArtifact() throws {
        let package = root.appendingPathComponent("Render.takeform")
        let credential = "creator"
        let authority = try ProjectAuthority(packageURL: package)
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        guard case let .applied(channel) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Harbor", initialRecipe: [:])), credential: credential).outcome else { return XCTFail("channel setup failed") }
        guard case let .applied(episodes) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: channel.revision, command: .createEpisode(name: "Recap", recipeVersion: 1)), credential: credential).outcome,
              let episode = episodes.episodes.first else { return XCTFail("episode setup failed") }
        let source = root.appendingPathComponent("still.png")
        try png().write(to: source)
        guard case let .imported(asset) = try authority.importManagedSources([source], credential: credential).first else { return XCTFail("asset setup failed") }
        let beforeComposition = try authority.open().document
        let composition = try makeComposition(episodeID: episode.id, asset: asset)
        guard case let .applied(committed) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: beforeComposition.revision, command: .replaceEpisodeComposition(episodeID: episode.id, composition: composition)), credential: credential).outcome else { return XCTFail("composition setup failed") }
        let digest = SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
        let request = CommandEnvelope(expectedRevision: committed.revision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4))

        let first = try authority.requestEpisodeRenderForAuthenticatedCreator(request, credential: credential)
        guard case let .renderRequested(status) = first.outcome else { return XCTFail("render request was not recorded") }
        XCTAssertEqual(status.logicalState, .requested)
        XCTAssertEqual(status.progress, .indeterminate)
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(status.requestedRevision, committed.revision)
        XCTAssertEqual(try authority.open().document.revision, committed.revision, "logical render request must not revise portable document")
        XCTAssertEqual(try authority.requestEpisodeRenderForAuthenticatedCreator(request, credential: credential), first, "exact command replay must return stored request")
        let malformedReplay = CommandEnvelope(id: request.id, expectedRevision: request.expectedRevision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: String(repeating: "0", count: 64), format: .mp4))
        XCTAssertEqual(try authority.requestEpisodeRenderForAuthenticatedCreator(malformedReplay, credential: credential).outcome, .rejected(reason: "command-id-reused-with-different-request"), "a changed caller-supplied digest must not replay an accepted request")
        let mismatch = try authority.requestEpisodeRenderForAuthenticatedCreator(CommandEnvelope(expectedRevision: committed.revision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: String(repeating: "0", count: 64), format: .mp4)), credential: credential)
        XCTAssertEqual(mismatch.outcome, .rejected(reason: "render-composition-digest-mismatch"))
        let replacement = EpisodeComposition(episodeID: episode.id, output: composition.output, clipAudioPolicy: composition.clipAudioPolicy, occurrences: composition.occurrences, captions: [CompositionCaption(text: "Changed after render request", outputRange: try range(0, 3), layer: 2, order: 0)])
        guard case let .applied(replaced) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: committed.revision, command: .replaceEpisodeComposition(episodeID: episode.id, composition: replacement)), credential: credential).outcome else { return XCTFail("composition replacement failed") }
        XCTAssertEqual(try authority.requestEpisodeRenderForAuthenticatedCreator(request, credential: credential), first, "an exact request must replay after its episode composition later changes")
        let stale = try authority.requestEpisodeRenderForAuthenticatedCreator(CommandEnvelope(expectedRevision: Revision(committed.revision.value - 1), command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4)), credential: credential)
        XCTAssertEqual(stale.outcome, .conflict(currentRevision: replaced.revision))

        XCTAssertEqual(try authority.renderStatusForAuthenticatedCreator(jobID: status.jobID, credential: credential), status)
        let cancelID = CommandID()
        let cancelled = try authority.cancelEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: cancelID, credential: credential)
        XCTAssertEqual(cancelled.logicalState, .cancelled)
        XCTAssertEqual(try authority.cancelEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: cancelID, credential: credential), cancelled, "cancel operation replay must be idempotent")
        let pairedToken = "paired-render-token"
        let pairedGrant = try authority.issuePairedCLIGrant(credential: credential, label: "render", scopes: [.editProject], expiresAt: .distantFuture, rawToken: pairedToken)
        guard case let .renderStatus(pairedStatus) = CreatorAuthorityService.respond(to: .pairedRenderStatus(package, status.jobID, pairedGrant.id, pairedToken), from: .cli) else { return XCTFail("paired status route failed") }
        XCTAssertEqual(pairedStatus, cancelled)
        guard case let .renderContext(context) = CreatorAuthorityService.respond(to: .pairedRenderContext(package, episode.id, pairedGrant.id, pairedToken), from: .cli) else { return XCTFail("paired render context route failed") }
        XCTAssertEqual(context.episodeID, episode.id)
        XCTAssertEqual(context.revision, replaced.revision)
        XCTAssertEqual(context.compositionDigest, SHA256.hash(data: try replacement.canonicalData()).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(context.output, replacement.output)
        guard case .failure(.creatorAuthorizationRequired) = CreatorAuthorityService.respond(to: .pairedRenderContext(package, episode.id, pairedGrant.id, pairedToken), from: .app) else { return XCTFail("app role must not impersonate paired render context") }
        guard case .failure(.creatorAuthorizationRequired) = CreatorAuthorityService.respond(to: .requestRender(package, request, Data(credential.utf8)), from: .cli) else { return XCTFail("CLI must not use app creator render route") }
        let materialized = try authority.materializeEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: CommandID(), credential: credential)
        XCTAssertEqual(materialized, .unavailable(cancelled))
        let destination = root.appendingPathComponent("export.mp4")
        try Data("existing creator output".utf8).write(to: destination)
        let exportID = CommandID()
        let exported = try authority.exportEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: exportID, destination: destination, decision: .refuseExisting, credential: credential)
        XCTAssertEqual(exported, .unavailable(cancelled))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing creator output".utf8), "unavailable renderer must not clobber an explicit destination")
        XCTAssertEqual(try authority.exportEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: exportID, destination: destination, decision: .refuseExisting, credential: credential), exported, "an exact export retry must replay its result")
        XCTAssertThrowsError(try authority.exportEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: exportID, destination: root.appendingPathComponent("other-export.mp4"), decision: .refuseExisting, credential: credential), "one export operation ID must not be reused for another destination")
    }

    func testServiceOwnedWorkerCompletesAndExportsWithoutClobbering() throws {
        let package = root.appendingPathComponent("Worker.takeform")
        let credential = "creator"
        let authority = try ProjectAuthority(packageURL: package)
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        guard case let .applied(channel) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Harbor", initialRecipe: [:])), credential: credential).outcome,
              case let .applied(episodes) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: channel.revision, command: .createEpisode(name: "Recap", recipeVersion: 1)), credential: credential).outcome,
              let episode = episodes.episodes.first else { return XCTFail("worker project setup failed") }
        let source = root.appendingPathComponent("still.png")
        try png().write(to: source)
        guard case let .imported(asset) = try authority.importManagedSources([source], credential: credential).first else { return XCTFail("worker asset setup failed") }
        let composition = try makeComposition(episodeID: episode.id, asset: asset)
        let imported = try authority.open().document
        guard case let .applied(composed) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: imported.revision, command: .replaceEpisodeComposition(episodeID: episode.id, composition: composition)), credential: credential).outcome else { return XCTFail("worker composition setup failed") }
        let digest = SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
        let request = CommandEnvelope(expectedRevision: composed.revision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4))
        let runtime = try fakeRenderRuntime()
        let coordinator = RenderExecutionCoordinator.shared
        coordinator.installTestRuntime { _ in runtime }
        defer { coordinator.clearTestRuntime() }
        guard case let .result(renderResult) = CreatorAuthorityService.respond(to: .requestRender(package, request, Data(credential.utf8)), from: .app),
              case let .renderRequested(status) = renderResult.outcome else { return XCTFail("app worker request route failed") }
        var completedInput: RenderAttemptInput?
        for _ in 0..<100 {
            let candidate = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
            if candidate.status.logicalState == .completed, coordinator.availability(for: candidate) == .available { completedInput = candidate; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let finalInput = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
        let finalState = finalInput.status.logicalState
        let failureCode = coordinator.failureCode(for: finalInput) ?? "none"
        _ = try XCTUnwrap(completedInput, "worker did not publish a verified artifact; final state \(finalState), completion \(failureCode)")
        let pairedToken = "paired-render-worker"
        let paired = try authority.issuePairedCLIGrant(credential: credential, label: "worker", scopes: [.editProject], expiresAt: .distantFuture, rawToken: pairedToken)
        guard case let .renderPlaybackSource(playback) = CreatorAuthorityService.respond(to: .playbackSource(package, status.jobID, CommandID(), Data(credential.utf8)), from: .app) else { return XCTFail("app playback route did not return a freshly verified source") }
        XCTAssertEqual(playback.jobID, status.jobID)
        XCTAssertEqual(playback.requestedRevision, status.requestedRevision)
        XCTAssertEqual(playback.compositionDigest, status.compositionDigest)
        XCTAssertEqual(playback.output, composition.output)
        XCTAssertEqual(playback.videoStreamCount, 1)
        XCTAssertEqual(playback.audioStreamCount, 0)
        XCTAssertEqual(playback.descriptor.jobID, status.jobID)
        XCTAssertEqual(try Data(contentsOf: playback.artifactURL), Data("render".utf8))
        guard case .failure(.creatorAuthorizationRequired) = CreatorAuthorityService.respond(to: .playbackSource(package, status.jobID, CommandID(), Data(credential.utf8)), from: .cli) else { return XCTFail("CLI must not receive an app playback URL") }
        guard case let .renderMaterialization(.descriptor(descriptor)) = CreatorAuthorityService.respond(to: .pairedMaterializeRender(package, status.jobID, CommandID(), paired.id, pairedToken), from: .cli) else { return XCTFail("paired materialization route did not expose the verified descriptor") }
        XCTAssertEqual(descriptor.jobID, status.jobID)
        let destination = root.appendingPathComponent("export.mp4")
        guard case let .renderExport(.exported(exported)) = CreatorAuthorityService.respond(to: .pairedExportRender(package, status.jobID, CommandID(), destination, .refuseExisting, paired.id, pairedToken), from: .cli) else { return XCTFail("paired export route did not publish the verified artifact") }
        XCTAssertEqual(exported, descriptor)
        XCTAssertEqual(try Data(contentsOf: destination), Data("render".utf8))
        guard case .failure(.rejected) = CreatorAuthorityService.respond(to: .pairedExportRender(package, status.jobID, CommandID(), destination, .refuseExisting, paired.id, pairedToken), from: .cli) else { return XCTFail("no-clobber collision must reject rather than replace the destination") }
        XCTAssertEqual(try Data(contentsOf: destination), Data("render".utf8))
        let movedPackage = root.appendingPathComponent("MovedWorker.takeform")
        try FileManager.default.moveItem(at: package, to: movedPackage)
        let movedAuthority = try ProjectAuthority(packageURL: movedPackage)
        _ = try movedAuthority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: true)
        let movedInput = try movedAuthority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
        XCTAssertEqual(coordinator.materialization(for: movedInput), .unavailable(movedInput.status), "machine-local artifact availability must not survive an explicit package rebind")
        guard case .failure = CreatorAuthorityService.respond(to: .playbackSource(movedPackage, status.jobID, CommandID(), Data(credential.utf8)), from: .app) else { return XCTFail("a rebound package must not receive the prior machine-local playback URL") }
    }

    func testCancelledWorkerIsReapedAndCannotPublishItsLateReceipt() throws {
        let package = root.appendingPathComponent("CancelledWorker.takeform")
        let credential = "creator"
        let authority = try ProjectAuthority(packageURL: package)
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        guard case let .applied(channel) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Harbor", initialRecipe: [:])), credential: credential).outcome,
              case let .applied(episodes) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: channel.revision, command: .createEpisode(name: "Recap", recipeVersion: 1)), credential: credential).outcome,
              let episode = episodes.episodes.first else { return XCTFail("worker project setup failed") }
        let source = root.appendingPathComponent("still.png")
        try png().write(to: source)
        guard case let .imported(asset) = try authority.importManagedSources([source], credential: credential).first else { return XCTFail("worker asset setup failed") }
        let composition = try makeComposition(episodeID: episode.id, asset: asset)
        let imported = try authority.open().document
        guard case let .applied(composed) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: imported.revision, command: .replaceEpisodeComposition(episodeID: episode.id, composition: composition)), credential: credential).outcome else { return XCTFail("worker composition setup failed") }
        let digest = SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
        let request = CommandEnvelope(expectedRevision: composed.revision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4))
        guard case let .renderRequested(status) = try authority.requestEpisodeRenderForAuthenticatedCreator(request, credential: credential).outcome else { return XCTFail("worker request setup failed") }
        let input = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
        let slowWorker = "#!/bin/sh\ntrap '' TERM\nstage=\"$TAKEFORM_RENDER_STAGE\"\njob=\"$TAKEFORM_RENDER_JOB\"\nattempt=\"$TAKEFORM_RENDER_ATTEMPT\"\nhash=\"$TAKEFORM_RENDER_SNAPSHOT_SHA256\"\n/bin/sleep 0.25\nprintf render > \"$stage/render.mp4\"\nsha=$(/usr/bin/shasum -a 256 \"$stage/render.mp4\" | /usr/bin/awk '{print $1}')\nprintf '{\\\"schemaVersion\\\":1,\\\"jobID\\\":\\\"%s\\\",\\\"attemptID\\\":\\\"%s\\\",\\\"outcome\\\":\\\"succeeded\\\",\\\"input\\\":{\\\"compositionDigest\\\":\\\"ignored\\\",\\\"snapshotSHA256\\\":\\\"%s\\\",\\\"assets\\\":[]},\\\"artifact\\\":{\\\"fileName\\\":\\\"render.mp4\\\",\\\"byteLength\\\":6,\\\"sha256\\\":\\\"%s\\\"}}' \"$job\" \"$attempt\" \"$hash\" \"$sha\" > \"$stage/attempt-receipt.json\"\n"
        let runtime = try fakeRenderRuntime(workerScript: slowWorker)
        let coordinator = RenderExecutionCoordinator { projectID in projectID == input.snapshot.projectID ? runtime : nil }
        XCTAssertEqual(coordinator.start(authority: authority, input: input), .running)
        let cancelled = try authority.cancelEpisodeRenderForAuthenticatedCreator(jobID: status.jobID, operationID: CommandID(), credential: credential)
        XCTAssertEqual(cancelled.logicalState, .cancelled)
        coordinator.cancel(projectID: input.snapshot.projectID, jobID: status.jobID)

        var reaped: pid_t?
        for _ in 0..<100 {
            let candidate = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
            reaped = coordinator.lastReapedPID(for: candidate)
            if reaped != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let final = try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential)
        XCTAssertEqual(final.status.logicalState, .cancelled)
        let pid = try XCTUnwrap(reaped, "the owned child was not reaped")
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(coordinator.materialization(for: final), .unavailable(final.status))
        let machineJob = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takeform/Authority/\(input.snapshot.projectID.uuidString)/renders/\(status.jobID.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineJob.appendingPathComponent("current.json").path), "a late receipt must not publish a cancelled job")
        let late = try authority.transitionRenderRequest(jobID: status.jobID, snapshotSHA256: SHA256.hash(data: input.snapshotJSON).map { String(format: "%02x", $0) }.joined(), to: .completed)
        XCTAssertEqual(late.logicalState, .cancelled, "a retained worker receipt cannot revive a cancelled request")
    }

    func testRecoveryInterruptsOrphanedRequestedRenderWithoutStartingAnotherWorker() throws {
        let fixture = try requestedRender(named: "Interrupted")
        guard case let .renderStatus(status) = CreatorAuthorityService.respond(to: .renderStatus(fixture.package, fixture.status.jobID, Data(fixture.credential.utf8)), from: .app) else { return XCTFail("service status route failed") }
        XCTAssertEqual(status.logicalState, .interrupted)
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(try fixture.authority.renderAttemptInputForAuthenticatedCreator(jobID: fixture.status.jobID, credential: fixture.credential).status.logicalState, .interrupted)
    }

    func testRecoveryAcceptsOnlyMarkerBoundVerifiedCompletion() throws {
        let fixture = try requestedRender(named: "Recovered")
        let runtime = try fakeRenderRuntime()
        let coordinator = RenderExecutionCoordinator { _ in runtime }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takeform/Authority/\(fixture.input.snapshot.projectID.uuidString)/renders/\(fixture.status.jobID.uuidString)")
        let attemptID = UUID()
        let stage = root.appendingPathComponent("\(attemptID.uuidString).stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let snapshotSHA = SHA256.hash(data: fixture.input.snapshotJSON).map { String(format: "%02x", $0) }.joined()
        let marker: [String: Any] = ["schemaVersion": 1, "projectID": fixture.input.snapshot.projectID.uuidString, "jobID": fixture.status.jobID.uuidString, "attemptID": attemptID.uuidString, "snapshotSHA256": snapshotSHA, "machineBindingDigest": fixture.input.machineBindingDigest]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: stage.appendingPathComponent("attempt-owner.json"))
        let bytes = Data("render".utf8)
        try bytes.write(to: stage.appendingPathComponent("render.mp4"))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let receipt: [String: Any] = ["schemaVersion": 1, "jobID": fixture.status.jobID.uuidString, "attemptID": attemptID.uuidString, "outcome": "succeeded", "input": ["compositionDigest": "ignored", "snapshotSHA256": snapshotSHA, "assets": []], "artifact": ["fileName": "render.mp4", "byteLength": bytes.count, "sha256": sha]]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: stage.appendingPathComponent("attempt-receipt.json"))
        coordinator.reconcile(authority: fixture.authority)
        let final = try fixture.authority.renderAttemptInputForAuthenticatedCreator(jobID: fixture.status.jobID, credential: fixture.credential)
        XCTAssertEqual(final.status.logicalState, .completed)
        XCTAssertEqual(coordinator.availability(for: final), .available)
    }

    func testWrongCanvasReceiptCannotPublishRenderArtifact() throws {
        let fixture = try requestedRender(named: "WrongCanvas")
        let wrongProbe = "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo FakeTool 1.0; else printf '{\\\"streams\\\":[{\\\"codec_type\\\":\\\"video\\\",\\\"width\\\":1280,\\\"height\\\":720,\\\"avg_frame_rate\\\":\\\"30/1\\\",\\\"nb_frames\\\":\\\"360\\\"}],\\\"format\\\":{\\\"duration\\\":\\\"12.0\\\"}}\\n'; fi\n"
        let runtime = try fakeRenderRuntime(ffprobeScript: wrongProbe)
        let coordinator = RenderExecutionCoordinator { _ in runtime }
        XCTAssertEqual(coordinator.start(authority: fixture.authority, input: fixture.input), .running)
        for _ in 0..<100 {
            let current = try fixture.authority.renderAttemptInputForAuthenticatedCreator(jobID: fixture.status.jobID, credential: fixture.credential)
            if current.status.logicalState != .requested { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let final = try fixture.authority.renderAttemptInputForAuthenticatedCreator(jobID: fixture.status.jobID, credential: fixture.credential)
        XCTAssertEqual(final.status.logicalState, .failed)
        XCTAssertEqual(coordinator.materialization(for: final), .unavailable(final.status))
    }

    func testLegacyOccurrenceDefaultsToFullCanvasOutputRect() throws {
        let occurrence = CompositionOccurrence(assetID: UUID(), assetDigest: String(repeating: "a", count: 64), source: .still, outputRange: try range(0, 1), layer: 0, order: 0, crop: try crop())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(occurrence)) as? [String: Any])
        object.removeValue(forKey: "outputRect")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(try JSONDecoder().decode(CompositionOccurrence.self, from: legacy).outputRect, .fullCanvas)
    }

    private var imageProbe: ManagedAssetProbe {
        ManagedAssetProbe(imageEncodedWidth: 1920, imageEncodedHeight: 1080, imageDisplayedWidth: 1920, imageDisplayedHeight: 1080, imageOrientation: 1)
    }

    private func requestedRender(named name: String) throws -> (authority: ProjectAuthority, package: URL, credential: String, status: EpisodeRenderRequestStatus, input: RenderAttemptInput) {
        let package = root.appendingPathComponent("\(name).takeform")
        let credential = "creator"
        let authority = try ProjectAuthority(packageURL: package)
        let initial = try authority.openForAuthenticatedCreator(credential: credential, rebindMovedPackage: false).document
        guard case let .applied(channel) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: initial.revision, command: .createChannel(name: "Harbor", initialRecipe: [:])), credential: credential).outcome,
              case let .applied(episodes) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: channel.revision, command: .createEpisode(name: "Recap", recipeVersion: 1)), credential: credential).outcome,
              let episode = episodes.episodes.first else { throw AuthorityFailure.corruptDatabase }
        let source = root.appendingPathComponent("\(name).png")
        try png().write(to: source)
        guard case let .imported(asset) = try authority.importManagedSources([source], credential: credential).first else { throw AuthorityFailure.corruptDatabase }
        let imported = try authority.open().document
        let composition = try makeComposition(episodeID: episode.id, asset: asset)
        guard case let .applied(composed) = try authority.executeForAuthenticatedCreator(CommandEnvelope(expectedRevision: imported.revision, command: .replaceEpisodeComposition(episodeID: episode.id, composition: composition)), credential: credential).outcome else { throw AuthorityFailure.corruptDatabase }
        let digest = SHA256.hash(data: try composition.canonicalData()).map { String(format: "%02x", $0) }.joined()
        let request = CommandEnvelope(expectedRevision: composed.revision, command: .requestEpisodeRender(episodeID: episode.id, compositionDigest: digest, format: .mp4))
        guard case let .renderRequested(status) = try authority.requestEpisodeRenderForAuthenticatedCreator(request, credential: credential).outcome else { throw AuthorityFailure.corruptDatabase }
        return (authority, package, credential, status, try authority.renderAttemptInputForAuthenticatedCreator(jobID: status.jobID, credential: credential))
    }

    private func makeComposition(episodeID: UUID, asset: ManagedAsset, second: ManagedAsset? = nil, secondLayer: Int = 1) throws -> EpisodeComposition {
        let output = CompositionOutput(width: 1920, height: 1080, frameRate: try time(30), duration: try time(12))
        let first = CompositionOccurrence(assetID: asset.id, assetDigest: asset.digest, source: .still, outputRange: try range(0, 12), layer: 0, order: 0, crop: try crop(), outputRect: try outputRect(0, 1, 0, 1, width: 1, 2, height: 1, 1))
        var occurrences = [first]
        if let second {
            occurrences.append(CompositionOccurrence(assetID: second.id, assetDigest: second.digest, source: .still, outputRange: try range(6, 6), layer: secondLayer, order: 1, crop: try crop(), outputRect: try outputRect(1, 2, 0, 1, width: 1, 2, height: 1, 1)))
        }
        return EpisodeComposition(episodeID: episodeID, output: output, occurrences: occurrences, captions: [CompositionCaption(text: "Harbor recap", outputRange: try range(0, 3), layer: 2, order: 0)])
    }

    private func equivalentComposition(_ original: EpisodeComposition, asset: ManagedAsset) throws -> EpisodeComposition {
        let output = CompositionOutput(width: 1920, height: 1080, frameRate: try time(60, 2), duration: try time(24, 2))
        let occurrence = CompositionOccurrence(id: original.occurrences[0].id, assetID: asset.id, assetDigest: asset.digest, source: .still, outputRange: try range(0, 24, scale: 2), layer: 0, order: 0, crop: try crop(), outputRect: original.occurrences[0].outputRect)
        return EpisodeComposition(episodeID: original.episodeID, output: output, occurrences: [occurrence], captions: [CompositionCaption(id: original.captions[0].id, text: "Harbor recap", outputRange: try range(0, 6, scale: 2), layer: 2, order: 0)])
    }

    private func time(_ value: Int64, _ timescale: Int32 = 1) throws -> CompositionTime {
        guard let result = CompositionTime(value: value, timescale: timescale) else { throw CompositionValidationFailure.invalidRange }
        return result
    }

    private func range(_ start: Int64, _ duration: Int64, scale: Int32 = 1) throws -> CompositionRange { CompositionRange(start: try time(start, scale), duration: try time(duration, scale)) }
    private func crop() throws -> CompositionCrop { CompositionCrop(x: try time(0), y: try time(0), width: try time(1), height: try time(1)) }
    private func outputRect(_ x: Int64, _ xScale: Int32, _ y: Int64, _ yScale: Int32, width: Int64, _ widthScale: Int32, height: Int64, _ heightScale: Int32) throws -> CompositionOutputRect { CompositionOutputRect(x: try time(x, xScale), y: try time(y, yScale), width: try time(width, widthScale), height: try time(height, heightScale)) }

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

    private func fakeRenderRuntime(workerScript: String? = nil, ffprobeScript: String? = nil) throws -> RenderWorkerRuntime {
        let runtime = root.appendingPathComponent("fake-runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let node = runtime.appendingPathComponent("node")
        let worker = runtime.appendingPathComponent("worker")
        let browser = runtime.appendingPathComponent("browser")
        let ffmpeg = runtime.appendingPathComponent("ffmpeg")
        let ffprobe = runtime.appendingPathComponent("ffprobe")
        try "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo v22.22.1; exit 0; fi\nworker=\"$1\"; shift; exec \"$worker\" \"$@\"\n".write(to: node, atomically: true, encoding: .utf8)
        let defaultWorker = "#!/bin/sh\nstage=\"$TAKEFORM_RENDER_STAGE\"\njob=\"$TAKEFORM_RENDER_JOB\"\nattempt=\"$TAKEFORM_RENDER_ATTEMPT\"\nhash=\"$TAKEFORM_RENDER_SNAPSHOT_SHA256\"\nprintf render > \"$stage/render.mp4\"\nsha=$(/usr/bin/shasum -a 256 \"$stage/render.mp4\" | /usr/bin/awk '{print $1}')\nprintf '{\\\"schemaVersion\\\":1,\\\"jobID\\\":\\\"%s\\\",\\\"attemptID\\\":\\\"%s\\\",\\\"outcome\\\":\\\"succeeded\\\",\\\"input\\\":{\\\"compositionDigest\\\":\\\"ignored\\\",\\\"snapshotSHA256\\\":\\\"%s\\\",\\\"assets\\\":[]},\\\"artifact\\\":{\\\"fileName\\\":\\\"render.mp4\\\",\\\"byteLength\\\":6,\\\"sha256\\\":\\\"%s\\\"}}' \"$job\" \"$attempt\" \"$hash\" \"$sha\" > \"$stage/attempt-receipt.json\"\n"
        try (workerScript ?? defaultWorker).write(to: worker, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho FakeTool 1.0\n".write(to: browser, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho FakeTool 1.0\n".write(to: ffmpeg, atomically: true, encoding: .utf8)
        let defaultProbe = "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo FakeTool 1.0; else printf '{\\\"streams\\\":[{\\\"codec_type\\\":\\\"video\\\",\\\"width\\\":1920,\\\"height\\\":1080,\\\"avg_frame_rate\\\":\\\"30/1\\\",\\\"nb_frames\\\":\\\"360\\\"}],\\\"format\\\":{\\\"duration\\\":\\\"12.0\\\"}}\\n'; fi\n"
        try (ffprobeScript ?? defaultProbe).write(to: ffprobe, atomically: true, encoding: .utf8)
        for url in [node, worker, browser, ffmpeg, ffprobe] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        return RenderWorkerRuntime(node: node, worker: worker, runtimeRoot: runtime, browser: browser, ffmpeg: ffmpeg, ffprobe: ffprobe)
    }
}
