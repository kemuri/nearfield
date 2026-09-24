import AppKit
import SwiftUI

struct SettingsOnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var showsTopFade = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { scrollProxy in
                    ScrollView {
                        ScrollOffsetObserver { offset in
                            updateTopFadeVisibility(offset)
                        }
                        .frame(width: 0, height: 0)

                        Color.clear
                            .frame(height: 0)
                            .id("settingsTop")

                        VStack(alignment: .leading, spacing: 8) {
                            StudioDisplayStatusPill(
                                status: StudioDisplayConnectionStatus(
                                    connectedCount: model.studioDisplayCount,
                                    coreAudioAvailability: model.coreAudioAvailability
                                )
                            )
                            .frame(width: OnboardingLayout.contentWidth)

                            SettingsGroup {
                                ToggleSettingRow(
                                    title: "Open at login",
                                    isOn: Binding(
                                        get: { model.openAtLogin },
                                        set: { model.setOpenAtLogin($0) }
                                    )
                                )
                                SettingsDivider()
                                ToggleSettingRow(
                                    title: "Show Menubar App",
                                    detail: "Open Nearfield to show this screen again.",
                                    isOn: Binding(
                                        get: { model.showMenubarApp },
                                        set: { model.setShowMenubarApp($0) }
                                    ),
                                    height: 64
                                )
                            }

                            SettingsSection(title: "Sound") {
                                SettingsGroup {
                                    BalanceSettingRow(model: model)
                                    SettingsDivider()
                                    DisplayArrangementRow(model: model)
                                }
                            }

                            SpatialRoutingGroup(model: model)

                            SettingsSection(title: "Driver") {
                                SettingsGroup {
                                    DriverStatusRow(model: model)
                                    SettingsDivider()
                                    ActionSettingRow(
                                        title: "Uninstall Nearfield",
                                        buttonTitle: "Uninstall",
                                        destructive: true,
                                        // Installing and uninstalling never overlap.
                                        enabled: !model.isInstallingDriver && !model.isRemovingDriver
                                    ) {
                                        model.removeDrivers()
                                    }
                                }
                            }

                            Text(model.appVersionText)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .frame(width: OnboardingLayout.contentWidth)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    }
                    .coordinateSpace(name: "settingsScroll")
                    .onAppear {
                        scrollProxy.scrollTo("settingsTop", anchor: .top)
                    }
                    .onChange(of: model.settingsScrollResetToken) { _, _ in
                        scrollProxy.scrollTo("settingsTop", anchor: .top)
                    }
            }

            ProgressiveTopFade(isVisible: showsTopFade)
                .allowsHitTesting(false)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private func updateTopFadeVisibility(_ offset: CGFloat) {
        if offset > 12, !showsTopFade {
            showsTopFade = true
        } else if offset <= 1, showsTopFade {
            showsTopFade = false
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                    .padding(.leading, 8)
                    .padding(.top, 8)
            } else {
                Color.clear.frame(height: 4)
            }
            content
        }
        .frame(width: OnboardingLayout.contentWidth, alignment: .leading)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(width: OnboardingLayout.contentWidth)
        .background(Theme.groupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NativeSettingsSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    var isEnabled = true

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
        control.target = context.coordinator
        control.action = #selector(Coordinator.valueChanged(_:))
        return control
    }

    func updateNSView(_ nsView: NSSwitch, context: Context) {
        let nextState: NSControl.StateValue = isOn ? .on : .off
        if nsView.state != nextState {
            nsView.state = nextState
        }
        nsView.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    final class Coordinator: NSObject {
        private let isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc @MainActor func valueChanged(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}

private struct CompactSettingsSwitch: View {
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        NativeSettingsSwitch(isOn: $isOn, isEnabled: isEnabled)
            .frame(width: 50, height: 30)
            .scaleEffect(0.72, anchor: .center)
            .frame(width: 36, height: 22)
    }
}

private struct ToggleSettingRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var height: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                CompactSettingsSwitch(isOn: $isOn)
            }

            if let detail {
                Text(detail)
                    .settingsDetailStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detail == nil ? 9 : 10)
        .frame(minHeight: height, alignment: .center)
    }
}

private struct ActionSettingRow: View {
    let title: String
    var detail: String?
    let buttonTitle: String
    var destructive = false
    var enabled = true
    var height: CGFloat = 42
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
                    .foregroundStyle(destructive ? .red : .primary)
                    .disabled(!enabled)
            }

            if let detail {
                Text(detail)
                    .settingsDetailStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detail == nil ? 8 : 10)
        .frame(minHeight: detail == nil ? height : max(height, 58), alignment: .center)
    }
}

private struct BalanceSettingRow: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Balance")
                    .settingsTitleStyle()
                Spacer()
                Text(model.balanceText())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "l.circle.fill")
                    .balanceSideIconStyle()

                NativeBalanceSlider(
                    value: Binding(
                        get: { model.balance },
                        set: { model.setBalance($0) }
                    )
                )
                .frame(height: 30)

                Image(systemName: "r.circle.fill")
                    .balanceSideIconStyle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 66)
    }
}

