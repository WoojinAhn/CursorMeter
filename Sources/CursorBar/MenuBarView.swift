import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: UsageViewModel
    var onLogin: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = viewModel.usageData {
                usageContent(data)
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

            // Refresh interval picker
            Menu("Refresh: \(viewModel.refreshInterval.label)") {
                ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                    Button(interval.label) {
                        viewModel.setRefreshInterval(interval)
                    }
                }
            }

            Divider()

            switch viewModel.authState {
            case .loggedOut, .loginRequired:
                Button("Log In...") { onLogin() }
            case .loggedIn:
                Button("Refresh Now") {
                    Task { await viewModel.refresh() }
                }
                Button("Log Out") { viewModel.logout() }
            }

            Button("Open Dashboard") {
                if let url = URL(string: "https://www.cursor.com/dashboard") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("Quit") { onQuit() }
        }
        .padding(8)
    }

    @ViewBuilder
    private func usageContent(_ data: UsageDisplayData) -> some View {
        // Name & email
        HStack {
            Text(data.name)
                .font(.headline)
            Spacer()
            Text(data.email)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Request usage
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Requests")
                    .font(.subheadline)
                Spacer()
                Text(data.usageText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(data.percentUsed / 100.0, 1.0))
                .tint(data.percentUsed > 90 ? .red : .accentColor)
            HStack {
                Spacer()
                Text(data.percentText + " used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // Reset date
        if let resetText = data.resetText {
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
