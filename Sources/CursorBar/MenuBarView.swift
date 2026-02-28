import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.openSettings) private var openSettings
    var onLogin: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section 1: User info + Usage (or status)
            if let data = viewModel.usageData {
                userInfoSection(data)
                Divider()
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

            Divider()

            // Section 2: Quick settings
            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                Menu("Refresh: \(viewModel.refreshInterval.label)") {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                        Button(interval.label) {
                            viewModel.setRefreshInterval(interval)
                        }
                    }
                }
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Section 3: Actions
            Button("Open Dashboard") {
                if let url = URL(string: "https://www.cursor.com/dashboard?tab=usage") {
                    NSWorkspace.shared.open(url)
                }
            }

            switch viewModel.authState {
            case .loggedOut, .loginRequired:
                Button("Log In...") { onLogin() }
            case .loggedIn:
                Button("Log Out") { viewModel.logout() }
            }

            Divider()

            Button("Quit") { onQuit() }
        }
        .padding(8)
    }

    // MARK: - User Info Section

    @ViewBuilder
    private func userInfoSection(_ data: UsageDisplayData) -> some View {
        HStack {
            Text(data.name)
                .font(.headline)
            Spacer()
            Text(data.email)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Usage Section

    @ViewBuilder
    private func usageSection(_ data: UsageDisplayData) -> some View {
        // Requests + inline refresh
        HStack {
            Text("Requests")
                .font(.subheadline)
            Spacer()
            Text(data.usageText)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if viewModel.authState == .loggedIn {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
        }

        // Progress bar + percent
        HStack(spacing: 8) {
            ProgressView(value: min(data.percentUsed / 100.0, 1.0))
                .tint(CircularProgressIcon.level(for: data.percentUsed).color)
            Text(data.percentText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }

        // Reset date
        if let resetText = data.resetText {
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
