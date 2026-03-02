import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.openSettings) private var openSettings
    var onLogin: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section 1: User info + Usage (or status)
            if let data = viewModel.usageData {
                userInfoSection(data)
                Divider().padding(.vertical, 2)
                usageSection(data)
            } else if viewModel.isLoading {
                Text("Loading...")
                    .foregroundStyle(.secondary)
            } else if let error = viewModel.errorMessage {
                Text("Error: \(error)")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                Text("Not logged in")
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            // Section 2: Actions
            menuRow("Open Dashboard", icon: "arrow.up.right") {
                if let url = URL(string: "https://www.cursor.com/dashboard?tab=usage") {
                    NSWorkspace.shared.open(url)
                }
            }

            menuRow("Settings...", icon: "gear") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            switch viewModel.authState {
            case .loggedOut, .loginRequired:
                menuRow("Log In...", icon: "person") { onLogin() }
            case .loggedIn:
                menuRow("Log Out", icon: "person.slash") { viewModel.logout() }
            }

            if let update = viewModel.availableUpdate {
                menuRow("Update available: v\(update.version)", icon: "arrow.down.circle") {
                    if let url = URL(string: update.htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            menuRow("Quit", icon: nil) { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260)
    }

    // MARK: - Menu Row

    private func menuRow(_ title: String, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - User Info Section

    @ViewBuilder
    private func userInfoSection(_ data: UsageDisplayData) -> some View {
        HStack {
            Text(data.name)
                .font(.system(size: 13, weight: .semibold))
            if let type = data.membershipType {
                Text(type.capitalized)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text(data.email)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Usage Section

    @ViewBuilder
    private func usageSection(_ data: UsageDisplayData) -> some View {
        // Requests + inline refresh
        HStack {
            Text(data.usageLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(data.usageText)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if viewModel.authState == .loggedIn {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
        }

        // Progress bar + percent
        HStack(spacing: 6) {
            ProgressView(value: min(data.percentUsed / 100.0, 1.0))
                .tint(CircularProgressIcon.level(for: data.percentUsed).color)
            Text(data.percentText)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }

        // On-demand usage
        if let onDemandText = data.onDemandText {
            HStack {
                Text("On-demand")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(onDemandText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        // Reset date + refresh interval
        HStack {
            if let resetText = data.resetText {
                Text(resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                    Button(interval.label) {
                        viewModel.setRefreshInterval(interval)
                    }
                }
            } label: {
                Text("⏱ \(viewModel.refreshInterval.label)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
