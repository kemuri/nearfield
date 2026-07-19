#if !NEARFIELD_DISTRIBUTION
import AppKit
import SwiftUI

/// A developer/design tool window for live-tweaking the onboarding header
/// animation. Every parameter feeds the same `NearfieldHeaderAnimation` used in
/// onboarding, and the current values can be exported as Swift source (ready to
/// paste back into `NearfieldHeaderAnimationConfiguration.onboarding`) via the
/// clipboard.
@MainActor
final class WaveLabWindowController: NSWindowController, NSWindowDelegate {
    private let visibility = WaveLabWindowVisibility()

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 660)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wave Lab"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 720, height: 560)
        window.center()

        super.init(window: window)

        window.delegate = self

        let hostingView = NSHostingView(rootView: WaveLabRootView(visibility: visibility))
        hostingView.frame = contentRect
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        visibility.isPreviewPaused = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.updatePreviewPauseState()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updatePreviewPauseState()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updatePreviewPauseState()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updatePreviewPauseState()
    }

    func windowWillClose(_ notification: Notification) {
        visibility.isPreviewPaused = true
    }

    private func updatePreviewPauseState() {
        guard let window else {
            visibility.isPreviewPaused = true
            return
        }
        visibility.isPreviewPaused = !window.isVisible || !window.occlusionState.contains(.visible)
    }
}

private final class WaveLabWindowVisibility: ObservableObject {
    @Published var isPreviewPaused = true
}

private enum WaveLabLayout {
    static let previewBaseWidth: CGFloat = 307
    static let previewOverscanWidth: CGFloat = 343.5
    static let previewHeight: CGFloat = 345
}

struct WaveLabRootView: View {
    @ObservedObject private var visibility: WaveLabWindowVisibility
    @State private var normalConfig = NearfieldHeaderAnimationConfiguration.onboarding
    @State private var hoverConfig = NearfieldHeaderAnimationConfiguration.onboarding
    @State private var editingHover = false
    @State private var isHovering = false
    @State private var hoverEasing: HoverEasing = .easeInOut
    @State private var hoverDuration: Double = 0.35
    @State private var didCopy = false
    @State private var pasteStatus: WaveLabPasteStatus?
    @State private var audioReactiveEnabled = false
    @State private var audioInfluence = 0.65
    @StateObject private var outputAudioMonitor = OutputAudioLevelMonitor()

    fileprivate init(visibility: WaveLabWindowVisibility) {
        self.visibility = visibility
    }

    /// Binding to the config the control sliders currently edit.
    private var edited: Binding<NearfieldHeaderAnimationConfiguration> {
        editingHover ? $hoverConfig : $normalConfig
    }

    /// Read-only accessor for the edited config.
    private var config: NearfieldHeaderAnimationConfiguration { edited.wrappedValue }

    /// True when the preview should show the hover state — either the pointer is
    /// over the image, or the hover state is the one being edited.
    private var showingHover: Bool { isHovering || editingHover }

