import AVFoundation
import AppKit
import SwiftUI

struct RenderedPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> RenderedPlayerLayerView { RenderedPlayerLayerView(player: player) }
    func updateNSView(_ view: RenderedPlayerLayerView, context: Context) { view.playerLayer.player = player }
}

final class RenderedPlayerLayerView: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
