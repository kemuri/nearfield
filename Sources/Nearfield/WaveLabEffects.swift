import SwiftUI

/// Post-process render effects that sit on top of the header animation (waves +
/// noise + base color) without touching the overlaid logo and title. Pure
/// SwiftUI/Canvas — no Metal — because the project is built with `swift build`,
/// which does not compile `.metal` shader sources.
enum WaveLabEffect: String, CaseIterable, Hashable {
    case none
    case greyscale
    case pixelated
    case dither
    case glitch

    var label: String {
        switch self {
        case .none: return "None"
        case .greyscale: return "Greyscale"
        case .pixelated: return "Pixelated"
        case .dither: return "Dither"
        case .glitch: return "Glitch"
        }
    }
}

/// Tunable parameters for each render effect. Only the fields relevant to the
/// active effect are used.
struct WaveLabEffectSettings {
    var greyscaleAmount: Double
    var pixelBlockSize: CGFloat
    var ditherContrast: Double
    var ditherCellSize: CGFloat
    var ditherLevels: Double
    var glitchAmount: CGFloat
    var glitchSliceCount: Int
    var glitchSliceDisplacement: CGFloat
    var glitchSpeed: Double

    static let `default` = WaveLabEffectSettings(
        greyscaleAmount: 1,
        pixelBlockSize: 6,
        ditherContrast: 1.5,
        ditherCellSize: 3,
        ditherLevels: 3,
        glitchAmount: 5,
        glitchSliceCount: 5,
        glitchSliceDisplacement: 22,
        glitchSpeed: 1
    )
}

/// Whether the compiled Metal effect library shipped in the app bundle. When
/// present the pixelate/dither/glitch effects use GPU shaders; otherwise they
/// fall back to the pure-SwiftUI implementations.
enum MetalEffectLibrary {
    static let isAvailable: Bool = {
        Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
    }()
}

/// Wraps the animation content and applies the selected effect.
struct AnimationEffectsView<Content: View>: View {
    let effect: WaveLabEffect
    var settings: WaveLabEffectSettings = .default
    var paused = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch effect {
        case .none:
            content()
        case .greyscale:
            content().grayscale(settings.greyscaleAmount)
        case .pixelated:
            if MetalEffectLibrary.isAvailable {
                MetalPixelateEffect(blockSize: max(settings.pixelBlockSize, 1), content: content)
            } else {
                PixelatedEffect(blockSize: max(settings.pixelBlockSize, 1), content: content)
            }
        case .dither:
            if MetalEffectLibrary.isAvailable {
                MetalDitherEffect(
                    cellSize: max(settings.ditherCellSize, 1),
                    contrast: settings.ditherContrast,
                    levels: settings.ditherLevels,
                    content: content
                )
            } else {
                DitherEffect(
                    contrast: settings.ditherContrast,
                    cellSize: max(settings.ditherCellSize, 1),
                    content: content
                )
            }
        case .glitch:
            if MetalEffectLibrary.isAvailable {
                MetalGlitchEffect(settings: settings, paused: paused, content: content)
            } else {
                GlitchEffect(settings: settings, paused: paused, content: content)
            }
        }
    }
}

// MARK: - Metal-backed effects

private struct MetalPixelateEffect<Content: View>: View {
    let blockSize: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().layerEffect(
            ShaderLibrary.default.wl_pixelate(.float(Float(blockSize))),
            maxSampleOffset: CGSize(width: blockSize, height: blockSize)
        )
    }
}

private struct MetalDitherEffect<Content: View>: View {
    let cellSize: CGFloat
    let contrast: Double
    let levels: Double
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().colorEffect(
            ShaderLibrary.default.wl_dither(
                .float(Float(cellSize)),
                .float(Float(contrast)),
                .float(Float(levels))
            )
        )
    }
}

