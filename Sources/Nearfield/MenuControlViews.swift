import AppKit

@MainActor
final class MenuToggleRowView: NSView {
    private let toggle = NSSwitch()
    private let onChange: (Bool) -> Void

    init(title: String, subtitle: String? = nil, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: subtitle == nil ? 42 : 56))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(subtitleLabel)
        }

        toggle.state = isOn ? .on : .off
        toggle.controlSize = .regular
        toggle.focusRingType = .none
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        let row = NSStackView(views: [textStack, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .gravityAreas
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.widthAnchor.constraint(equalToConstant: 206),
            toggle.widthAnchor.constraint(equalToConstant: 58)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        onChange(sender.state == .on)
    }
}

@MainActor
final class MenuBalanceRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Balance")
    private let leftIcon = NSImageView()
    private let rightIcon = NSImageView()
    private let slider: NSSlider
    private let onChange: (Float) -> Void

    init(value: Float, isEnabled: Bool, onChange: @escaping (Float) -> Void) {
        self.slider = NSSlider(value: Double(value), minValue: -1, maxValue: 1, target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 74))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        configureIcon(leftIcon, symbolName: "left.circle.fill")
        configureIcon(rightIcon, symbolName: "right.circle.fill")

        slider.isContinuous = true
        slider.focusRingType = .none
        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        let sliderRow = NSStackView(views: [leftIcon, slider, rightIcon])
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 8
        sliderRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, sliderRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            sliderRow.widthAnchor.constraint(equalToConstant: 280),
            leftIcon.widthAnchor.constraint(equalToConstant: 16),
            leftIcon.heightAnchor.constraint(equalToConstant: 16),
            rightIcon.widthAnchor.constraint(equalToConstant: 16),
            rightIcon.heightAnchor.constraint(equalToConstant: 16),
            slider.widthAnchor.constraint(equalToConstant: 232)
        ])

        update(value: value, isEnabled: isEnabled)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: Float, isEnabled: Bool) {
        setSliderValueWithoutAnimation(value)
        slider.isEnabled = isEnabled
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        leftIcon.contentTintColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        rightIcon.contentTintColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        onChange(sender.floatValue)
    }

    private func configureIcon(_ imageView: NSImageView, symbolName: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        imageView.symbolConfiguration = configuration
        imageView.contentTintColor = .secondaryLabelColor
    }

    private func setSliderValueWithoutAnimation(_ value: Float) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            slider.floatValue = value
        }
    }
}

@MainActor
final class MenuStatusRowView: NSView {
    init(title: String, detail: String, symbolName: String, tintColor: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 58))

        let icon = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        icon.contentTintColor = tintColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            textStack.widthAnchor.constraint(equalToConstant: 246)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class MenuDisclosureRowView: NSControl {
    private let onToggle: () -> Void

    init(title: String, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 38))

        let icon = symbolView("gearshape.fill", tint: .secondaryLabelColor, pointSize: 13)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        let chevron = symbolView(isExpanded ? "chevron.down" : "chevron.right", tint: .secondaryLabelColor, pointSize: 12)

        let content = NSStackView(views: [icon, titleLabel, chevron])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.widthAnchor.constraint(equalToConstant: 220),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onToggle()
    }
}

@MainActor
final class MenuAdvancedPanelView: NSView {
    private let panelHeight: CGFloat

    struct Action {
        let title: String
        let symbolName: String
        let isEnabled: Bool
        let handler: () -> Void
    }

    struct SimulatedStateOption {
        let title: String
        let symbolName: String
        let isSelected: Bool
        let handler: () -> Void
    }

    init(actions: [Action], simulatedStateOptions: [SimulatedStateOption]) {
        panelHeight = CGFloat(actions.count + simulatedStateOptions.count) * 30 + 78
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: panelHeight))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionLabel("Actions"))
        for action in actions {
            stack.addArrangedSubview(MenuActionRowButton(
                title: action.title,
                symbolName: action.symbolName,
                isEnabled: action.isEnabled,
                isSelected: false,
                handler: action.handler
            ))
        }
        stack.addArrangedSubview(spacer(height: 6))
        stack.addArrangedSubview(sectionLabel("Temporary State"))
        for option in simulatedStateOptions {
            stack.addArrangedSubview(MenuActionRowButton(
                title: option.title,
                symbolName: option.symbolName,
                isEnabled: true,
                isSelected: option.isSelected,
                handler: option.handler
            ))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 304, height: panelHeight)
    }

    private func sectionLabel(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
        label.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return label
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

@MainActor
private final class MenuActionRowButton: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let checkLabel = NSTextField(labelWithString: "")
    private let handler: () -> Void

    init(title: String, symbolName: String, isEnabled: Bool, isSelected: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        self.isEnabled = isEnabled
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        checkLabel.stringValue = isSelected ? "✓" : ""
        checkLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        checkLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        checkLabel.alignment = .center

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [checkLabel, iconView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkLabel.widthAnchor.constraint(equalToConstant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.widthAnchor.constraint(equalToConstant: 222)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        handler()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: 28)
    }
}

@MainActor
private func symbolView(_ symbolName: String, tint: NSColor, pointSize: CGFloat) -> NSImageView {
    let imageView = NSImageView()
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    imageView.contentTintColor = tint
    return imageView
}