private struct DisplayArrangementRow: View {
    @ObservedObject var model: OnboardingModel
    @State private var dropTargetUID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Arrangement")
                    .settingsTitleStyle()

                Spacer(minLength: 8)

                Button("Identify") {
                    model.identifyDisplays()
                }
                .controlSize(.small)
                .disabled(!model.canArrangeDisplays)
                .help("Play a chime through each display in channel order")
            }

            Text("Drag displays to rearrange them.")
                .settingsDetailStyle()

            HStack(spacing: 8) {
                ForEach(model.arrangedDisplays, id: \.uid) { display in
                    let channelIndex = model.arrangedDisplays.firstIndex(of: display) ?? 0
                    let channelRole = model.channelRole(at: channelIndex)
                    let displayTitle = model.displayTitle(for: display)

                    VStack(spacing: 7) {
                        Button {
                            model.visuallyIdentifyDisplay(display.uid)
                        } label: {
                            DisplayArrangementTile(
                                title: displayTitle,
                                iconName: display.visualKind.symbolName,
                                isIdentified: model.identifiedDisplayUID == display.uid,
                                isDropTarget: dropTargetUID == display.uid
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canArrangeDisplays)
                        .draggable(display.uid) {
                            DisplayArrangementDragPreview(
                                title: displayTitle,
                                iconName: display.visualKind.symbolName
                            )
                        }
                        .dropDestination(for: String.self) { displayUIDs, _ in
                            guard let displayUID = displayUIDs.first,
                                  displayUID != display.uid else {
                                return false
                            }
                            model.moveDisplay(displayUID, onto: display.uid)
                            return true
                        } isTargeted: { isTargeted in
                            withAnimation(.smooth(duration: 0.16)) {
                                if isTargeted {
                                    dropTargetUID = display.uid
                                } else if dropTargetUID == display.uid {
                                    dropTargetUID = nil
                                }
                            }
                        }
                        .help(
                            "Click to highlight \(displayTitle). " +
                                "Drag this display box to change its channel."
                        )
                        .accessibilityLabel(displayTitle)
                        .accessibilityHint("Highlights this physical monitor. Drag to change its channel.")
                        .accessibilityActions {
                            if channelIndex > 0 {
                                Button("Move Left") {
                                    model.moveDisplay(
                                        display.uid,
                                        onto: model.arrangedDisplays[channelIndex - 1].uid
                                    )
                                }
                            }
                            if channelIndex + 1 < model.arrangedDisplays.count {
                                Button("Move Right") {
                                    model.moveDisplay(
                                        display.uid,
                                        onto: model.arrangedDisplays[channelIndex + 1].uid
                                    )
                                }
                            }
                        }

                        Text(channelRole.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 17)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(channelRole.title) channel")
                }

                ForEach(Array(0..<max(0, 2 - model.arrangedDisplays.count)), id: \.self) { _ in
                    MissingDisplayArrangementCard()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 150, alignment: .center)
    }
}

private struct DisplayArrangementTile: View {
    let title: String
    let iconName: String
    let isIdentified: Bool
    let isDropTarget: Bool

    private var accentColor: Color {
        Color(nsColor: .controlAccentColor)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isDropTarget
                        ? accentColor.opacity(0.11)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.72)
                )

            VStack(spacing: 5) {
                ZStack {
                    Image(systemName: iconName)
                        .opacity(isIdentified ? 0 : 1)
                        .scaleEffect(isIdentified ? 0.25 : 1)
                        .blur(radius: isIdentified ? 4 : 0)

                    Image(systemName: "speaker.wave.2.fill")
                        .opacity(isIdentified ? 1 : 0)
                        .scaleEffect(isIdentified ? 1 : 0.25)
                        .blur(radius: isIdentified ? 0 : 4)
                }
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isIdentified ? accentColor : .secondary)

                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isIdentified || isDropTarget ? accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isIdentified || isDropTarget ? 1.5 : 0.5
                )
        }
        .scaleEffect(isIdentified ? 1.02 : (isDropTarget ? 0.98 : 1))
        .animation(.smooth(duration: 0.3), value: isIdentified)
        .animation(.smooth(duration: 0.16), value: isDropTarget)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DisplayArrangementDragPreview: View {
    let title: String
    let iconName: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct MissingDisplayArrangementCard: View {
    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .overlay {
                    Image(systemName: "display")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 52)

            Text("Not connected")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(height: 17)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .labelColor).opacity(0.015),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityLabel("Studio Display not connected")
    }
}

