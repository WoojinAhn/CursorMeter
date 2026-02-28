import SwiftUI

@main
struct CursorBarApp: App {
    @State private var viewModel = UsageViewModel()
    @State private var loginWindow: LoginWindow?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                viewModel: viewModel,
                onLogin: { showLogin() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .onAppear {
                viewModel.checkExistingSession()
            }
        } label: {
            let percent = viewModel.usageData?.percentUsed ?? 0
            Image(nsImage: CircularProgressIcon.menuBarImage(percent: percent))
            if viewModel.showMenuBarText, let data = viewModel.usageData {
                Text(data.usageText)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    private func showLogin() {
        let window = LoginWindow()
        loginWindow = window
        window.open { cookieHeader in
            if let cookieHeader {
                viewModel.onLoginSuccess(cookieHeader: cookieHeader)
            }
            loginWindow = nil
        }
    }
}