    private var previewAudioLevel: Double {
        guard audioReactiveEnabled, !visibility.isPreviewPaused else { return 0 }
        return outputAudioMonitor.level * audioInfluence
    }

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
            Divider()
            controlsColumn
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Color(white: 0.12))
        .onChange(of: audioReactiveEnabled) { _, _ in
            updateOutputAudioMonitor()
        }
        .onChange(of: visibility.isPreviewPaused) { _, _ in
            updateOutputAudioMonitor()
        }
        .onDisappear {
            outputAudioMonitor.setActive(false)
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack(alignment: .bottomLeading) {
                InterpolatedHeaderAnimation(
                    progress: showingHover ? 1 : 0,
                    normal: normalConfig,
                    hover: hoverConfig,
                    paused: visibility.isPreviewPaused,
                    audioLevel: previewAudioLevel
                )
                .frame(width: WaveLabLayout.previewOverscanWidth, height: WaveLabLayout.previewHeight)
                .frame(width: WaveLabLayout.previewBaseWidth, alignment: .leading)
                .clipped()
                .animation(hoverEasing.animation(duration: hoverDuration), value: isHovering)

                VStack(alignment: .leading, spacing: 16) {
                    NearfieldLogoMark()
                        .frame(width: 36, height: 42)
                    Text("Nearfield")
                        .font(.system(size: 35, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(16)
            }
            .frame(width: WaveLabLayout.previewBaseWidth, height: WaveLabLayout.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .onHover { hovering in
                isHovering = hovering
            }

            Text(showingHover ? "Live preview · Hover state" : "Live preview · Normal state")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    // MARK: Controls

    private var controlsColumn: some View {
        VStack(spacing: 0) {
            stateSelector
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    transitionSection
                    audioResponseSection
                    canvasSection
                    waveSection
                    progressiveBlurSection
                    noiseSection
                    effectSection
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    edited.wrappedValue = .onboarding
                } label: {
                    Label("Reset", systemImage: "arrow.uturn.backward")
                }

                Spacer(minLength: 8)

                if let pasteStatus {
                    Text(pasteStatus.message)
                        .font(.caption)
                        .foregroundStyle(pasteStatus.isError ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .transition(.opacity)
                }

                Button {
                    pasteConfiguration()
                } label: {
                    Label("Paste", systemImage: "clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("Paste a Wave Lab preset into the selected state")

                Button {
                    copyConfiguration()
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.clipboard"
                    )
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the selected state's Wave Lab preset")
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 340)
    }

    /// Lets the user choose which state the sliders edit. Sits above the scroll
    /// area so it's always visible.
    private var stateSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("State", selection: $editingHover) {
                Text("Normal").tag(false)
                Text("Hover").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .firstTextBaseline) {
                Text("Hover the preview image to switch to the hover state.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    hoverConfig = normalConfig
                } label: {
                    Label("Normal → Hover", systemImage: "arrow.right")
                }
                .controlSize(.small)
                .help("Copy every Normal parameter into the Hover state")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var transitionSection: some View {
        Section(title: "Hover transition") {
            Picker("Easing", selection: $hoverEasing) {
                ForEach(HoverEasing.allCases, id: \.self) { easing in
                    Text(easing.label).tag(easing)
                }
            }
            SliderRow(title: "Duration", value: $hoverDuration, range: 0.05...2, decimals: 2)
            Text("Every continuous setting tweens between the normal and hover states with this curve.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var audioResponseSection: some View {
        Section(title: "Audio response") {
            Toggle("Current output influences waves", isOn: $audioReactiveEnabled)
                .toggleStyle(.switch)

            SliderRow(title: "Influence", value: $audioInfluence, range: 0...1.5, decimals: 2)
                .disabled(!audioReactiveEnabled)

            AudioLevelMeter(level: outputAudioMonitor.level)
                .opacity(audioReactiveEnabled ? 1 : 0.4)

            Text(audioReactiveEnabled ? outputAudioMonitor.statusText : "Off")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if outputAudioMonitor.requiresScreenRecordingPermission {
                Button {
                    openScreenRecordingSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
    }

    private var canvasSection: some View {
        Section(title: "Canvas") {
            ColorPicker("Base color", selection: edited.baseColor, supportsOpacity: false)
            SliderRow(title: "Animation speed", value: edited.animationSpeed, range: 0...2, decimals: 3)
            BlendModePicker(title: "Wave blend mode", selection: edited.waveBlendMode)
        }
    }

    private var waveSection: some View {
        Section(title: "Waves") {
            ColorPicker("Wave color", selection: sharedWave(\.color))
            SliderRow(title: "Frequency", value: sharedWave(\.frequency), range: 0.2...5, decimals: 3)
            SliderRow(title: "Amplitude", value: sharedWave(\.amplitude), range: 0...0.7, decimals: 3)
            SliderRow(title: "Amplitude falloff", value: sharedWave(\.amplitudeFalloff), range: 0...1, decimals: 2)
            SliderRow(title: "Vertical position", value: sharedWave(\.verticalPosition), range: 0...1, decimals: 3)
            SliderRow(title: "Base blur", value: sharedWave(\.blurRadius), range: 0...20, decimals: 1)
            SliderRow(title: "Horizontal overscan", value: sharedWave(\.horizontalOverscan), range: 0...500, decimals: 0)
            Divider().padding(.vertical, 2)
            SliderRow(title: "Wave 1 line width", value: edited.primaryWave.lineWidth, range: 1...60, decimals: 1)
            SliderRow(title: "Wave 1 opacity", value: edited.primaryWave.opacity, range: 0...1)
            SliderRow(title: "Wave 1 phase", value: edited.primaryWave.phaseOffset, range: -6.283...6.283, decimals: 2)
            SliderRow(title: "Wave 2 line width", value: edited.secondaryWave.lineWidth, range: 1...60, decimals: 1)
            SliderRow(title: "Wave 2 opacity", value: edited.secondaryWave.opacity, range: 0...1)
            SliderRow(title: "Wave 2 phase", value: edited.secondaryWave.phaseOffset, range: -6.283...6.283, decimals: 2)
        }
    }

    private var progressiveBlurSection: some View {
        Section(title: "Progressive blur") {
            Toggle("Blurred on left → sharp on right", isOn: edited.blurStrongOnLeft)
                .toggleStyle(.switch)
            IntSliderRow(title: "Segments", value: edited.progressiveBlurSegments, range: 1...20)
            SliderRow(title: "Max blur radius", value: edited.maximumProgressiveBlurRadius, range: 0...60, decimals: 1)
            SliderRow(title: "Falloff exponent", value: edited.progressiveBlurExponent, range: 0.2...4, decimals: 2)
        }
    }

    private var noiseSection: some View {
        Section(title: "Noise") {
            Toggle("Animate noise", isOn: edited.noise.animated)
                .toggleStyle(.switch)
            Toggle("Monochrome", isOn: edited.noise.monochrome)
                .toggleStyle(.switch)
            Picker("Base color", selection: edited.noise.monochromeIsWhite) {
                Text("White").tag(true)
                Text("Black").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(!config.noise.monochrome)
            BlendModePicker(title: "Blend mode", selection: edited.noise.blendMode)
            SliderRow(title: "Opacity", value: edited.noise.opacity, range: 0...0.6)
            IntSliderRow(title: "Density", value: edited.noise.density, range: 0...12000)
            SliderRow(title: "Min dot size", value: edited.noise.minimumDotSize, range: 0.1...4, decimals: 2)
            SliderRow(title: "Max dot size", value: edited.noise.maximumDotSize, range: 0.1...6, decimals: 2)
            IntSliderRow(title: "Frames / sec", value: edited.noise.framesPerSecond, range: 1...30)
                .disabled(!config.noise.animated)
        }
    }

    private var effectSection: some View {
        Section(title: "Render effect") {
            Picker("Effect", selection: edited.effect) {
                ForEach(WaveLabEffect.allCases, id: \.self) { effect in
                    Text(effect.label).tag(effect)
                }
            }
            Text("Applied on top of the animation only — the logo and title stay crisp.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            switch config.effect {
            case .none:
                EmptyView()
            case .greyscale:
                SliderRow(title: "Amount", value: edited.effectSettings.greyscaleAmount, range: 0...1)
            case .pixelated:
                SliderRow(title: "Block size", value: edited.effectSettings.pixelBlockSize, range: 1...40, decimals: 1)
            case .dither:
                SliderRow(title: "Contrast", value: edited.effectSettings.ditherContrast, range: 1...4, decimals: 2)
                SliderRow(title: "Dot scale", value: edited.effectSettings.ditherCellSize, range: 1...12, decimals: 1)
                SliderRow(title: "Levels", value: edited.effectSettings.ditherLevels, range: 2...8, decimals: 0)
            case .glitch:
                SliderRow(title: "Amount", value: edited.effectSettings.glitchAmount, range: 0...30, decimals: 1)
                IntSliderRow(title: "Slices", value: edited.effectSettings.glitchSliceCount, range: 0...20)
                SliderRow(title: "Slice shift", value: edited.effectSettings.glitchSliceDisplacement, range: 0...80, decimals: 0)
                SliderRow(title: "Speed", value: edited.effectSettings.glitchSpeed, range: 0...4, decimals: 2)
            }
        }
    }

    // MARK: Shared-wave binding

    /// Returns a binding that reads from the primary wave but writes to *both*
    /// waves, so the two crossing strokes stay identical except for their phase.
    private func sharedWave<T>(_ keyPath: WritableKeyPath<HeaderSineWaveConfiguration, T>) -> Binding<T> {
        Binding(
            get: { config.primaryWave[keyPath: keyPath] },
            set: { newValue in
                edited.wrappedValue.primaryWave[keyPath: keyPath] = newValue
                edited.wrappedValue.secondaryWave[keyPath: keyPath] = newValue
            }
        )
    }

    private func updateOutputAudioMonitor() {
        outputAudioMonitor.setActive(audioReactiveEnabled && !visibility.isPreviewPaused)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Clipboard

    private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(WaveLabExporter.swiftSource(for: config), forType: .string)

        didCopy = true
        pasteStatus = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }

    private func pasteConfiguration() {
        guard let source = NSPasteboard.general.string(forType: .string),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showPasteStatus("Empty", isError: true)
            return
        }

        do {
            edited.wrappedValue = try WaveLabPresetImporter.configuration(from: source)
            didCopy = false
            showPasteStatus(editingHover ? "Pasted Hover" : "Pasted Normal", isError: false)
        } catch {
            showPasteStatus("Invalid Preset", isError: true)
        }
    }

    private func showPasteStatus(_ message: String, isError: Bool) {
        let status = WaveLabPasteStatus(message: message, isError: isError)
        pasteStatus = status

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if pasteStatus == status {
                pasteStatus = nil
            }
        }
    }
}

// MARK: - Control building blocks

private struct WaveLabPasteStatus: Equatable {
    var message: String
    var isError: Bool
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SliderRow<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    var decimals: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.\(decimals)f", Double(value)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct IntSliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(value)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }
}

private struct AudioLevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Output audio level")
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }
}

private struct BlendModePicker: View {
    let title: String
    @Binding var selection: BlendMode

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(WaveLabBlendMode.choices, id: \.mode) { choice in
                Text(choice.label).tag(choice.mode)
            }
        }
    }
}

// MARK: - Hover transition

enum HoverEasing: String, CaseIterable, Hashable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In Out"
        case .spring: return "Spring"
        }
    }

    func animation(duration: Double) -> Animation {
        switch self {
        case .linear: return .linear(duration: duration)
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .spring: return .spring(duration: duration)
        }
    }
}

// InterpolatedHeaderAnimation lives in OnboardingHeaderAnimation.swift so both
// the Wave Lab and the real onboarding share the same tweening view.

// MARK: - Blend mode catalog

enum WaveLabBlendMode {
    static let choices: [(label: String, mode: BlendMode)] = [
        ("Soft Light", .softLight),
        ("Screen", .screen),
        ("Overlay", .overlay),
        ("Hard Light", .hardLight),
        ("Color Dodge", .colorDodge),
        ("Plus Lighter", .plusLighter),
        ("Normal", .normal)
    ]

    static func name(for mode: BlendMode) -> String {
        switch mode {
        case .softLight: return ".softLight"
        case .screen: return ".screen"
        case .overlay: return ".overlay"
        case .hardLight: return ".hardLight"
        case .colorDodge: return ".colorDodge"
        case .plusLighter: return ".plusLighter"
        case .normal: return ".normal"
        default: return ".normal"
        }
    }
}

// MARK: - Swift source exporter

enum WaveLabExporter {
    static func swiftSource(for config: NearfieldHeaderAnimationConfiguration) -> String {
        """
        static let onboarding = NearfieldHeaderAnimationConfiguration(
            baseColor: \(colorLiteral(config.baseColor)),
            animationSpeed: \(num(config.animationSpeed, 3)),
            loopResetInterval: \(num(config.loopResetInterval, 0)),
            waveBlendMode: \(WaveLabBlendMode.name(for: config.waveBlendMode)),
            primaryWave: \(waveLiteral(config.primaryWave)),
            secondaryWave: \(waveLiteral(config.secondaryWave)),
            progressiveBlurSegments: \(config.progressiveBlurSegments),
            maximumProgressiveBlurRadius: \(num(config.maximumProgressiveBlurRadius, 2)),
            progressiveBlurExponent: \(num(config.progressiveBlurExponent, 2)),
            blurStrongOnLeft: \(config.blurStrongOnLeft),
            noise: HeaderNoiseConfiguration(
                opacity: \(num(config.noise.opacity, 3)),
                density: \(config.noise.density),
                minimumDotSize: \(num(config.noise.minimumDotSize, 2)),
                maximumDotSize: \(num(config.noise.maximumDotSize, 2)),
                framesPerSecond: \(config.noise.framesPerSecond),
                animated: \(config.noise.animated),
                monochrome: \(config.noise.monochrome),
                monochromeIsWhite: \(config.noise.monochromeIsWhite),
                blendMode: \(WaveLabBlendMode.name(for: config.noise.blendMode))
            ),
            effect: .\(config.effect.rawValue),
            effectSettings: WaveLabEffectSettings(
                greyscaleAmount: \(num(config.effectSettings.greyscaleAmount, 2)),
                pixelBlockSize: \(num(config.effectSettings.pixelBlockSize, 1)),
                ditherContrast: \(num(config.effectSettings.ditherContrast, 2)),
                ditherCellSize: \(num(config.effectSettings.ditherCellSize, 1)),
                ditherLevels: \(num(config.effectSettings.ditherLevels, 0)),
                glitchAmount: \(num(config.effectSettings.glitchAmount, 1)),
                glitchSliceCount: \(config.effectSettings.glitchSliceCount),
                glitchSliceDisplacement: \(num(config.effectSettings.glitchSliceDisplacement, 1)),
                glitchSpeed: \(num(config.effectSettings.glitchSpeed, 2))
            )
        )
        """
    }

    private static func waveLiteral(_ wave: HeaderSineWaveConfiguration) -> String {
        """
        HeaderSineWaveConfiguration(
                color: \(colorLiteral(wave.color)),
                opacity: \(num(wave.opacity, 3)),
                lineWidth: \(num(wave.lineWidth, 3)),
                frequency: \(num(wave.frequency, 3)),
                amplitude: \(num(wave.amplitude, 3)),
                amplitudeFalloff: \(num(wave.amplitudeFalloff, 3)),
                verticalPosition: \(num(wave.verticalPosition, 3)),
                phaseOffset: \(num(wave.phaseOffset, 2)),
                speedMultiplier: \(num(wave.speedMultiplier, 2)),
                horizontalOverscan: \(num(wave.horizontalOverscan, 1)),
                blurRadius: \(num(wave.blurRadius, 2))
            )
        """
    }

    private static func colorLiteral(_ color: Color) -> String {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let r = num(Double(resolved.redComponent), 4)
        let g = num(Double(resolved.greenComponent), 4)
        let b = num(Double(resolved.blueComponent), 4)
        return "Color(red: \(r), green: \(g), blue: \(b))"
    }

    private static func num(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private static func num(_ value: CGFloat, _ decimals: Int) -> String {
        num(Double(value), decimals)
    }
}

enum WaveLabPresetImporter {
    enum ImportError: LocalizedError {
        case missingConfiguration
        case missingField(String)
        case invalidField(String)

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                return "No NearfieldHeaderAnimationConfiguration literal was found."
            case .missingField(let label):
                return "Missing preset field: \(label)."
            case .invalidField(let label):
                return "Invalid preset field: \(label)."
            }
        }
    }

    static func configuration(from source: String) throws -> NearfieldHeaderAnimationConfiguration {
        let args = try arguments(forCall: "NearfieldHeaderAnimationConfiguration", in: source)

        return NearfieldHeaderAnimationConfiguration(
            baseColor: try color(required("baseColor", in: args), label: "baseColor"),
            animationSpeed: try double(required("animationSpeed", in: args), label: "animationSpeed"),
            loopResetInterval: try double(required("loopResetInterval", in: args), label: "loopResetInterval"),
            waveBlendMode: try blendMode(required("waveBlendMode", in: args), label: "waveBlendMode"),
            primaryWave: try wave(required("primaryWave", in: args), label: "primaryWave"),
            secondaryWave: try wave(required("secondaryWave", in: args), label: "secondaryWave"),
            progressiveBlurSegments: try int(required("progressiveBlurSegments", in: args), label: "progressiveBlurSegments"),
            maximumProgressiveBlurRadius: try cgFloat(required("maximumProgressiveBlurRadius", in: args), label: "maximumProgressiveBlurRadius"),
            progressiveBlurExponent: try double(required("progressiveBlurExponent", in: args), label: "progressiveBlurExponent"),
            blurStrongOnLeft: try bool(required("blurStrongOnLeft", in: args), label: "blurStrongOnLeft"),
            noise: try noise(required("noise", in: args), label: "noise"),
            effect: try effect(required("effect", in: args), label: "effect"),
            effectSettings: try effectSettings(required("effectSettings", in: args), label: "effectSettings")
        )
    }

    private static func wave(_ source: String, label: String) throws -> HeaderSineWaveConfiguration {
        let args = try arguments(forCall: "HeaderSineWaveConfiguration", in: source)

        return HeaderSineWaveConfiguration(
            color: try color(required("color", in: args), label: "\(label).color"),
            opacity: try double(required("opacity", in: args), label: "\(label).opacity"),
            lineWidth: try cgFloat(required("lineWidth", in: args), label: "\(label).lineWidth"),
            frequency: try double(required("frequency", in: args), label: "\(label).frequency"),
            amplitude: try cgFloat(required("amplitude", in: args), label: "\(label).amplitude"),
            amplitudeFalloff: try cgFloat(required("amplitudeFalloff", in: args), label: "\(label).amplitudeFalloff"),
            verticalPosition: try cgFloat(required("verticalPosition", in: args), label: "\(label).verticalPosition"),
            phaseOffset: try double(required("phaseOffset", in: args), label: "\(label).phaseOffset"),
            speedMultiplier: try double(required("speedMultiplier", in: args), label: "\(label).speedMultiplier"),
            horizontalOverscan: try cgFloat(required("horizontalOverscan", in: args), label: "\(label).horizontalOverscan"),
            blurRadius: try cgFloat(required("blurRadius", in: args), label: "\(label).blurRadius")
        )
    }

    private static func noise(_ source: String, label: String) throws -> HeaderNoiseConfiguration {
        let args = try arguments(forCall: "HeaderNoiseConfiguration", in: source)

        return HeaderNoiseConfiguration(
            opacity: try double(required("opacity", in: args), label: "\(label).opacity"),
            density: try int(required("density", in: args), label: "\(label).density"),
            minimumDotSize: try cgFloat(required("minimumDotSize", in: args), label: "\(label).minimumDotSize"),
            maximumDotSize: try cgFloat(required("maximumDotSize", in: args), label: "\(label).maximumDotSize"),
            framesPerSecond: try int(required("framesPerSecond", in: args), label: "\(label).framesPerSecond"),
            animated: try bool(required("animated", in: args), label: "\(label).animated"),
            monochrome: try bool(required("monochrome", in: args), label: "\(label).monochrome"),
            monochromeIsWhite: try bool(required("monochromeIsWhite", in: args), label: "\(label).monochromeIsWhite"),
            blendMode: try blendMode(required("blendMode", in: args), label: "\(label).blendMode")
        )
    }

    private static func effectSettings(_ source: String, label: String) throws -> WaveLabEffectSettings {
        if enumCaseName(source) == "default" {
            return .default
        }

        let args = try arguments(forCall: "WaveLabEffectSettings", in: source)

        return WaveLabEffectSettings(
            greyscaleAmount: try double(required("greyscaleAmount", in: args), label: "\(label).greyscaleAmount"),
            pixelBlockSize: try cgFloat(required("pixelBlockSize", in: args), label: "\(label).pixelBlockSize"),
            ditherContrast: try double(required("ditherContrast", in: args), label: "\(label).ditherContrast"),
            ditherCellSize: try cgFloat(required("ditherCellSize", in: args), label: "\(label).ditherCellSize"),
            ditherLevels: try double(required("ditherLevels", in: args), label: "\(label).ditherLevels"),
            glitchAmount: try cgFloat(required("glitchAmount", in: args), label: "\(label).glitchAmount"),
            glitchSliceCount: try int(required("glitchSliceCount", in: args), label: "\(label).glitchSliceCount"),
            glitchSliceDisplacement: try cgFloat(required("glitchSliceDisplacement", in: args), label: "\(label).glitchSliceDisplacement"),
            glitchSpeed: try double(required("glitchSpeed", in: args), label: "\(label).glitchSpeed")
        )
    }

    private static func color(_ source: String, label: String) throws -> Color {
        switch enumCaseName(source) {
        case "white":
            return .white
        case "black":
            return .black
        default:
            break
        }

        let args = try arguments(forCall: "Color", in: source)
        return Color(
            red: try double(required("red", in: args), label: "\(label).red"),
            green: try double(required("green", in: args), label: "\(label).green"),
            blue: try double(required("blue", in: args), label: "\(label).blue"),
            opacity: try optionalDouble("opacity", in: args) ?? 1
        )
    }

    private static func blendMode(_ source: String, label: String) throws -> BlendMode {
        switch enumCaseName(source) {
        case "softLight":
            return .softLight
        case "screen":
            return .screen
        case "overlay":
            return .overlay
        case "hardLight":
            return .hardLight
        case "colorDodge":
            return .colorDodge
        case "plusLighter":
            return .plusLighter
        case "normal":
            return .normal
        default:
            throw ImportError.invalidField(label)
        }
    }

    private static func effect(_ source: String, label: String) throws -> WaveLabEffect {
        guard let effect = WaveLabEffect(rawValue: enumCaseName(source)) else {
            throw ImportError.invalidField(label)
        }
        return effect
    }

    private static func arguments(forCall name: String, in source: String) throws -> [String: String] {
        let body = try contents(ofCall: name, in: source)
        return try namedArguments(in: body)
    }

    private static func contents(ofCall name: String, in source: String) throws -> String {
        guard let nameRange = source.range(of: name),
              let openParen = source[nameRange.upperBound...].firstIndex(of: "(") else {
            throw name == "NearfieldHeaderAnimationConfiguration"
                ? ImportError.missingConfiguration
                : ImportError.invalidField(name)
        }

        var depth = 1
        var index = source.index(after: openParen)
        while index < source.endIndex {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openParen)..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        throw ImportError.invalidField(name)
    }

    private static func namedArguments(in source: String) throws -> [String: String] {
        var args: [String: String] = [:]
        for segment in splitTopLevel(source) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let colon = topLevelColon(in: trimmed) else {
                throw ImportError.invalidField(trimmed)
            }

            let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else {
                throw ImportError.invalidField(trimmed)
            }
            args[label] = value
        }
        return args
    }

    private static func splitTopLevel(_ source: String) -> [String] {
        var pieces: [String] = []
        var depth = 0
        var start = source.startIndex
        var index = source.startIndex

        while index < source.endIndex {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            case "," where depth == 0:
                pieces.append(String(source[start..<index]))
                start = source.index(after: index)
            default:
                break
            }
            index = source.index(after: index)
        }

        pieces.append(String(source[start..<source.endIndex]))
        return pieces
    }

    private static func topLevelColon(in source: String) -> String.Index? {
        var depth = 0
        var index = source.startIndex
        while index < source.endIndex {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth = max(depth - 1, 0)
            case ":" where depth == 0:
                return index
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func required(_ label: String, in args: [String: String]) throws -> String {
        guard let value = args[label] else {
            throw ImportError.missingField(label)
        }
        return value
    }

    private static func optionalDouble(_ label: String, in args: [String: String]) throws -> Double? {
        guard let value = args[label] else { return nil }
        return try double(value, label: label)
    }

    private static func double(_ source: String, label: String) throws -> Double {
        let cleaned = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
        guard let value = Double(cleaned) else {
            throw ImportError.invalidField(label)
        }
        return value
    }

    private static func cgFloat(_ source: String, label: String) throws -> CGFloat {
        CGFloat(try double(source, label: label))
    }

    private static func int(_ source: String, label: String) throws -> Int {
        let cleaned = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
        if let value = Int(cleaned) {
            return value
        }
        guard let doubleValue = Double(cleaned), doubleValue.rounded() == doubleValue else {
            throw ImportError.invalidField(label)
        }
        return Int(doubleValue)
    }

    private static func bool(_ source: String, label: String) throws -> Bool {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true":
            return true
        case "false":
            return false
        default:
            throw ImportError.invalidField(label)
        }
    }

    private static func enumCaseName(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.split(separator: ".").last ?? Substring(trimmed))
    }
}
#endif
