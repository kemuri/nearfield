import SwiftUI

struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                OnboardingGraphicHeader(
                    height: headerHeight,
                    activePageIndex: model.step.rawValue,
                    showsGraphic: model.showHeaderGraphic,
                    transitionDuration: model.stepTransitionDuration,
                    showsPageIndicator: model.showsPageIndicator,
                    normalConfiguration: model.step == .settings ? .settings : .onboarding,
                    hoverActive: model.isInstallHovered && model.step == .welcome,
                    paused: model.headerPaused
                )

                if let subheadlineText {
                    HeaderSubheadline(text: subheadlineText, fontSize: subheadlineFontSize)
                        .padding(.top, 16)
                        .padding(.leading, 16)
                        .frame(width: OnboardingLayout.baseSize.width, alignment: .leading)
                        .hidden()
                }

                ZStack(alignment: .topLeading) {
                    switch model.step {
                    case .welcome:
                        WelcomeOnboardingView(model: model)
                            .transition(contentTransition)
                    case .install:
                        InstallOnboardingView(model: model)
                            .transition(contentTransition)
                    case .settings:
                        SettingsOnboardingView(model: model)
                            .transition(contentTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }

            HeaderCopyOverlay(
                copy: headerCopy,
                transitionDuration: model.stepTransitionDuration,
                introAnimationToken: model.introAnimationToken
            )
            .allowsHitTesting(false)
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .top)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
        .animation(.smooth(duration: model.stepTransitionDuration), value: model.step)
        .animation(.smooth(duration: 0.22), value: model.showHeaderGraphic)
        .preferredColorScheme(model.debugColorSchemeOverride)
        .scaleEffect(OnboardingLayout.scale, anchor: .topLeading)
        .frame(
            width: OnboardingLayout.windowSize.width,
            height: OnboardingLayout.windowSize.height,
            alignment: .topLeading
        )
    }

    private var headerTitle: String {
        switch model.step {
        case .welcome:
            "Nearfield"
        case .install:
            "Installing Drivers"
        case .settings:
            "Settings"
        }
    }

    private var headerHeight: CGFloat {
        switch model.step {
        case .welcome:
            OnboardingLayout.expandedHeaderHeight
        case .install, .settings:
            120
        }
    }

    private var headerTitleSize: CGFloat {
        switch model.step {
        case .welcome:
            35.235
        case .install, .settings:
            24
        }
    }

    private var headerTitleTop: CGFloat {
        let titleHeight: CGFloat = headerTitleSize < 30 ? 29 : 42
        return headerHeight - 16 - titleHeight
    }

    private var subheadlineText: String? {
        switch model.step {
        case .welcome:
            "Transform your studio displays into\nstereo audio monitors"
        case .install:
            "Nearfield works as a virtual HAL Driver,\nproviding the best native experience"
        case .settings:
            nil
        }
    }

    private var subheadlineFontSize: CGFloat {
        switch model.step {
        case .welcome:
            16
        case .install:
            12
        case .settings:
            12
        }
    }

    private var subheadlineTop: CGFloat {
        headerHeight + 16
    }

    private var headerCopy: HeaderCopyContent {
        HeaderCopyContent(
            title: headerTitle,
            titleSize: headerTitleSize,
            titleTop: headerTitleTop,
            subheadlineText: subheadlineText,
            subheadlineFontSize: subheadlineFontSize,
            subheadlineTop: subheadlineTop
        )
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }
}

private struct HeaderCopyContent: Equatable {
    var title: String
    var titleSize: CGFloat
    var titleTop: CGFloat
    var subheadlineText: String?
    var subheadlineFontSize: CGFloat
    var subheadlineTop: CGFloat

    var titleHeight: CGFloat {
        titleSize < 30 ? 29 : 42
    }

    func replacingMetrics(with other: HeaderCopyContent) -> HeaderCopyContent {
        HeaderCopyContent(
            title: title,
            titleSize: other.titleSize,
            titleTop: other.titleTop,
            subheadlineText: subheadlineText,
            subheadlineFontSize: other.subheadlineFontSize,
            subheadlineTop: other.subheadlineTop
        )
    }
}

private struct HeaderCopyOverlay: View {
    let copy: HeaderCopyContent
    let transitionDuration: Double
    let introAnimationToken: Int

    @State private var displayedCopy: HeaderCopyContent?
    @State private var outgoingCopy: HeaderCopyContent?
    @State private var incomingOpacity = 1.0
    @State private var outgoingOpacity = 0.0
    @State private var cleanupWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let outgoingCopy {
                HeaderCopyLayer(
                    copy: outgoingCopy,
                    introAnimationToken: introAnimationToken,
                    playsIntro: false
                )
                    .opacity(outgoingOpacity)
            }

            HeaderCopyLayer(
                copy: displayedCopy ?? copy,
                introAnimationToken: introAnimationToken,
                playsIntro: (displayedCopy ?? copy).title == "Nearfield"
            )
                .opacity(incomingOpacity)
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .topLeading)
        .onAppear {
            displayedCopy = copy
            incomingOpacity = 1
            outgoingOpacity = 0
        }
        .onChange(of: copy) { _, newCopy in
            animate(to: newCopy)
        }
        .onDisappear {
            cleanupWorkItem?.cancel()
        }
    }

    private func animate(to newCopy: HeaderCopyContent) {
        let previousCopy = displayedCopy ?? copy
        let duration = max(0.28, transitionDuration)
        cleanupWorkItem?.cancel()

        outgoingCopy = previousCopy
        displayedCopy = newCopy.replacingMetrics(with: previousCopy)
        incomingOpacity = previousCopy == newCopy ? 1 : 0
        outgoingOpacity = previousCopy == newCopy ? 0 : 1

        DispatchQueue.main.async {
            withAnimation(.smooth(duration: duration)) {
                outgoingCopy = previousCopy.replacingMetrics(with: newCopy)
                displayedCopy = newCopy
            }
            withAnimation(.easeInOut(duration: max(0.12, duration * 0.54)).delay(duration * 0.14)) {
                incomingOpacity = 1
                outgoingOpacity = 0
            }
        }

        let cleanup = DispatchWorkItem {
            outgoingCopy = nil
            displayedCopy = newCopy
            incomingOpacity = 1
            outgoingOpacity = 0
        }
        cleanupWorkItem = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.12, execute: cleanup)
    }
}

