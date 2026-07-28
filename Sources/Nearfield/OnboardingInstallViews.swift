import SwiftUI

struct WelcomeOnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            IntroReveal(token: model.introAnimationToken, delay: 0.48, duration: 0.24, yOffset: 12) {
                Button("Install") {
                    model.startInstallFlow()
                }
                .buttonStyle(WelcomeInstallButtonStyle())
                .focusable(false)
                .onHover { model.isInstallHovered = $0 }
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WelcomeInstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 70, height: 30)
            .background(
                Color(red: 0.1882352978, green: 0.1882352978, blue: 0.1882352978)
                    .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct InstallOnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(OnboardingInstallStep.allCases, id: \.rawValue) { step in
                    InstallStepRow(
                        step: step,
                        state: model.installStepState(for: step),
                        pendingOpacity: model.pendingInstallStepOpacity(for: step),
                        requestAccess: model.requestDriverInstallApproval,
                        retry: model.retryCurrentInstallStep
                    )
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .animation(.smooth(duration: 0.24), value: model.installProgressIndex)
            .animation(.smooth(duration: 0.24), value: model.installError?.step.rawValue)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InstallStepRow: View {
    let step: OnboardingInstallStep
    let state: OnboardingInstallStepState
    let pendingOpacity: Double
    let requestAccess: () -> Void
    let retry: (Bool) -> Void

    var body: some View {
        Group {
            switch state {
            case .completed:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .frame(width: 16, height: 16)
                    Text(step.completedTitle)
                        .installTitleStyle(color: .secondary)
                    Spacer()
                }
                .frame(height: 35)
            case .active:
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.activeTitle)
                            .installTitleStyle(color: .primary)
                        Text(step.activeDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if step == .approveDriver {
                            InstallPermissionButton(title: "Request Access", action: requestAccess)
                                .padding(.top, 7)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 11)
                .frame(height: activeRowHeight, alignment: .top)
            case .failed(let error):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error.title)
                            .installTitleStyle(color: .primary)
                        Text(error.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if step == .approveDriver {
                            InstallPermissionButton(title: "Request Again", width: 123) {
                                retry(false)
                            }
                                .padding(.top, 7)
                        }
                    }
                    Spacer()
                    if step != .approveDriver {
                        Button {
                            retry(commandModifierIsPressed)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(retryHelpText)
                    }
                }
                .padding(.top, 10)
                .frame(height: step == .approveDriver ? 101 : 75, alignment: .top)
            case .pending:
                HStack {
                    Text(step.activeTitle)
                        .installTitleStyle(color: .primary)
                    Spacer()
                }
                .frame(height: 32)
                .opacity(pendingOpacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: OnboardingLayout.contentWidth, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var commandModifierIsPressed: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.command) == true ||
            NSEvent.modifierFlags.contains(.command)
    }

    private var retryHelpText: String {
        if step == .environment {
            return "Recheck Studio Displays. Hold Command to continue without them."
        }
        return "Retry current step"
    }

    private var rowBackground: Color {
        switch state {
        case .active, .failed:
            Theme.activeRowBackground
        case .completed:
            Theme.completedRowBackground
        case .pending:
            Theme.pendingRowBackground.opacity(pendingOpacity)
        }
    }

    private var activeRowHeight: CGFloat {
        if step == .approveDriver {
            return 124
        }
        return step.activeDetail.contains("\n") ? 65 : 54
    }
}

private struct InstallPermissionButton: View {
    let title: String
    var width: CGFloat = 132
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(InstallPermissionButtonStyle(width: width))
            .focusable(false)
    }
}

private struct InstallPermissionButtonStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: width, height: 24)
            .background(
                Color(nsColor: .systemBlue)
                    .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