private struct SpatialRoutingGroup: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        SettingsSection {
            SettingsGroup {
                SpatialRoutingHeaderRow(
                    isOn: Binding(
                        get: { model.spatialRoutingEnabled },
                        set: { model.setSpatialRoutingEnabled($0) }
                    )
                )

                if model.spatialRoutingEnabled {
                    ForEach(model.spatialRoutingApps) { app in
                        SettingsDivider()
                        SpatialRoutingAppRow(
                            app: app,
                            isSelected: model.selectedSpatialRoutingAppID == app.id,
                            isOn: Binding(
                                get: { app.isEnabled },
                                set: { model.setSpatialRoutingApp(app.id, enabled: $0) }
                            ),
                            select: { model.selectSpatialRoutingApp(app.id) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    SettingsDivider()
                    SpatialRoutingFooterRow(
                        canRemove: !model.spatialRoutingApps.isEmpty,
                        add: model.addSpatialRoutingApps,
                        remove: model.removeSelectedSpatialRoutingApp
                    )
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.26), value: model.spatialRoutingEnabled)
            .animation(.smooth(duration: 0.22), value: model.spatialRoutingApps.count)
        }
    }
}

private struct SpatialRoutingHeaderRow: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text("App Audio Routing")
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                CompactSettingsSwitch(isOn: $isOn)
            }

            Text("Route apps by window location.")
                .settingsDetailStyle()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 76, alignment: .center)
    }
}

private struct SpatialRoutingAppRow: View {
    let app: SpatialRoutingApp
    let isSelected: Bool
    @Binding var isOn: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 16) {
                    SpatialRoutingAppIcon(icon: app.icon, channel: app.activeChannel)

                    Text(app.title)
                        .settingsTitleStyle(color: isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 50)

            CompactSettingsSwitch(isOn: $isOn)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 50)
    }
}

private struct SpatialRoutingAppIcon: View {
    let icon: NSImage
    let channel: SpatialRoutingChannel?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)

            if let channel {
                SpatialRoutingChannelBadge(channel: channel)
                    .offset(x: 3, y: 3)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .frame(width: 32, height: 32)
        .animation(.smooth(duration: 0.18), value: channel)
    }
}

private struct SpatialRoutingChannelBadge: View {
    let channel: SpatialRoutingChannel

    var body: some View {
        Image(systemName: channel.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.palette)
            .frame(width: 12, height: 12)
            .foregroundStyle(
                Color(nsColor: .alternateSelectedControlTextColor),
                Color(nsColor: .controlAccentColor)
            )
            .background {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .overlay {
                        Circle()
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 1.2, x: 0, y: 0.6)
            }
            .accessibilityLabel(channel.accessibilityLabel)
    }
}

private struct SpatialRoutingFooterRow: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Add application")

            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1, height: 18)

            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove selected application")

            Spacer()
        }
        .padding(.leading, 8)
        .frame(height: 40)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Theme.groupBackground)
        }
    }
}

private struct NativeBalanceSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: -1, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        slider.sliderType = .linear
        slider.altIncrementValue = 0.05
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator: NSObject {
        private let value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc @MainActor func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

private struct DriverStatusRow: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isInstallingDriver {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: model.driverStatusSymbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(model.driverStatusColor)
                    .frame(width: 16, height: 16)
            }

            Text(model.driverStatusTitle)
                .settingsTitleStyle()

            Spacer()

            Button(model.driverActionTitle) {
                model.installDriver()
            }
            .controlSize(.small)
            .disabled(model.isInstallingDriver || model.isRemovingDriver)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }
}

private struct StudioDisplayStatusPill: View {
    let status: StudioDisplayConnectionStatus

    private var statusColor: Color {
        switch status.state {
        case .connected:
            return .green
        case .coreAudioUnavailable:
            return .red
        case .checking, .notConnected:
            return .yellow
        }
    }

    private var statusSymbolName: String {
        switch status.state {
        case .connected:
            return "checkmark.circle.fill"
        case .checking:
            return "clock.fill"
        case .coreAudioUnavailable:
            return "xmark.octagon.fill"
        case .notConnected:
            return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 11, weight: .medium))
            Text(status.detail)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(statusColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

private struct ProgressiveTopFade: View {
    let isVisible: Bool

    var body: some View {
        LinearGradient(
            colors: [
                Theme.background.opacity(0.98),
                Theme.background.opacity(0.72),
                Theme.background.opacity(0.22),
                Theme.background.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .opacity(isVisible ? 1 : 0)
        .frame(height: 74)
    }
}

private struct ScrollOffsetObserver: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollOffsetObserverView {
        let view = ScrollOffsetObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollOffsetObserverView, context: Context) {
        context.coordinator.onChange = onChange
        nsView.coordinator = context.coordinator
        nsView.installObserverIfPossible()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: @unchecked Sendable {
        var onChange: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        @MainActor
        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView,
                  scrollView !== self.scrollView else {
                updateOffset()
                return
            }

            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateOffset()
                }
            }
            updateOffset()
        }

        @MainActor
        func updateOffset() {
            let offset = max(0, scrollView?.contentView.bounds.origin.y ?? 0)
            onChange(offset)
        }
    }
}

private final class ScrollOffsetObserverView: NSView {
    weak var coordinator: ScrollOffsetObserver.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObserverIfPossible()
    }

    func installObserverIfPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            coordinator?.attach(from: self)
        }
    }
}