private struct MetalGlitchEffect<Content: View>: View {
    let settings: WaveLabEffectSettings
    var paused = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: paused)) { timeline in
                let time = Float(timeline.date.timeIntervalSinceReferenceDate * settings.glitchSpeed)
                content()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .layerEffect(
                        ShaderLibrary.default.wl_glitch(
                            .float2(proxy.size),
                            .float(time),
                            .float(Float(settings.glitchAmount)),
                            .float(Float(settings.glitchSliceCount)),
                            .float(Float(settings.glitchSliceDisplacement))
                        ),
                        maxSampleOffset: CGSize(
                            width: settings.glitchAmount + settings.glitchSliceDisplacement * 1.5 + 4,
                            height: 0
                        )
                    )
            }
        }
        .clipped()
    }
}

// MARK: - Pixelated

/// Lays the animation out at a fraction of its size so it rasterizes at low
/// resolution, then scales the result back up into chunky blocks.
private struct PixelatedEffect<Content: View>: View {
    let blockSize: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let lowWidth = max(proxy.size.width / blockSize, 1)
            let lowHeight = max(proxy.size.height / blockSize, 1)

            content()
                .frame(width: lowWidth, height: lowHeight)
                .drawingGroup()
                .scaleEffect(
                    x: proxy.size.width / lowWidth,
                    y: proxy.size.height / lowHeight,
                    anchor: .topLeading
                )
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

// MARK: - Dither

/// Grayscale + adjustable contrast, then an ordered Bayer threshold pattern
/// blended in `.overlay` to push midtones toward black/white in a retro
/// screen-door grid.
private struct DitherEffect<Content: View>: View {
    let contrast: Double
    let cellSize: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .grayscale(1.0)
            .contrast(contrast)
            .overlay {
                BayerDitherPattern(cellSize: cellSize)
                    .blendMode(.overlay)
            }
            .compositingGroup()
            .clipped()
    }
}

private struct BayerDitherPattern: View {
    let cellSize: CGFloat

    private static let matrix: [[CGFloat]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
    ]

    var body: some View {
        Canvas { context, size in
            let cell = max(cellSize, 1)
            guard size.width > 0, size.height > 0 else { return }
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1

            for row in 0..<rows {
                for column in 0..<columns {
                    let threshold = (Self.matrix[row % 4][column % 4] + 0.5) / 16.0
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(Color(white: threshold)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glitch

/// Resolves the animation as a single Canvas symbol (so every draw is the same
/// frame) and recomposes it with an RGB channel split plus a few horizontally
/// displaced scanline slices.
private struct GlitchEffect<Content: View>: View {
    let settings: WaveLabEffectSettings
    var paused = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: paused)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate * settings.glitchSpeed
                Canvas { context, size in
                    guard let symbol = context.resolveSymbol(id: 0) else { return }
                    draw(context: context, size: size, symbol: symbol, time: time)
                } symbols: {
                    content()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .tag(0)
                }
            }
        }
        .clipped()
    }

    private func draw(
        context: GraphicsContext,
        size: CGSize,
        symbol: GraphicsContext.ResolvedSymbol,
        time: TimeInterval
    ) {
        let full = CGRect(origin: .zero, size: size)
        let shift = settings.glitchAmount * CGFloat(0.5 + 0.5 * sin(time * 7))

        // Chromatic aberration: additively recombine offset R/G/B channels.
        func channel(_ tint: Color, dx: CGFloat) {
            var layer = context
            layer.blendMode = .plusLighter
            layer.addFilter(.colorMultiply(tint))
            layer.draw(symbol, in: full.offsetBy(dx: dx, dy: 0))
        }
        channel(.red, dx: -shift)
        channel(.green, dx: 0)
        channel(.blue, dx: shift)

        // Occasional displaced scanline slices.
        let sliceCount = max(settings.glitchSliceCount, 0)
        guard sliceCount > 0 else { return }
        for index in 0..<sliceCount {
            let wave = sin(time * 11 + Double(index) * 37.13)
            guard wave > 0.5 else { continue }

            let band = CGFloat((Double(index) + 0.5) / Double(sliceCount))
            let y = band * size.height
            let height = size.height * 0.05
            let dx = CGFloat(wave) * settings.glitchSliceDisplacement

            var layer = context
            layer.clip(to: Path(CGRect(x: 0, y: y, width: size.width, height: height)))
            layer.draw(symbol, in: full.offsetBy(dx: dx, dy: 0))
        }
    }
}
