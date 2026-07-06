import AppKit

enum SpatialRoutingChannel: String, Equatable {
    case left
    case right
    case pair
    case muted

    var symbolName: String {
        switch self {
        case .left: "l.circle.fill"
        case .right: "r.circle.fill"
        case .pair: "speaker.wave.2.circle.fill"
        case .muted: "speaker.slash.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .left: "Left channel"
        case .right: "Right channel"
        case .pair: "Both channels"
        case .muted: "Muted"
        }
    }

    init?(route: String) {
        switch route.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left", "left-display":
            self = .left
        case "right", "right-display":
            self = .right
        case "pair", "default":
            self = .pair
        case "muted", "mute", "silent":
            self = .muted
        default:
            return nil
        }
    }
}

@MainActor
protocol SettingsWindowControllerDelegate: AnyObject {
    func settingsDevices() -> [AudioDevice]
    func settingsMode() -> NearfieldOutputMode
    func settingsLeftDeviceUID() -> String?
    func settingsOpenAtLogin() -> Bool
    func settingsSetOpenAtLogin(_ enabled: Bool)
    func settingsShowMenuBarApp() -> Bool
    func settingsSetShowMenuBarApp(_ enabled: Bool)
    func settingsDriverInstalled() -> Bool
    func settingsIsInstallingDriver() -> Bool
    func settingsAppRoutingEnabled() -> Bool
    func settingsSetAppRoutingEnabled(_ enabled: Bool)
    func settingsAppRoutingAppBundleIDs() -> [String]?
    func settingsSetAppRoutingAppBundleIDs(_ bundleIDs: [String])
    func settingsSpatialRoutingChannel(
        for bundleIdentifier: String,
        routingBundleIdentifiers: [String]
    ) -> SpatialRoutingChannel?
    func settingsRoutingRules() -> String
    func settingsSetRoutingRules(_ rules: String)
    func settingsFooterStatus() -> String
    func settingsBalance() -> Float
    func settingsSetBalance(_ balance: Float)
    func settingsSetMode(_ mode: NearfieldOutputMode)
    func settingsSetLeftDeviceUID(_ uid: String)
    func settingsApplyConfiguration()
    func settingsInstallDriver()
    func settingsRemoveEverything()
    func settingsPlayTestTone(_ channel: TestToneChannel)
}

@MainActor
final class SettingsWindowController: NSWindowController {
    weak var settingsDelegate: SettingsWindowControllerDelegate?

    private enum Theme {
        static let background = NSColor(calibratedRed: 0.095, green: 0.098, blue: 0.102, alpha: 1)
        static let card = NSColor(calibratedRed: 0.125, green: 0.129, blue: 0.133, alpha: 1)
        static let border = NSColor(calibratedWhite: 1, alpha: 0.06)
        static let separator = NSColor(calibratedWhite: 1, alpha: 0.08)
        static let primary = NSColor(calibratedWhite: 0.92, alpha: 1)
        static let secondary = NSColor(calibratedWhite: 0.66, alpha: 1)
        static let control = NSColor(calibratedRed: 0.20, green: 0.205, blue: 0.215, alpha: 1)
        static let accent = NSColor.systemBlue
        static let destructive = NSColor.systemRed
    }

