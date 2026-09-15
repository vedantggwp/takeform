import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cleared, test-only inputs made with Apple media frameworks. Nothing here is
/// a comparison-film fixture or a shipping asset.
final class SyntheticMediaFixtures {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "takeform-media-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { cleanup() }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func orientationStill(named name: String, contentIdentifier: String? = nil) throws -> URL {
        let url = root.appending(path: name)
        let image = try syntheticImage(width: 8, height: 4)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw FixtureError("ImageIO could not create synthetic HEIC")
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        if let contentIdentifier {
            properties[kCGImagePropertyMakerAppleDictionary] = ["17": contentIdentifier]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError("ImageIO could not finalize synthetic HEIC")
        }
        return url
    }

    func png(named name: String) throws -> URL {
        let url = root.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError("ImageIO could not create synthetic PNG")
        }
        CGImageDestinationAddImage(destination, try syntheticImage(width: 8, height: 4), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError("ImageIO could not finalize synthetic PNG")
        }
        return url
    }

    func corruptPNG(named name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data("not a PNG".utf8).write(to: url, options: .atomic)
        return url
    }

    func video(named name: String, rotated: Bool = false) async throws -> URL {
        let url = root.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 8,
            AVVideoHeightKey: 4,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false
            ]
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 8,
                kCVPixelBufferHeightKey as String: 4
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError("AVAssetWriter rejected synthetic video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError("AVAssetWriter could not start") }
        writer.startSession(atSourceTime: .zero)
        for time in [0, 20, 73, 160, 230, 400] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard adaptor.append(try pixelBuffer(), withPresentationTime: CMTime(value: CMTimeValue(time), timescale: 600)) else {
                throw writer.error ?? FixtureError("AVAssetWriter could not append synthetic frame")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? FixtureError("AVAssetWriter could not finish") }
        return url
    }

    func motion(named name: String, contentIdentifier: String?) async throws -> URL {
        let base = try await video(named: "base-\(UUID().uuidString).mov")
        guard let contentIdentifier else { return base }
        let output = root.appending(path: name)
        try FileManager.default.copyItem(at: base, to: output)
        let movie = AVMutableMovie(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = contentIdentifier as NSString
        movie.metadata = movie.metadata.filter { $0.identifier != .quickTimeMetadataContentIdentifier } + [item]
        try movie.writeHeader(to: output, fileType: .mov, options: .addMovieHeaderToDestination)
        return output
    }

    func monoAIFF(named name: String) throws -> URL {
        try audio(named: name, fileType: .aiff, formatID: kAudioFormatLinearPCM, sampleRate: 22_050, channels: 1)
    }

    func stereoM4A(named name: String) throws -> URL {
        try audio(named: name, fileType: .m4a, formatID: kAudioFormatMPEG4AAC, sampleRate: 48_000, channels: 2)
    }

    func paddedVideo(named name: String, minimumLogicalBytes: UInt64) async throws -> URL {
        let url = try await video(named: name)
        let initial = try fileSize(url)
        guard initial < minimumLogicalBytes else { return url }
        let padding = minimumLogicalBytes - initial
        guard padding >= 8, padding <= UInt64(UInt32.max) else { throw FixtureError("Synthetic free atom size is invalid") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var size = UInt32(padding).bigEndian
        try withUnsafeBytes(of: &size) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: Data("free".utf8))
        try handle.seek(toOffset: minimumLogicalBytes - 1)
        try handle.write(contentsOf: Data([0]))
        guard try fileSize(url) >= minimumLogicalBytes else { throw FixtureError("Synthetic padded video has wrong logical size") }
        return url
    }

    func fileSize(_ url: URL) throws -> UInt64 {
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw FixtureError("Could not read synthetic fixture logical size")
        }
        return size.uint64Value
    }

    private func audio(named name: String, fileType: AVFileType, formatID: AudioFormatID, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = root.appending(path: name)
        let settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800) else {
            throw FixtureError("Could not allocate synthetic audio buffer")
        }
        buffer.frameLength = 4_800
        if let samples = buffer.floatChannelData {
            for channel in 0..<Int(file.processingFormat.channelCount) {
                samples[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func syntheticImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw FixtureError("Could not create synthetic image context") }
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else { throw FixtureError("Could not create synthetic image") }
        return image
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw FixtureError("Could not allocate synthetic pixel buffer") }

        guard
            CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
            let baseAddress = CVPixelBufferGetBaseAddress(buffer)
        else {
            throw FixtureError("Could not lock synthetic pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteCount = bytesPerRow * CVPixelBufferGetHeight(buffer)
        baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let offset = y * bytesPerRow + x * 4
                let isLeft = x < CVPixelBufferGetWidth(buffer) / 2
                pixels[offset] = isLeft ? 204 : 26
                pixels[offset + 1] = isLeft ? 102 : 178
                pixels[offset + 2] = isLeft ? 25 : 51
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
