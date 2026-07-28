import AppKit
import SwiftUI

enum Theme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let groupBackground = Color(nsColor: .labelColor).opacity(0.035)
    static let activeRowBackground = Color(nsColor: .labelColor).opacity(0.08)
    static let completedRowBackground = Color(nsColor: .labelColor).opacity(0.035)
    static let pendingRowBackground = Color(nsColor: .labelColor).opacity(0.055)
    static let separator = Color(nsColor: .separatorColor)
}

extension Text {
    func installTitleStyle(color: Color) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    func settingsTitleStyle(color: Color = .primary) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    func settingsDetailStyle() -> some View {
        font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

extension Image {
    func balanceSideIconStyle() -> some View {
        font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 24)
    }
}
