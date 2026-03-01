import SwiftUI

@main
struct CursorMeterApp: App {
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
            if let data = viewModel.usageData {
                if viewModel.showMenuBarText {
                    Image(nsImage: CircularProgressIcon.menuBarImageWithText(
                        percent: data.percentUsed,
                        used: data.requestsUsed,
                        limit: data.requestsLimit
                    ))
                } else {
                    Image(nsImage: CircularProgressIcon.menuBarImage(percent: data.percentUsed))
                }
            } else {
                Image(nsImage: CircularProgressIcon.idleImage())
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
