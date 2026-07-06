import AppKit
import SwiftUI

/// Linear interpolation helpers used to tween the header configuration between
/// the Wave Lab's normal and hover states. `t` is clamped 0...1 by callers.
enum WaveLabLerp {
    static func double(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    static func cgFloat(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    static func int(_ a: Int, _ b: Int, _ t: Double) -> Int {
        Int((Double(a) + (Double(b) - Double(a)) * t).rounded())
    }

    static func color(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let fallback = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let na = NSColor(a).usingColorSpace(.sRGB) ?? fallback
        let nb = NSColor(b).usingColorSpace(.sRGB) ?? fallback
        func mix(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x) + (Double(y) - Double(x)) * t }
        return Color(
            .sRGB,
            red: mix(na.redComponent, nb.redComponent),
            green: mix(na.greenComponent, nb.greenComponent),
            blue: mix(na.blueComponent, nb.blueComponent),
            opacity: mix(na.alphaComponent, nb.alphaComponent)
        )
    }
}

extension NearfieldHeaderAnimationConfiguration {
    /// Interpolates every continuous setting from `a` to `b`. Discrete settings
    /// that can't be blended (blend modes, the effect, booleans) switch at the
    /// midpoint.
    static func interpolated(
        from a: NearfieldHeaderAnimationConfiguration,
        to b: NearfieldHeaderAnimationConfiguration,
        t rawT: Double
    ) -> NearfieldHeaderAnimationConfiguration {
        let t = min(max(rawT, 0), 1)
        let pastMid = t >= 0.5
        return NearfieldHeaderAnimationConfiguration(
            baseColor: WaveLabLerp.color(a.baseColor, b.baseColor, t),
            animationSpeed: WaveLabLerp.double(a.animationSpeed, b.animationSpeed, t),
            loopResetInterval: WaveLabLerp.double(a.loopResetInterval, b.loopResetInterval, t),
            waveBlendMode: pastMid ? b.waveBlendMode : a.waveBlendMode,
            primaryWave: .interpolated(from: a.primaryWave, to: b.primaryWave, t: t),
            secondaryWave: .interpolated(from: a.secondaryWave, to: b.secondaryWave, t: t),
            progressiveBlurSegments: WaveLabLerp.int(a.progressiveBlurSegments, b.progressiveBlurSegments, t),
            maximumProgressiveBlurRadius: WaveLabLerp.cgFloat(a.maximumProgressiveBlurRadius, b.maximumProgressiveBlurRadius, t),
            progressiveBlurExponent: WaveLabLerp.double(a.progressiveBlurExponent, b.progressiveBlurExponent, t),
            blurStrongOnLeft: pastMid ? b.blurStrongOnLeft : a.blurStrongOnLeft,
            noise: .interpolated(from: a.noise, to: b.noise, t: t),
            effect: pastMid ? b.effect : a.effect,
            effectSettings: .interpolated(from: a.effectSettings, to: b.effectSettings, t: t)
        )
    }
}

extension HeaderSineWaveConfiguration {
    static func interpolated(
        from a: HeaderSineWaveConfiguration,
        to b: HeaderSineWaveConfiguration,
        t: Double
    ) -> HeaderSineWaveConfiguration {
        HeaderSineWaveConfiguration(
            color: WaveLabLerp.color(a.color, b.color, t),
            opacity: WaveLabLerp.double(a.opacity, b.opacity, t),
            lineWidth: WaveLabLerp.cgFloat(a.lineWidth, b.lineWidth, t),
            frequency: WaveLabLerp.double(a.frequency, b.frequency, t),
            amplitude: WaveLabLerp.cgFloat(a.amplitude, b.amplitude, t),
            amplitudeFalloff: WaveLabLerp.cgFloat(a.amplitudeFalloff, b.amplitudeFalloff, t),
            verticalPosition: WaveLabLerp.cgFloat(a.verticalPosition, b.verticalPosition, t),
            phaseOffset: WaveLabLerp.double(a.phaseOffset, b.phaseOffset, t),
            speedMultiplier: WaveLabLerp.double(a.speedMultiplier, b.speedMultiplier, t),
            horizontalOverscan: WaveLabLerp.cgFloat(a.horizontalOverscan, b.horizontalOverscan, t),
            blurRadius: WaveLabLerp.cgFloat(a.blurRadius, b.blurRadius, t)
        )
    }
}

extension HeaderNoiseConfiguration {
    static func interpolated(
        from a: HeaderNoiseConfiguration,
        to b: HeaderNoiseConfiguration,
        t: Double
    ) -> HeaderNoiseConfiguration {
        let pastMid = t >= 0.5
        return HeaderNoiseConfiguration(
            opacity: WaveLabLerp.double(a.opacity, b.opacity, t),
            density: WaveLabLerp.int(a.density, b.density, t),
            minimumDotSize: WaveLabLerp.cgFloat(a.minimumDotSize, b.minimumDotSize, t),
            maximumDotSize: WaveLabLerp.cgFloat(a.maximumDotSize, b.maximumDotSize, t),
            framesPerSecond: WaveLabLerp.int(a.framesPerSecond, b.framesPerSecond, t),
            animated: pastMid ? b.animated : a.animated,
            monochrome: pastMid ? b.monochrome : a.monochrome,
            monochromeIsWhite: pastMid ? b.monochromeIsWhite : a.monochromeIsWhite,
            blendMode: pastMid ? b.blendMode : a.blendMode
        )
    }
}

extension WaveLabEffectSettings {
    static func interpolated(
        from a: WaveLabEffectSettings,
        to b: WaveLabEffectSettings,
        t: Double
    ) -> WaveLabEffectSettings {
        WaveLabEffectSettings(
            greyscaleAmount: WaveLabLerp.double(a.greyscaleAmount, b.greyscaleAmount, t),
            pixelBlockSize: WaveLabLerp.cgFloat(a.pixelBlockSize, b.pixelBlockSize, t),
            ditherContrast: WaveLabLerp.double(a.ditherContrast, b.ditherContrast, t),
            ditherCellSize: WaveLabLerp.cgFloat(a.ditherCellSize, b.ditherCellSize, t),
            ditherLevels: WaveLabLerp.double(a.ditherLevels, b.ditherLevels, t),
            glitchAmount: WaveLabLerp.cgFloat(a.glitchAmount, b.glitchAmount, t),
            glitchSliceCount: WaveLabLerp.int(a.glitchSliceCount, b.glitchSliceCount, t),
            glitchSliceDisplacement: WaveLabLerp.cgFloat(a.glitchSliceDisplacement, b.glitchSliceDisplacement, t),
            glitchSpeed: WaveLabLerp.double(a.glitchSpeed, b.glitchSpeed, t)
        )
    }
}
