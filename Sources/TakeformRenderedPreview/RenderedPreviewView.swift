import AVFoundation
import AppKit
import SwiftUI

/// The SwiftUI surface owns selection and status. This bridge owns only its
/// AVPlayerLayer lifecycle.
public struct RenderedPreviewView: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) { self.player = player }

    public func makeNSView(context: Context) -> RenderedPreviewLayerView {
        RenderedPreviewLayerView(player: player)
    }

    public func updateNSView(_ view: RenderedPreviewLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

public final class RenderedPreviewLayerView: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
