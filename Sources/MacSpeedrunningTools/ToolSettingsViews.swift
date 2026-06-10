import AppKit
import SwiftUI

@MainActor
final class BetterNBBToolController: ObservableObject, @preconcurrency SSEClientDelegate, @preconcurrency InformationMessageClientDelegate {
    @Published var isEnabled = false
    @Published var isConnected = false
    @Published var config = OverlayConfig.load()
    @Published var placementMode = false

    private var overlay: OverlayWindow?
    private let sse = SSEClient()
    private let messages = InformationMessageClient()
    private var refreshTimer: Timer?

    init() {
        sse.delegate = self
        messages.delegate = self
    }

    func toggle() {
        isEnabled ? stop() : start()
    }

    func start() {
        if overlay == nil {
            overlay = OverlayWindow(cfg: config)
            overlay?.onPlacementRectChanged = { [weak self] rect in
                Task { @MainActor in
                    self?.applyPlacement(rect)
                }
            }
        }
        overlay?.reconfigure(config)
        overlay?.rebuildLayout()
        overlay?.show()
        sse.connect()
        messages.connect()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.sse.fetchSnapshot()
        }
        isEnabled = true
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        sse.disconnect()
        messages.disconnect()
        overlay?.hide()
        isEnabled = false
        isConnected = false
    }

    func updateConfig(_ apply: (inout OverlayConfig) -> Void) {
        apply(&config)
        config.save()
        overlay?.reconfigure(config)
    }

    func setPlacementMode(_ enabled: Bool) {
        placementMode = enabled
        if !isEnabled { start() }
        overlay?.setPlacementMode(enabled)
        overlay?.rebuildLayout()
    }

    private func applyPlacement(_ rect: CGRect) {
        updateConfig { config in
            config.overlayX = rect.minX
            config.overlayY = rect.minY
            config.overlayWidth = min(2600, max(220, rect.width))
            config.overlayHeight = min(1400, max(120, rect.height))
            config.overlaySet = true
        }
    }

    func sseClient(_ client: SSEClient, didReceive state: NBBState) {
        overlay?.apply(state)
    }

    func sseClientConnectionChanged(_ client: SSEClient, connected: Bool) {
        isConnected = connected
    }

    func informationMessageClient(_ client: InformationMessageClient, didReceive messages: [NBBState.InformationMessage]) {
        overlay?.applyMessages(messages)
    }
}

struct BetterNBBSettingsView: View {
    @ObservedObject var controller: BetterNBBToolController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "BetterNBB", subtitle: controller.isConnected ? "Connected to Ninjabrain Bot." : "Waiting for Ninjabrain Bot data.")

            Button {
                controller.toggle()
            } label: {
                Label(controller.isEnabled ? "Stop BetterNBB" : "Start BetterNBB", systemImage: controller.isEnabled ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PrimaryMonoButtonStyle(active: controller.isEnabled))

            SectionBox(title: "Overlay Position") {
                HStack {
                    Button(controller.placementMode ? "Finish Overlay Placement" : "Place Overlay Template") {
                        controller.setPlacementMode(!controller.placementMode)
                    }
                    .buttonStyle(PrimaryMonoButtonStyle())
                    Text(controller.config.overlaySet ? String(format: "%.0f, %.0f  %.0f x %.0f", controller.config.overlayX, controller.config.overlayY, controller.config.overlayWidth, controller.config.overlayHeight) : "Not set")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            SectionBox(title: "Row Counts") {
                Stepper("Prediction rows: \(controller.config.maxPredRows)", value: Binding(
                    get: { controller.config.maxPredRows },
                    set: { value in controller.updateConfig { $0.maxPredRows = value } }
                ), in: 1...5)
                Stepper("Eye throw rows: \(controller.config.maxEyeRows)", value: Binding(
                    get: { controller.config.maxEyeRows },
                    set: { value in controller.updateConfig { $0.maxEyeRows = value } }
                ), in: 1...2)
            }

            SectionBox(title: "Stronghold Columns") {
                ToggleGrid(items: [
                    ("Distance", binding(\.showDist)),
                    ("Location", binding(\.showLoc)),
                    ("Percent", binding(\.showPct)),
                    ("Nether", binding(\.showNether)),
                    ("Nether Distance", binding(\.showNetherDist)),
                    ("Angle", binding(\.showAngle))
                ])
            }

            SectionBox(title: "Eye Throw Columns") {
                ToggleGrid(items: [
                    ("X", binding(\.showEyeX)),
                    ("Z", binding(\.showEyeZ)),
                    ("Angle", binding(\.showEyeAngle)),
                    ("Offset", binding(\.showEyeOffset)),
                    ("Error", binding(\.showEyeError)),
                    ("Boat Dot", binding(\.showEyeMarker))
                ])
            }

            SectionBox(title: "Options") {
                Toggle("Hide 0% predictions", isOn: binding(\.hideZeroPct))
                Toggle("Show NBB messages", isOn: binding(\.showInfoMessages))
                Toggle("Show movement hint", isOn: binding(\.showMoveHint))
            }

            SectionBox(title: "Window Style") {
                ColorPicker("Background", selection: Binding(
                    get: { Color(nsColor: controller.config.windowBackgroundColor.withAlphaComponent(1)) },
                    set: { color in
                        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
                        controller.updateConfig {
                            $0.windowBgRed = Double(nsColor.redComponent)
                            $0.windowBgGreen = Double(nsColor.greenComponent)
                            $0.windowBgBlue = Double(nsColor.blueComponent)
                        }
                    }
                ), supportsOpacity: false)
                SliderRow(title: "Opacity", value: Binding(get: { controller.config.windowBgOpacity }, set: { value in controller.updateConfig { $0.windowBgOpacity = value } }), range: 0...1)
                Toggle("Enable border", isOn: binding(\.windowShowBorder))
                SliderRow(title: "Border Width", value: Binding(get: { controller.config.windowBorderWidth }, set: { value in controller.updateConfig { $0.windowBorderWidth = value } }), range: 0...6)
                SliderRow(title: "Corner Radius", value: Binding(get: { controller.config.windowCornerRadius }, set: { value in controller.updateConfig { $0.windowCornerRadius = value } }), range: 0...24)
                SliderRow(title: "Shadow", value: Binding(get: { controller.config.windowShadowStrength }, set: { value in controller.updateConfig { $0.windowShadowStrength = value } }), range: 0...1)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<OverlayConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.config[keyPath: keyPath] },
            set: { value in controller.updateConfig { $0[keyPath: keyPath] = value } }
        )
    }
}

