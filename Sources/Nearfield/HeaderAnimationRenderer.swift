import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The header animation drawn on the GPU: one full-frame fragment shader
/// (`nf_header_fragment` in WaveLabEffects.metal) per frame. Each frame the CPU
/// only advances the wave phase and encodes one draw call; the frames are paced
/// by the display and stop whenever the view can't be seen.
struct GPUHeaderAnimation: NSViewRepresentable {
    var configuration: NearfieldHeaderAnimationConfiguration
    var paused: Bool

    func makeNSView(context: Context) -> HeaderAnimationView {
        HeaderAnimationView()
    }

    func updateNSView(_ view: HeaderAnimationView, context: Context) {
        view.update(configuration: configuration, paused: paused)
    }
}

/// The compiled shader and what it needs to draw, shared by every header.
@MainActor
final class HeaderAnimationRenderer {
    /// Nil without the compiled shader library (a plain `swift build`); the
    /// SwiftUI renderer is used then.
    static let shared: HeaderAnimationRenderer? = HeaderAnimationRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard MetalEffectLibrary.isAvailable,
              let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFunction = library.makeFunction(name: "nf_header_vertex"),
              let fragmentFunction = library.makeFunction(name: "nf_header_fragment"),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func draw(_ uniforms: HeaderAnimationUniforms, to drawable: CAMetalDrawable) {
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        encode(uniforms, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func encode(_ uniforms: HeaderAnimationUniforms, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<HeaderAnimationUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

/// Matches `NFHeaderUniforms` in WaveLabEffects.metal, field for field.
struct HeaderAnimationUniforms {
    struct Wave {
        var color = SIMD4<Float>()
        var shape = SIMD4<Float>()
        var placement = SIMD4<Float>()
    }

    var view = SIMD4<Float>()
    var base = SIMD4<Float>()
    var modes = SIMD4<Float>()
    var blur = SIMD4<Float>()
    var primaryWave = Wave()
    var secondaryWave = Wave()
    var noise = SIMD4<Float>()
    var grain = SIMD4<Float>()
    var effectA = SIMD4<Float>()
    var effectB = SIMD4<Float>()

    /// Everything that only changes with the configuration. The phase, grain
    /// seed, effect time and size are filled in per frame.
    init(configuration: NearfieldHeaderAnimationConfiguration) {
        base = SIMD4(Self.rgb(configuration.baseColor), 1)
        modes = SIMD4(
            Self.code(configuration.waveBlendMode),
            Self.code(configuration.noise.blendMode),
            Self.code(configuration.effect),
            configuration.blurStrongOnLeft ? 1 : 0
        )
        blur = SIMD4(Float(configuration.maximumProgressiveBlurRadius), Float(configuration.progressiveBlurExponent), 0, 0)
        primaryWave = Self.wave(configuration.primaryWave)
        secondaryWave = Self.wave(configuration.secondaryWave)
        let noise = configuration.noise
        self.noise = SIMD4(Float(noise.opacity), Float(noise.density), Float(noise.minimumDotSize), Float(noise.maximumDotSize))
        grain = SIMD4(0, noise.monochrome ? 1 : 0, noise.monochromeIsWhite ? 1 : 0, 0)
        let effect = configuration.effectSettings
        effectA = SIMD4(
            Float(effect.greyscaleAmount),
            Float(effect.pixelBlockSize),
            Float(effect.ditherContrast),
            Float(effect.ditherCellSize)
        )
        effectB = SIMD4(
            Float(effect.ditherLevels),
            Float(effect.glitchAmount),
            Float(effect.glitchSliceCount),
            Float(effect.glitchSliceDisplacement)
        )
    }

    init() {}

    /// Sets the wave positions for `phase` (as `CoreHeaderAnimation` integrates it).
    mutating func setPhase(_ phase: Double, configuration: NearfieldHeaderAnimationConfiguration) {
        primaryWave.placement.y = Self.phaseShift(phase, wave: configuration.primaryWave)
        secondaryWave.placement.y = Self.phaseShift(phase, wave: configuration.secondaryWave)
    }

    private static func phaseShift(_ phase: Double, wave: HeaderSineWaveConfiguration) -> Float {
        // Wrapped so the shader's single-precision angle stays exact however
        // long the animation runs.
        Float((phase * wave.speedMultiplier + wave.phaseOffset).truncatingRemainder(dividingBy: 2 * .pi))
    }

    private static func wave(_ wave: HeaderSineWaveConfiguration) -> Wave {
        let color = rgba(wave.color)
        return Wave(
            color: SIMD4(color.x, color.y, color.z, color.w * Float(wave.opacity)),
            shape: SIMD4(Float(wave.lineWidth), Float(wave.frequency), Float(wave.amplitude), Float(wave.amplitudeFalloff)),
            placement: SIMD4(Float(wave.verticalPosition), 0, Float(wave.horizontalOverscan), Float(wave.blurRadius))
        )
    }

    private static func rgb(_ color: Color) -> SIMD3<Float> {
        let value = rgba(color)
        return SIMD3(value.x, value.y, value.z)
    }

    private static func rgba(_ color: Color) -> SIMD4<Float> {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return SIMD4(
            Float(resolved.redComponent),
            Float(resolved.greenComponent),
            Float(resolved.blueComponent),
            Float(resolved.alphaComponent)
        )
    }

    private static func code(_ mode: BlendMode) -> Float {
        switch mode {
        case .softLight: return 1
        case .screen: return 2
        case .overlay: return 3
        case .hardLight: return 4
        case .colorDodge: return 5
        case .plusLighter: return 6
        default: return 0
        }
    }

    private static func code(_ effect: WaveLabEffect) -> Float {
        switch effect {
        case .none: return 0
        case .greyscale: return 1
        case .pixelated: return 2
        case .dither: return 3
        case .glitch: return 4
        }
    }
}

/// Shows the header animation in a Metal layer. Animates only while it is
/// unpaused and its window is on screen and not covered; otherwise it draws
/// nothing at all.
final class HeaderAnimationView: NSView {
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?
    private var windowObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?

    private var configuration = NearfieldHeaderAnimationConfiguration.onboarding
    private var uniforms = HeaderAnimationUniforms()
    private var paused = true
    private var phase: Double = 0
    private var lastFrameTime: CFTimeInterval?
    private let startTime = CACurrentMediaTime()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer.device = HeaderAnimationRenderer.shared?.device
        metalLayer.pixelFormat = HeaderAnimationRenderer.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        return metalLayer
    }

    func update(configuration: NearfieldHeaderAnimationConfiguration, paused: Bool) {
        self.configuration = configuration
        uniforms = HeaderAnimationUniforms(configuration: configuration)
        self.paused = paused
        updateAnimation()
        drawIfIdle()
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopObservingWindow()
        // The display link follows the view's screen; a new one is made for
        // the new window.
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        updateScale()
        updateAnimation()
        drawIfIdle()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
        drawIfIdle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        drawIfIdle()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        updateAnimation()
        drawIfIdle()
    }

    private var canBeSeen: Bool {
        guard let window,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0,
              bounds.height > 0 else {
            return false
        }
        return true
    }

    private func observeWindow() {
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.willCloseNotification
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityMayHaveChanged() }
            }
        }
        // Displays coming and going move windows without always reporting an
        // occlusion change.
        screenObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityMayHaveChanged() }
        }
    }

    private func stopObservingWindow() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
        if let screenObserver {
            center.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    private func visibilityMayHaveChanged() {
        updateScale()
        updateAnimation()
        drawIfIdle()
    }

    // MARK: Drawing

    private var isAnimating: Bool {
        displayLink.map { !$0.isPaused } ?? false
    }

    private func updateAnimation() {
        guard !paused, canBeSeen else {
            displayLink?.isPaused = true
            lastFrameTime = nil
            return
        }
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            // The waves move slowly; 120 Hz would only double the work.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if let lastFrameTime {
            // As CoreHeaderAnimation: the speed sets the rate from here on, and
            // a stall never jumps the waves ahead.
            phase += min(max(now - lastFrameTime, 0), 0.1) * configuration.animationSpeed * 2 * .pi
        }
        lastFrameTime = now
        draw()
    }

    /// Redraws once after a change while not animating, if it can be seen.
    private func drawIfIdle() {
        guard !isAnimating, canBeSeen else { return }
        draw()
    }

    private func draw() {
        guard let renderer = HeaderAnimationRenderer.shared,
              bounds.width > 0,
              bounds.height > 0,
              metalLayer.drawableSize.width > 0,
              metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable() else {
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        var frame = uniforms
        frame.setPhase(phase, configuration: configuration)
        let noise = configuration.noise
        // The grain changes at its own frame rate, or not at all.
        frame.grain.x = noise.animated ? Float(Int(elapsed * Double(noise.framesPerSecond)) % 4096) : 0
        frame.view = SIMD4(
            Float(bounds.width),
            Float(bounds.height),
            Float(metalLayer.contentsScale),
            Float((elapsed * configuration.effectSettings.glitchSpeed).truncatingRemainder(dividingBy: 1000))
        )
        renderer.draw(frame, to: drawable)
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: (bounds.width * scale).rounded(.up), height: (bounds.height * scale).rounded(.up))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}