private struct HeaderCopyLayer: View {
    let copy: HeaderCopyContent
    let introAnimationToken: Int
    var playsIntro = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if copy.title == "Nearfield" {
                IntroReveal(token: introAnimationToken, delay: 0.08, yOffset: 8, isEnabled: playsIntro) {
                    NearfieldLogoMark()
                        .frame(width: 30.264, height: 27.711)
                }
                .offset(x: 18.868, y: 236.144)
            }

            if playsIntro && copy.title == "Nearfield" {
                AnimatedHeaderTitle(
                    text: copy.title,
                    fontSize: copy.titleSize,
                    height: copy.titleHeight,
                    token: introAnimationToken
                )
                .offset(x: 16, y: copy.titleTop)
            } else {
                Text(copy.title)
                    .font(.system(size: copy.titleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(height: copy.titleHeight, alignment: .leading)
                    .offset(x: 16, y: copy.titleTop)
            }

            if let subheadlineText = copy.subheadlineText {
                IntroReveal(token: introAnimationToken, delay: 0.36, yOffset: 8, isEnabled: playsIntro) {
                    HeaderSubheadline(text: subheadlineText, fontSize: copy.subheadlineFontSize)
                        .frame(width: OnboardingLayout.baseSize.width - 32, alignment: .leading)
                }
                .offset(x: 16, y: copy.subheadlineTop)
            }
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .topLeading)
    }
}

private struct AnimatedHeaderTitle: View {
    let text: String
    let fontSize: CGFloat
    let height: CGFloat
    let token: Int

    @State private var revealedLetterCount = 0

    private var characters: [String] {
        text.map(String.init)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                Text(character)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(index < revealedLetterCount ? 1 : 0)
                    .blur(radius: index < revealedLetterCount ? 0 : 7)
                    .offset(y: index < revealedLetterCount ? 0 : 50)
            }
        }
        .frame(height: height, alignment: .leading)
        .accessibilityLabel(text)
        .onAppear(perform: runAnimation)
        .onChange(of: token) { _, _ in
            runAnimation()
        }
    }

    private func runAnimation() {
        revealedLetterCount = 0
        for index in characters.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 + Double(index) * 0.046) {
                withAnimation(.smooth(duration: 0.3)) {
                    revealedLetterCount = max(revealedLetterCount, index + 1)
                }
            }
        }
    }
}

struct IntroReveal<Content: View>: View {
    let token: Int
    let delay: Double
    let duration: Double
    let yOffset: CGFloat
    let isEnabled: Bool
    let content: Content

    @State private var isVisible = false

    init(
        token: Int,
        delay: Double,
        duration: Double = 0.26,
        yOffset: CGFloat = 10,
        isEnabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.token = token
        self.delay = delay
        self.duration = duration
        self.yOffset = yOffset
        self.isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isEnabled ? (isVisible ? 1 : 0) : 1)
            .blur(radius: isEnabled ? (isVisible ? 0 : 7) : 0)
            .offset(y: isEnabled ? (isVisible ? 0 : yOffset) : 0)
            .onAppear(perform: runAnimation)
            .onChange(of: token) { _, _ in
                runAnimation()
            }
    }

    private func runAnimation() {
        guard isEnabled else {
            isVisible = true
            return
        }
        isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.smooth(duration: duration)) {
                isVisible = true
            }
        }
    }
}

private struct HeaderSubheadline: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.4))
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.smooth(duration: 0.26), value: fontSize)
    }
}


private struct OnboardingGraphicHeader: View {
    let height: CGFloat
    let activePageIndex: Int
    let showsGraphic: Bool
    let transitionDuration: Double
    let showsPageIndicator: Bool
    let normalConfiguration: NearfieldHeaderAnimationConfiguration
    var hoverActive: Bool = false
    var paused: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsGraphic {
                // Keep the wave render surface fixed; step changes mask it by
                // shrinking the outer header frame below.
                InterpolatedHeaderAnimation(
                    progress: hoverActive ? 1 : 0,
                    normal: normalConfiguration,
                    hover: .onboardingHover,
                    paused: paused
                )
                .frame(
                    width: OnboardingLayout.ditherImageWidth,
                    height: OnboardingLayout.expandedHeaderHeight
                )
                .clipped()
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: hoverActive)
            }
        }
        .frame(width: OnboardingLayout.baseSize.width, height: height)
        .overlay(alignment: .topTrailing) {
            if showsPageIndicator {
                PageIndicator(activeIndex: activePageIndex, transitionDuration: transitionDuration)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
            }
        }
        .clipped()
    }
}

private struct PageIndicator: View {
    let activeIndex: Int
    let transitionDuration: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(index == activeIndex ? 1 : 0.5))
                    .frame(width: index == activeIndex ? 12 : 4, height: 4)
                    .animation(.smooth(duration: max(0.18, transitionDuration * 0.65)), value: activeIndex)
            }
        }
    }
}
