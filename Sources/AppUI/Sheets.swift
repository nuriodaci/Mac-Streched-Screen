import SwiftUI

/// Confirmation sheets follow the standard macOS alert composition: caution glyph, headline,
/// message, optional acknowledgement, then trailing Cancel / primary buttons.
public struct ConfirmSheet: View {
    @ObservedObject private var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                DisplayMark()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text("Test this resolution?")
                    .font(.headline)
                Text(model.requestedMode)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            Text("Save your work first. This experimental Apple API can interrupt the display. A separate helper attempts to remove the override after 20 seconds, but cannot recover a system or driver hang. HDR and HDMI audio may be unavailable until you restore.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 24)

            Toggle("I understand the risks", isOn: $model.acknowledgesExperimentalRisk)
                .toggleStyle(.checkbox)
                .disabled(model.isBusy)
                .padding(.top, 18)

            Divider()
                .padding(.top, 20)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.cancelTest() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button("Test") { model.confirmTest() }
                    .disabled(!model.canConfirmTest)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isBusy)
    }
}

public struct LiveConfirmSheet: View {
    @ObservedObject private var model: AppModel
    public init(model: AppModel) { self.model = model }

    private var countdown: String {
        model.remainingSeconds > 0 ? "\(model.remainingSeconds)" : "0"
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(countdown)
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .foregroundStyle(model.remainingSeconds <= 5 ? Color.orange : Color.accentColor)
                    .monospacedDigit()
                    .accessibilityLabel("\(countdown) seconds remaining")
                Text("Keep this resolution?")
                    .font(.headline)
                Text(model.requestedMode)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            Text(model.remainingSeconds > 0
                 ? "The restore helper will attempt to remove the temporary override when the timer ends."
                 : "The timer has ended. Restore the display to remove the override.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 24)

            Divider()
                .padding(.top, 20)

            HStack(spacing: 10) {
                Spacer()
                Button("Revert") { model.revertResolution() }
                    .disabled(model.isBusy)
                    .keyboardShortcut(.cancelAction)
                Button("Keep Resolution") { model.keepResolution() }
                    .disabled(model.isBusy || model.remainingSeconds == 0 || !model.canKeepResolution)
                // No Return-key shortcut: a black screen must never be confirmed blindly.
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isBusy)
    }
}