struct WindowBackdropSettingsView: View {
    @ObservedObject var state: WindowBackdropState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "WindowBackdrop", subtitle: state.activeWindow?.displayName ?? "Cover everything except the active target window.")
            Button {
                state.startOrStopBackdrop()
            } label: {
                Label(state.isBackdropEnabled ? "Stop Backdrop" : "Start Backdrop", systemImage: state.isBackdropEnabled ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PrimaryMonoButtonStyle(active: state.isBackdropEnabled))

            SectionBox(title: "Backdrop") {
                ColorPicker("Color", selection: $state.backgroundColor, supportsOpacity: false)
                HStack {
                    Button("Choose Image") { state.chooseImage() }
                    Button("Clear") { state.clearImage() }
                        .disabled(state.imageURL == nil)
                }
                .buttonStyle(.bordered)
                if let imageURL = state.imageURL {
                    Text(imageURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image Fit", selection: $state.imageFitMode) {
                        ForEach(ImageFitMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if state.imageFitMode == .keepAspectRatio {
                        ColorPicker("Empty Zones", selection: $state.emptyZoneColor, supportsOpacity: false)
                    }
                }
            }

            SectionBox(title: "Style") {
                SliderRow(title: "Opacity", value: $state.opacity, range: 0.1...1.0)
                SliderRow(title: "Blur", value: $state.blurRadius, range: 0...40, suffix: "px")
            }

            SectionBox(title: "Coverage") {
                Toggle("Cover Menu Bar", isOn: $state.coverMenuBar)
                Text(state.status)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MacrosshairSettingsView: View {
    @ObservedObject var controller: MacrosshairController
    @ObservedObject private var settings: CrosshairSettings

    init(controller: MacrosshairController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "MACrosshair", subtitle: "Screen-level crosshair overlay controls.")
            Button {
                controller.toggle()
            } label: {
                Label(controller.isVisible ? "Hide Crosshair" : "Show Crosshair", systemImage: "scope")
            }
            .buttonStyle(PrimaryMonoButtonStyle(active: controller.isVisible))

            SectionBox(title: "Color") {
                HStack {
                    ForEach(colorPresets, id: \.name) { preset in
                        Button(preset.name) { settings.color = preset.color }
                            .buttonStyle(.bordered)
                    }
                }
            }

            SectionBox(title: "Shape") {
                SliderRow(title: "Line Length", value: Binding(get: { Double(settings.lineLength) }, set: { settings.lineLength = CGFloat($0) }), range: 4...40)
                SliderRow(title: "Line Thickness", value: Binding(get: { Double(settings.lineThickness) }, set: { settings.lineThickness = CGFloat($0) }), range: 1...8)
                Toggle("Show Center Dot", isOn: $settings.showDot)
                SliderRow(title: "Dot Size", value: Binding(get: { Double(settings.dotSize) }, set: { settings.dotSize = CGFloat($0) }), range: 2...12)
                SliderRow(title: "Opacity", value: Binding(get: { Double(settings.opacity) }, set: { settings.opacity = CGFloat($0) }), range: 0.1...1.0)
            }

            SectionBox(title: "Offset") {
                HStack {
                    TextField("X", value: Binding(get: { Double(settings.offsetX) }, set: { settings.offsetX = CGFloat($0) }), format: .number)
                    TextField("Y", value: Binding(get: { Double(settings.offsetY) }, set: { settings.offsetY = CGFloat($0) }), format: .number)
                    Button("Reset") {
                        settings.offsetX = 0
                        settings.offsetY = 0
                    }
                }
            }
        }
    }

    private var colorPresets: [(name: String, color: NSColor)] {
        [("Red", .red), ("Green", .green), ("White", .white), ("Yellow", .yellow), ("Cyan", .cyan)]
    }
}

struct ToggleGrid: View {
    let items: [(String, Binding<Bool>)]
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Toggle(item.0, isOn: item.1)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 130, alignment: .leading)
            Slider(value: $value, in: range)
            Text(label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var label: String {
        if suffix.isEmpty {
            return String(format: "%.2f", value)
        }
        return "\(Int(value))\(suffix)"
    }
}
