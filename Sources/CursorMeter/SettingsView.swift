import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: UsageViewModel

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Interval", selection: refreshIntervalBinding) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable usage alerts", isOn: notificationEnabledBinding)

                if viewModel.notificationEnabled {
                    LabeledContent("Warning") {
                        Text("\(viewModel.warningThreshold)%")
                            .monospacedDigit()
                    }
                    Slider(value: warningSlider, in: 50...90, step: 5)

                    LabeledContent("Critical") {
                        Text("\(viewModel.criticalThreshold)%")
                            .monospacedDigit()
                    }
                    Slider(value: criticalSlider, in: criticalSliderRange, step: 5)
                }
            }

            Section("Menu Bar") {
                Toggle("Show usage text next to icon", isOn: showMenuBarTextBinding)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 300)
    }

    // MARK: - Bindings

    private var refreshIntervalBinding: Binding<RefreshInterval> {
        Binding(
            get: { viewModel.refreshInterval },
            set: { viewModel.setRefreshInterval($0) }
        )
    }

    private var notificationEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notificationEnabled },
            set: { viewModel.setNotificationEnabled($0) }
        )
    }

    private var warningSlider: Binding<Double> {
        Binding(
            get: { Double(viewModel.warningThreshold) },
            set: {
                viewModel.setWarningThreshold(Int($0))
                if viewModel.criticalThreshold < viewModel.warningThreshold + 5 {
                    viewModel.setCriticalThreshold(viewModel.warningThreshold + 5)
                }
            }
        )
    }

    private var criticalSliderRange: ClosedRange<Double> {
        let minVal = Double(min(viewModel.warningThreshold + 5, 100))
        return minVal...100
    }

    private var criticalSlider: Binding<Double> {
        Binding(
            get: { Double(viewModel.criticalThreshold) },
            set: { viewModel.setCriticalThreshold(Int($0)) }
        )
    }

    private var showMenuBarTextBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showMenuBarText },
            set: { viewModel.setShowMenuBarText($0) }
        )
    }
}
