import SwiftUI

/// The Scrolling page's sections below its options: the wheel step size and
/// whether the tap is missing the Accessibility permission.
struct ScrollingSettingsView: View {
    @Bindable var settings: ScrollingSettings
    let reverser: ScrollReverser
    let requestAccessibility: () -> Void

    var body: some View {
        Section {
            Slider(value: stepSize, in: 0...1) {
                Text("Wheel step size")
            } minimumValueLabel: {
                Text("Small")
            } maximumValueLabel: {
                Text("Large")
            }
            Text("macOS has one scroll direction for all devices (Natural scrolling in Trackpad or Mouse settings). This reverses it for the chosen devices, so the trackpad and the mouse can scroll differently. The step size is how far one notch of a mouse wheel scrolls; all the way left leaves it to macOS. Other apps that change scrolling cancel this out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.activeRules != nil && !reverser.isRunning {
                HStack {
                    Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Grant Access…", action: requestAccessibility)
                }
            }
        }
    }

    private var stepSize: Binding<Double> {
        Binding(
            get: { ScrollingSettings.sliderPosition(stepSize: settings.wheelStepSize) },
            set: { settings.wheelStepSize = ScrollingSettings.stepSize(sliderPosition: $0) })
    }
}
