import SwiftUI
import StretchCore

/// A compact native utility: system controls, semantic colors and a single primary action.
public struct ContentView: View {
    @ObservedObject private var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.hasDisplay {
                    settings
                    Label("Choose Full, Wide or Stretch in your monitor’s picture settings.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    emptyState
                }
            }
            .padding(24)
            Divider()
            actionBar
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button(action: model.refreshDisplays) {
                    Label("Refresh Displays", systemImage: "arrow.clockwise")
                }
                .disabled(controlsDisabled)
                .help("Refresh Displays (⌘R)")
            }
        }
        .sheet(item: $model.sheet, onDismiss: {
            if model.pendingChange != nil { model.revertResolution() }
            else { model.cancelTest() }
        }) { sheet in
            switch sheet {
            case .confirm: ConfirmSheet(model: model)
            case .confirmLive: LiveConfirmSheet(model: model)
            }
        }
        .onAppear { model.start() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            DisplayMark()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Stretch Screen")
                    .font(.system(size: 24, weight: .bold))
                Text("A different perspective on your display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("DISPLAY")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Display", selection: displaySelection) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .disabled(controlsDisabled)
                    if let display = model.selectedDisplay {
                        Divider()
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Native resolution").foregroundStyle(.secondary)
                                Text(display.nativeLabel).monospacedDigit()
                            }
                            Spacer()
                            Label(display.isOverrideActive ? "Override active" : "Connected",
                                  systemImage: display.isOverrideActive ? "arrow.left.and.right" : "checkmark.circle.fill")
                                .foregroundStyle(display.isOverrideActive ? Color.orange : Color.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(14)
                .background(cardBackground)
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("RESOLUTION")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Preset", selection: presetSelection) {
                        if model.presets.isEmpty { Text("No compatible presets").tag("") }
                        else if model.usesCustomResolution { Text("Custom").tag("custom") }
                        ForEach(model.presets) { preset in
                            Text("\(preset.title) · \(preset.refreshHz) Hz").tag(preset.id)
                        }
                    }
                    .disabled(model.presets.isEmpty || controlsDisabled)
                    Divider()
                    DisclosureGroup(isExpanded: $model.showsAdvanced) {
                        VStack(spacing: 10) {
                            LabeledContent("Width") { field($model.widthText, label: "Width", suffix: "px") }
                            LabeledContent("Height") { field($model.heightText, label: "Height", suffix: "px") }
                            LabeledContent("Refresh rate") { field($model.refreshText, label: "Refresh rate", suffix: "Hz") }
                            Text("Use a 4:3 resolution. Width must be a multiple of 8.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 12)
                    } label: {
                        Text("Custom resolution").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.selectedDisplay?.isOverrideActive == true {
                        Text("Restore your display before testing another resolution.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(cardBackground)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1)
            .foregroundStyle(.secondary).padding(.leading, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Connect an external display").font(.headline)
            Text("Connect a compatible monitor directly to your Mac, then refresh to get started.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh Displays", action: model.refreshDisplays).disabled(controlsDisabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    private var displaySelection: Binding<Int> {
        Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })
    }
    private var presetSelection: Binding<String> {
        Binding(get: { model.presets.isEmpty ? "" : (model.usesCustomResolution ? "custom" : model.selectedPresetID) },
                set: { if $0 != "custom" { model.selectPreset($0) } })
    }
    private var controlsDisabled: Bool { model.isBusy || model.pendingChange != nil }

    private func field(_ text: Binding<String>, label: String, suffix: String) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: 84).accessibilityLabel(label)
            Text(suffix).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
        }
        .disabled(controlsDisabled)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Working")
                } else {
                    Image(systemName: model.statusSymbol)
                        .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                }
                Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Text("Experimental preview").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore", action: model.restoreFactory)
                    .disabled(!model.hasDisplay || model.isBusy)
                    .help("Remove the temporary display override")
                Button("Test Resolution…", action: model.testResolution)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canTest)
            }
        }
        .padding(20)
        .background(.bar)
    }
}

/// Code-native companion to the reproducible app icon; respects the user's accent color.
struct DisplayMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "display")
                .font(.system(size: 36, weight: .regular)).foregroundStyle(.white)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .offset(y: -4)
        }
    }
}