    private let statusPill = NSTextField(labelWithString: "")
    private let outputModeControl = NSSegmentedControl(labels: ["Stereo", "Mono"], trackingMode: .selectOne, target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let leftPopup = NSPopUpButton()
    private let rightPopup = NSPopUpButton()
    private let swapButton = NSButton(title: "", target: nil, action: nil)
    private let playLeftButton = NSButton(title: "Play Left", target: nil, action: nil)
    private let playRightButton = NSButton(title: "Play Right", target: nil, action: nil)
    private let balanceSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let balanceValueLabel = NSTextField(labelWithString: "Center")
    private let driverStatusPill = NSTextField(labelWithString: "")
    private let setupButton = NSButton(title: "Setup Virtual Driver", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Everything", target: nil, action: nil)
    private let appRoutingSwitch = NSSwitch()
    private let routingRulesField = NSTextField(string: "")
    private let footerLabel = NSTextField(labelWithString: "")

    init(delegate: SettingsWindowControllerDelegate) {
        self.settingsDelegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nearfield Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.background
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        guard let settingsDelegate else { return }
        let devices = Array(settingsDelegate.settingsDevices().prefix(2))
        let mode = settingsDelegate.settingsMode()
        let savedLeftUID = settingsDelegate.settingsLeftDeviceUID()
        let leftUID = devices.contains(where: { $0.uid == savedLeftUID }) ? savedLeftUID : devices.first?.uid
        let rightUID = devices.first(where: { $0.uid != leftUID })?.uid
        if let leftUID, leftUID != savedLeftUID {
            settingsDelegate.settingsSetLeftDeviceUID(leftUID)
        }

        statusPill.stringValue = devices.count >= 2 ? "Nearfield Ready" : "Connect Displays"
        outputModeControl.selectedSegment = mode == .stereo ? 0 : 1
        loginSwitch.state = settingsDelegate.settingsOpenAtLogin() ? .on : .off
        balanceSlider.floatValue = settingsDelegate.settingsBalance()
        balanceValueLabel.stringValue = balanceText(settingsDelegate.settingsBalance())
        let installingDriver = settingsDelegate.settingsIsInstallingDriver()
        appRoutingSwitch.state = settingsDelegate.settingsAppRoutingEnabled() ? .on : .off
        routingRulesField.stringValue = settingsDelegate.settingsRoutingRules()

        let stereoEnabled = mode == .stereo && devices.count >= 2
        leftPopup.isEnabled = stereoEnabled && !installingDriver
        rightPopup.isEnabled = stereoEnabled && !installingDriver
        swapButton.isEnabled = stereoEnabled && !installingDriver
        playLeftButton.isEnabled = stereoEnabled && !installingDriver
        playRightButton.isEnabled = stereoEnabled && !installingDriver
        outputModeControl.isEnabled = !installingDriver
        setupButton.isEnabled = !installingDriver
        removeButton.isEnabled = !installingDriver
        appRoutingSwitch.isEnabled = !installingDriver
        routingRulesField.isEnabled = !installingDriver && settingsDelegate.settingsAppRoutingEnabled()
        setupButton.title = installingDriver ? "Installing..." : "Setup Driver"

        rebuildPopup(leftPopup, devices: devices, selectedUID: leftUID)
        rebuildPopup(rightPopup, devices: devices, selectedUID: rightUID)

        if installingDriver {
            setDriverStatus(driverStatusPill, title: "Installing", color: .systemBlue)
        } else if settingsDelegate.settingsDriverInstalled() {
            setDriverStatus(driverStatusPill, title: "Installed", color: .systemGreen)
        } else {
            setDriverStatus(driverStatusPill, title: "Missing", color: .systemYellow)
        }

        footerLabel.stringValue = settingsDelegate.settingsFooterStatus()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Theme.background.cgColor

        outputModeControl.target = self
        outputModeControl.action = #selector(changeOutputMode)
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        leftPopup.target = self
        leftPopup.action = #selector(selectLeftSpeaker)
        rightPopup.target = self
        rightPopup.action = #selector(selectRightSpeaker)
        setupButton.target = self
        setupButton.action = #selector(installDriver)
        removeButton.target = self
        removeButton.action = #selector(removeEverything)
        appRoutingSwitch.target = self
        appRoutingSwitch.action = #selector(toggleAppRouting)
        routingRulesField.target = self
        routingRulesField.action = #selector(changeRoutingRules)
        swapButton.target = self
        swapButton.action = #selector(swapSpeakers)
        playLeftButton.target = self
        playLeftButton.action = #selector(playLeftTone)
        playRightButton.target = self
        playRightButton.action = #selector(playRightTone)
        balanceSlider.target = self
        balanceSlider.action = #selector(changeBalance)
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap")
        swapButton.bezelStyle = .rounded

        configureControl(outputModeControl)
        configurePopup(leftPopup)
        configurePopup(rightPopup)
        configureButton(playLeftButton, destructive: false)
        configureButton(playRightButton, destructive: false)
        configureButton(setupButton, destructive: false)
        configureButton(removeButton, destructive: true)
        configureDriverStatusPill(driverStatusPill)
        configureRoutingRulesField()
        balanceValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        balanceValueLabel.textColor = Theme.secondary
        balanceValueLabel.alignment = .right
        balanceValueLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        balanceSlider.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let title = label("Nearfield Settings", size: 25, weight: .semibold, color: Theme.primary)
        let subtitle = label("Pair two Studio Displays as one controllable speaker output.", size: 13, weight: .regular, color: Theme.secondary)
        statusPill.font = .systemFont(ofSize: 12, weight: .medium)
        statusPill.alignment = .center
        statusPill.textColor = NSColor.systemGreen
        statusPill.wantsLayer = true
        statusPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.11).cgColor
        statusPill.layer?.cornerRadius = 11
        statusPill.widthAnchor.constraint(equalToConstant: 130).isActive = true
        statusPill.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let titleRow = NSStackView(views: [title, statusPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .gravityAreas

        let header = NSStackView(views: [titleRow, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5

        let topCard = card([
            row(title: "Open at Login", trailing: loginSwitch),
            row(title: "Output Mode", trailing: outputModeControl)
        ])

        let monitorCard = card([
            row(title: "Left Channel", trailing: leftPopup),
            row(title: "Right Channel", trailing: rightPopup),
            row(title: "Balance", detail: "Slide toward either side to reduce the opposite channel.", trailing: balanceControls()),
            row(title: "Identify Channels", detail: "Play a short tone through either stereo channel to confirm the physical assignment.", trailing: testToneControls()),
            row(title: "Swap Assignment", trailing: swapButton)
        ])

        let driverCard = card([
            row(title: "Driver", detail: "Router HAL output named Nearfield for system volume control.", trailing: driverControls(status: driverStatusPill, action: setupButton)),
            row(title: "App Routing", detail: "Route matching bundle IDs through the router output.", trailing: appRoutingSwitch),
            row(title: "Routing Rules", detail: "Format: bundle.id=left/right/pair/window.", trailing: routingRulesField),
            row(title: "Remove & Clean Up", detail: "Remove the HAL driver and old Nearfield aggregate devices.", trailing: removeButton)
        ])

        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = Theme.secondary

        let contentStack = NSStackView(views: [
            header,
            topCard,
            section("Monitor Assignment"),
            monitorCard,
            section("Virtual Driver"),
            driverCard,
            footerLabel
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let documentView = NSView()
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = Theme.background.cgColor
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 44),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 34),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -34),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -26)
        ])
    }

    private func card(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0

        for (index, rowView) in rows.enumerated() {
            stack.addArrangedSubview(rowView)
            if index < rows.count - 1 {
                stack.addArrangedSubview(separator())
            }
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.card.cgColor
        container.layer?.cornerRadius = 16
        container.layer?.borderColor = Theme.border.cgColor
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 692),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    private func row(title: String, detail: String? = nil, trailing: NSView) -> NSView {
        let titleLabel = label(title, size: 15, weight: .regular, color: Theme.primary)
        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        if let detail {
            let detailLabel = label(detail, size: 12, weight: .regular, color: Theme.secondary)
            detailLabel.maximumNumberOfLines = 2
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.widthAnchor.constraint(equalToConstant: 350).isActive = true
            textStack.addArrangedSubview(detailLabel)
        }
        textStack.widthAnchor.constraint(equalToConstant: 370).isActive = true

        let row = NSStackView(views: [textStack, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.widthAnchor.constraint(equalToConstant: 656).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 54 : 74).isActive = true
        return row
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.separator.cgColor
        view.widthAnchor.constraint(equalToConstant: 656).isActive = true
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func section(_ title: String) -> NSTextField {
        label(title, size: 15, weight: .semibold, color: Theme.primary)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.allowsDefaultTighteningForTruncation = false
        return label
    }

    private func configureControl(_ control: NSSegmentedControl) {
        control.segmentStyle = .rounded
        control.controlSize = .large
        control.widthAnchor.constraint(equalToConstant: 230).isActive = true
    }

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.bezelStyle = .rounded
        popup.controlSize = .large
        popup.widthAnchor.constraint(equalToConstant: 250).isActive = true
    }

    private func configureButton(_ button: NSButton, destructive: Bool) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.contentTintColor = destructive ? Theme.destructive : nil
    }

    private func configureDriverStatusPill(_ pill: NSTextField) {
        pill.font = .systemFont(ofSize: 12, weight: .semibold)
        pill.alignment = .center
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.widthAnchor.constraint(equalToConstant: 88).isActive = true
        pill.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func setDriverStatus(_ pill: NSTextField, title: String, color: NSColor) {
        pill.stringValue = title
        pill.textColor = color
        pill.layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor
    }

    private func configureRoutingRulesField() {
        routingRulesField.placeholderString = WindowAudioRouteResolver.defaultRoutingRules
        routingRulesField.controlSize = .large
        routingRulesField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        routingRulesField.widthAnchor.constraint(equalToConstant: 250).isActive = true
    }

    private func testToneControls() -> NSStackView {
        let stack = NSStackView(views: [playLeftButton, playRightButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func driverControls(status: NSTextField, action: NSButton) -> NSStackView {
        let stack = NSStackView(views: [status, action])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        action.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return stack
    }

    private func balanceControls() -> NSStackView {
        let left = label("L", size: 12, weight: .medium, color: Theme.secondary)
        let right = label("R", size: 12, weight: .medium, color: Theme.secondary)
        let stack = NSStackView(views: [left, balanceSlider, right, balanceValueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func balanceText(_ balance: Float) -> String {
        if abs(balance) < 0.03 {
            return "Center"
        }
        return balance < 0 ? "\(Int(abs(balance) * 100))% L" : "\(Int(balance * 100))% R"
    }

    private func rebuildPopup(_ popup: NSPopUpButton, devices: [AudioDevice], selectedUID: String?) {
        popup.removeAllItems()
        for (index, device) in devices.enumerated() {
            popup.addItem(withTitle: device.displayName(index: index))
            popup.lastItem?.representedObject = device.uid
            popup.lastItem?.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        }
        if let selectedUID,
           let item = popup.itemArray.first(where: { $0.representedObject as? String == selectedUID }) {
            popup.select(item)
        }
    }

    @objc private func changeOutputMode() {
        settingsDelegate?.settingsSetMode(outputModeControl.selectedSegment == 0 ? .stereo : .mono)
        settingsDelegate?.settingsApplyConfiguration()
        reload()
    }

    @objc private func toggleLogin() {
        settingsDelegate?.settingsSetOpenAtLogin(loginSwitch.state == .on)
        reload()
    }

    @objc private func selectLeftSpeaker() {
        guard let uid = leftPopup.selectedItem?.representedObject as? String else { return }
        settingsDelegate?.settingsSetLeftDeviceUID(uid)
        settingsDelegate?.settingsApplyConfiguration()
        reload()
    }

    @objc private func selectRightSpeaker() {
        guard let rightUID = rightPopup.selectedItem?.representedObject as? String,
              let leftUID = settingsDelegate?.settingsDevices().prefix(2).first(where: { $0.uid != rightUID })?.uid else {
            return
        }
        settingsDelegate?.settingsSetLeftDeviceUID(leftUID)
        settingsDelegate?.settingsApplyConfiguration()
        reload()
    }

    @objc private func swapSpeakers() {
        guard let rightUID = rightPopup.selectedItem?.representedObject as? String else { return }
        settingsDelegate?.settingsSetLeftDeviceUID(rightUID)
        settingsDelegate?.settingsApplyConfiguration()
        reload()
    }

    @objc private func changeBalance() {
        let balance = balanceSlider.floatValue
        balanceValueLabel.stringValue = balanceText(balance)
        settingsDelegate?.settingsSetBalance(balance)
    }

    @objc private func playLeftTone() {
        settingsDelegate?.settingsPlayTestTone(.left)
    }

    @objc private func playRightTone() {
        settingsDelegate?.settingsPlayTestTone(.right)
    }

    @objc private func installDriver() {
        settingsDelegate?.settingsInstallDriver()
        reload()
    }

    @objc private func toggleAppRouting() {
        settingsDelegate?.settingsSetAppRoutingEnabled(appRoutingSwitch.state == .on)
        reload()
    }

    @objc private func changeRoutingRules() {
        settingsDelegate?.settingsSetRoutingRules(routingRulesField.stringValue)
        reload()
    }

    @objc private func removeEverything() {
        settingsDelegate?.settingsRemoveEverything()
        reload()
    }
}
