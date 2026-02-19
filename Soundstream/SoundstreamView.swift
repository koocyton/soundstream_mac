import ScreenSaver
import Metal
import MetalKit
import os.log

private let log = Logger(subsystem: "com.henry.soundstream", category: "View")

final class SoundstreamView: ScreenSaverView {
    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var renderer: ParticleRenderer?
    private var audioCapture: AudioCapture?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        setupMetal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        if let device = MTLCreateSystemDefaultDevice() {
            metalLayer.device = device
            self.device = device
        }
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        self.metalLayer = metalLayer
        return metalLayer
    }

    private func setupMetal() {
        guard let device = self.device ?? MTLCreateSystemDefaultDevice() else {
            log.error("No Metal device available")
            return
        }
        self.device = device

        if let layer = metalLayer {
            layer.device = device
        }

        renderer = ParticleRenderer(device: device)
        if renderer == nil {
            log.error("Failed to create ParticleRenderer")
        }
    }

    override func startAnimation() {
        super.startAnimation()

        if audioCapture == nil {
            audioCapture = AudioCapture()
        }
        audioCapture?.start()
    }

    override func stopAnimation() {
        audioCapture?.stop()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        guard let metalLayer, let renderer else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let size = bounds.size
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        metalLayer.contentsScale = scale

        let audioState = audioCapture?.state ?? AudioState()
        renderer.updateAndRender(layer: metalLayer, audioState: audioState, backingScale: Float(scale))
    }

    override func draw(_ rect: NSRect) {
        if metalLayer == nil {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect)
        }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
