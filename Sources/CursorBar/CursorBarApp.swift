import SwiftUI

@main
struct CursorBarApp: App {
    @State private var viewModel = UsageViewModel()
    @State private var loginWindow: LoginWindow?

    var body: some Scene {
        MenuBarExtra("CursorBar", systemImage: "chart.bar.fill") {
            MenuBarView(
                viewModel: viewModel,
                onLogin: { showLogin() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .onAppear {
                viewModel.checkExistingSession()
            }
        }
        .menuBarExtraStyle(.window)
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
