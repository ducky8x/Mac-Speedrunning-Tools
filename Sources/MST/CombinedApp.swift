import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct MSTApp: App {
    @NSApplicationDelegateAdaptor(CombinedAppDelegate.self) private var appDelegate
    @StateObject private var hub = ToolHub.shared

    var body: some Scene {
        WindowGroup("MST") {
            RootView()
                .environmentObject(hub)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(hub.appSettings.preferredColorScheme)
        }
        .windowStyle(.titleBar)

        Window("Settings", id: "mst-settings") {
            MSTSettingsView(settings: hub.appSettings)
                .environmentObject(hub)
                .preferredColorScheme(hub.appSettings.preferredColorScheme)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class CombinedAppDelegate: NSObject, NSApplicationDelegate {
    private let hub = ToolHub.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = hub
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        }
        return true
    }
}

enum MSTAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark mode"
        case .light: "Light mode"
        case .system: "System"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    func shouldInvert(systemColorScheme: ColorScheme) -> Bool {
        switch self {
        case .dark: false
        case .light: true
        case .system: systemColorScheme == .light
        }
    }
}

@MainActor
final class AppSettingsController: ObservableObject {
    private let appearanceKey = "macSpeedrunningTools.settings.appearanceMode.v1"
    private let openOnLaunchKey = "macSpeedrunningTools.settings.openOnLaunch.v1"
    private var isApplyingOpenOnLaunch = false

    @Published var appearanceMode: MSTAppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: appearanceKey)
            UserDefaults.standard.synchronize()
        }
    }

    @Published var openOnLaunch: Bool {
        didSet {
            guard !isApplyingOpenOnLaunch else { return }
            UserDefaults.standard.set(openOnLaunch, forKey: openOnLaunchKey)
            UserDefaults.standard.synchronize()
            applyOpenOnLaunch()
        }
    }

    var preferredColorScheme: ColorScheme? {
        appearanceMode.preferredColorScheme
    }

    init() {
        let rawMode = UserDefaults.standard.string(forKey: appearanceKey)
        appearanceMode = rawMode.flatMap(MSTAppearanceMode.init(rawValue:)) ?? .dark
        openOnLaunch = UserDefaults.standard.bool(forKey: openOnLaunchKey)
    }

    func restartWalkthrough() {
        NotificationCenter.default.post(name: .restartMSTWalkthrough, object: nil)
    }

    private func applyOpenOnLaunch() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if openOnLaunch {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            isApplyingOpenOnLaunch = true
            openOnLaunch.toggle()
            isApplyingOpenOnLaunch = false
            UserDefaults.standard.set(openOnLaunch, forKey: openOnLaunchKey)
            UserDefaults.standard.synchronize()
        }
    }
}

extension Notification.Name {
    static let restartMSTWalkthrough = Notification.Name("macSpeedrunningTools.restartWalkthrough")
}

enum ToolSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case nbb = "BetterNBB"
    case backdrop = "WindowBackdrop"
    case piechart = "Better Piechart"
    case crosshair = "MACrosshair"
    case keyRebinder = "Key Rebinder"

    var id: Self { self }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .nbb: "map"
        case .backdrop: "macwindow"
        case .piechart: "chart.pie"
        case .crosshair: "scope"
        case .keyRebinder: "keyboard"
        }
    }

    var description: String? {
        switch self {
        case .overview:
            nil
        case .nbb:
            "A better overlay for NinjabrainBot."
        case .backdrop:
            "A backdrop that goes behind your Minecraft instance."
        case .piechart:
            "A thin-mode F3 piechart projector that makes the piechart round. :)"
        case .crosshair:
            "Draws a crosshair on the screen."
        case .keyRebinder:
            "Syncs Karabiner profiles and simple modifications from inside MST."
        }
    }
}

@MainActor
final class ToolHub: ObservableObject {
    static let shared = ToolHub()

    @Published var selection: ToolSection = .overview
    @Published var simpleMode = false

    @Published var nbb = BetterNBBToolController()
    @Published var backdrop = WindowBackdropState()
    @Published var piechart = PiechartState()
    @Published var crosshair = MacrosshairController()
    @Published var keyRebinder = KeyRebinderController()
    @Published var keybinds = ToolKeybindStore()
    @Published var appSettings = AppSettingsController()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        keybinds.onTrigger = { [weak self] section in
            self?.triggerShortcut(section)
        }

        for publisher in [
            nbb.objectWillChange.eraseToAnyPublisher(),
            backdrop.objectWillChange.eraseToAnyPublisher(),
            piechart.objectWillChange.eraseToAnyPublisher(),
            crosshair.objectWillChange.eraseToAnyPublisher(),
            keyRebinder.objectWillChange.eraseToAnyPublisher(),
            keybinds.objectWillChange.eraseToAnyPublisher(),
            appSettings.objectWillChange.eraseToAnyPublisher()
        ] {
            publisher
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.objectWillChange.send()
                    }
                }
                .store(in: &cancellables)
        }
    }

    func isEnabled(_ section: ToolSection) -> Bool {
        switch section {
        case .overview: true
        case .nbb: nbb.isEnabled
        case .backdrop: backdrop.isBackdropEnabled
        case .piechart: piechart.isLive
        case .crosshair: crosshair.isEnabled
        case .keyRebinder: keyRebinder.karabinerStatus.isConnected
        }
    }

    func toggle(_ section: ToolSection) {
        switch section {
        case .overview:
            simpleMode = false
        case .nbb:
            nbb.toggle()
        case .backdrop:
            backdrop.startOrStopBackdrop()
        case .piechart:
            piechart.toggle()
        case .crosshair:
            crosshair.toggleTool()
        case .keyRebinder:
            keyRebinder.cycleKarabinerProfile()
        }
    }

    func triggerShortcut(_ section: ToolSection) {
        switch section {
        case .overview:
            break
        case .nbb:
            nbb.toggleVisibility()
        case .backdrop:
            backdrop.toggleBackdropVisibility()
        case .piechart:
            break
        case .crosshair:
            crosshair.toggleVisibility()
        case .keyRebinder:
            keyRebinder.cycleKarabinerProfile()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var hub: ToolHub
    @Environment(\.colorScheme) private var systemColorScheme
    @StateObject private var setupAssistant = SetupAssistantController()

    private var isColorInverted: Bool {
        hub.appSettings.appearanceMode.shouldInvert(systemColorScheme: systemColorScheme)
    }

    var body: some View {
        Group {
            if hub.simpleMode {
                SimpleModeView()
            } else {
                ComplexModeView()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background(MSTWindowAppearanceBridge(inverted: isColorInverted))
        .foregroundStyle(Color.white)
        .tint(isColorInverted ? .black : .white)
        .environment(\.mstColorInversionEnabled, isColorInverted)
        .overlay(alignment: .topTrailing) {
            if setupAssistant.isPresented {
                SetupAssistantPopup(
                    step: setupAssistant.currentStep,
                    nextAction: advanceSetupAssistant,
                    skipAction: advanceSetupAssistant,
                    skipAllAction: setupAssistant.skipAll
                )
                .padding(.top, 22)
                .padding(.trailing, 22)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restartMSTWalkthrough)) { _ in
            setupAssistant.resetAndShow()
            hub.simpleMode = false
            hub.selection = .overview
        }
        .modifier(MSTColorInvertModifier(enabled: isColorInverted))
    }

    private func advanceSetupAssistant() {
        let nextSection = setupAssistant.advance()
        selectSetupSection(nextSection)
    }

    private func selectSetupSection(_ section: ToolSection?) {
        guard let section else { return }
        hub.simpleMode = false
        hub.selection = section
    }
}

struct MSTColorInvertModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.colorInvert()
        } else {
            content
        }
    }
}

private struct MSTColorInversionEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mstColorInversionEnabled: Bool {
        get { self[MSTColorInversionEnabledKey.self] }
        set { self[MSTColorInversionEnabledKey.self] = newValue }
    }
}

struct MSTPreserveSemanticColor: ViewModifier {
    @Environment(\.mstColorInversionEnabled) private var isColorInverted

    func body(content: Content) -> some View {
        content.modifier(MSTColorInvertModifier(enabled: isColorInverted))
    }
}

struct MSTWindowAppearanceBridge: NSViewRepresentable {
    let inverted: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        let background = inverted ? NSColor.white : NSColor.black
        window.appearance = NSAppearance(named: inverted ? .aqua : .darkAqua)
        window.backgroundColor = background
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = background.cgColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

struct SetupAssistantStep: Identifiable, Equatable {
    let id: String
    let section: ToolSection?
    let bodyText: String
    var warningText: String?
    var imageName: String?
}

@MainActor
final class SetupAssistantController: ObservableObject {
    private static let completedKey = "macSpeedrunningTools.setupAssistant.completed.v1"

    @Published var isPresented: Bool
    @Published private var stepIndex = 0

    private let steps: [SetupAssistantStep] = [
        SetupAssistantStep(
            id: "intro",
            section: nil,
            bodyText: "Familiarize with the MST UI."
        ),
        SetupAssistantStep(
            id: "betternbb",
            section: .nbb,
            bodyText: "BetterNBB: Turn on the Ninjabrainbot API from Ninjabrainbot settings and set your overlay position with Place Overlay Template, and then tune Window Style to your preference."
        ),
        SetupAssistantStep(
            id: "windowbackdrop",
            section: .backdrop,
            bodyText: "WindowBackdrop: choose a background color or pick an image in the Backdrop section. If you use an image, check the fit mode before starting."
        ),
        SetupAssistantStep(
            id: "better-piechart",
            section: .piechart,
            bodyText: "Better Piechart: toggle your Thin mode, click Import Thin Setup, refresh Minecraft windows, choose the instance, then start the projector."
        ),
        SetupAssistantStep(
            id: "macrosshair",
            section: .crosshair,
            bodyText: "MACrosshair: set a keybind for showing and hiding the crosshair, then adjust its color, shape, and offset if needed."
        ),
        SetupAssistantStep(
            id: "key-rebinder",
            section: .keyRebinder,
            bodyText: "Key Rebinder: connect Karabiner, choose a Karabiner profile, then edit the same simple modification rows Karabiner shows.",
            warningText: "You MUST turn on Modify events for your device in Karabiner or Karabiner will ignore the remaps MST writes.",
            imageName: "key-rebinder-karabiner-modify-events"
        )
    ]

    var currentStep: SetupAssistantStep {
        steps[min(stepIndex, steps.count - 1)]
    }

    var isLastStep: Bool {
        stepIndex >= steps.count - 1
    }

    init(defaults: UserDefaults = .standard) {
        isPresented = !defaults.bool(forKey: Self.completedKey)
    }

    func resetAndShow() {
        UserDefaults.standard.removeObject(forKey: Self.completedKey)
        UserDefaults.standard.synchronize()
        stepIndex = 0
        isPresented = true
    }

    func advance() -> ToolSection? {
        guard !isLastStep else {
            complete()
            return nil
        }

        stepIndex += 1
        return currentStep.section
    }

    func skipAll() {
        complete()
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.synchronize()
        isPresented = false
    }
}

struct SetupAssistantPopup: View {
    let step: SetupAssistantStep
    let nextAction: () -> Void
    let skipAction: () -> Void
    let skipAllAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Get started")
                    .font(.system(size: 17, weight: .black))
                Spacer()
                if let section = step.section {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.system(size: 11, weight: .bold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            }

            Text(step.bodyText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            if let warningText = step.warningText {
                Text(warningText)
                    .font(.system(size: 13, weight: .black))
                    .underline()
                    .foregroundStyle(Color.red)
                    .modifier(MSTPreserveSemanticColor())
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let imageName = step.imageName,
               let image = setupImage(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.22), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Button("Next", action: nextAction)
                    .buttonStyle(SetupAssistantPrimaryButtonStyle())

                Button("Skip", action: skipAction)
                    .buttonStyle(SetupAssistantSecondaryButtonStyle())

                Button("Skip all", action: skipAllAction)
                    .buttonStyle(SetupAssistantSecondaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.42), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func setupImage(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: name)
    }
}

struct SetupAssistantPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(Color.white)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct SetupAssistantSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .foregroundStyle(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.38), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct MSTSettingsView: View {
    private static let contentSize = CGSize(width: 380, height: 244)

    @ObservedObject var settings: AppSettingsController
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Settings")

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Appearance".uppercased())
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(MSTAppearanceMode.allCases) { mode in
                            Button {
                                settings.appearanceMode = mode
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 12, weight: .black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(settings.appearanceMode == mode ? Color.white : Color.black)
                                    .foregroundStyle(settings.appearanceMode == mode ? Color.black : Color.white)
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.42), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Label("Open on launch", systemImage: "power")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Toggle("", isOn: $settings.openOnLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Button {
                    settings.restartWalkthrough()
                } label: {
                    Label("Walkthrough", systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryMonoButtonStyle(active: false))
            }

            Spacer(minLength: 10)

            Text("Credits: Developed by ducky8x.")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(Color.black)
        .foregroundStyle(Color.white)
        .tint(.white)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(SettingsWindowSizer(size: Self.contentSize))
        .modifier(MSTColorInvertModifier(enabled: settings.appearanceMode.shouldInvert(systemColorScheme: systemColorScheme)))
    }
}

struct SettingsWindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        let nsSize = NSSize(width: size.width, height: size.height)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: nsSize)).size
        window.maxSize = window.minSize
        window.setContentSize(nsSize)
        window.styleMask.remove(.resizable)
    }
}

struct ComplexModeView: View {
    @EnvironmentObject private var hub: ToolHub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.16))
            mainContent
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MST")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.top, 18)

            ForEach(ToolSection.allCases) { section in
                Button {
                    hub.selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 20)
                        Text(section.rawValue)
                        Spacer()
                        if section != .overview && section != .keyRebinder {
                            Circle()
                                .fill(hub.isEnabled(section) ? Color.white : Color.clear)
                                .stroke(Color.white.opacity(0.65), lineWidth: 1)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(hub.selection == section ? Color.white : Color.clear)
                    .foregroundStyle(hub.selection == section ? Color.black : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    hub.simpleMode = true
                } label: {
                    Label("Simple", systemImage: "rectangle.grid.2x2")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4)))
                }
                .buttonStyle(.plain)

                Button {
                    openWindow(id: "mst-settings")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
        }
        .frame(width: 230)
        .background(Color.black)
    }

    @ViewBuilder
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch hub.selection {
                case .overview:
                    OverviewView()
                case .nbb:
                    BetterNBBSettingsView(controller: hub.nbb)
                case .backdrop:
                    WindowBackdropSettingsView(state: hub.backdrop)
                case .piechart:
                    BetterPiechartToolView(state: hub.piechart)
                case .crosshair:
                    MacrosshairSettingsView(controller: hub.crosshair)
                case .keyRebinder:
                    KeyRebinderSettingsView(controller: hub.keyRebinder)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }
}

struct SimpleModeView: View {
    @EnvironmentObject private var hub: ToolHub

    private let buttons: [ToolSection] = [.nbb, .backdrop, .piechart, .crosshair, .keyRebinder, .overview]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 2)

    var body: some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(buttons) { section in
                    Button {
                        if section == .overview {
                            hub.simpleMode = false
                            hub.selection = .overview
                        } else {
                            hub.toggle(section)
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            if section == .keyRebinder {
                                Text(keyRebinderPresetTag)
                                    .font(.system(size: 10, weight: .black))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.62)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 7)
                                    .foregroundStyle(Color.black)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(10)
                            }

                            VStack(spacing: 10) {
                                Image(systemName: section == .overview ? "arrow.up.left.and.arrow.down.right" : section.icon)
                                    .font(.system(size: 28, weight: .semibold))
                                Text(section == .overview ? "Complex Mode" : section.rawValue)
                                    .font(.system(size: 15, weight: .bold))
                                Text(simpleModeStatus(for: section))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 136)
                        }
                        .background(simpleModeBackground(for: section))
                        .foregroundStyle(simpleModeForeground(for: section))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

            }
            .frame(maxWidth: 620)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyRebinderPresetTag: String {
        hub.keyRebinder.currentKarabinerProfileName.isEmpty ? "NO PRESET" : hub.keyRebinder.currentKarabinerProfileName
    }

    private func simpleModeStatus(for section: ToolSection) -> String {
        if section == .overview { return "Expand" }
        if section == .keyRebinder { return "Click to cycle" }
        return hub.isEnabled(section) ? "On" : "Off"
    }

    private func simpleModeBackground(for section: ToolSection) -> Color {
        if section == .keyRebinder || section == .overview { return .black }
        return hub.isEnabled(section) ? .white : .black
    }

    private func simpleModeForeground(for section: ToolSection) -> Color {
        if section == .keyRebinder || section == .overview { return .white }
        return hub.isEnabled(section) ? .black : .white
    }
}

struct OverviewView: View {
    @EnvironmentObject private var hub: ToolHub

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Overview")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(ToolSection.allCases.filter { $0 != .overview }) { section in
                    ToolCard(
                        section: section,
                        isOn: hub.isEnabled(section),
                        statusText: statusText(for: section),
                        buttonTitle: buttonTitle(for: section)
                    ) {
                        hub.toggle(section)
                    }
                }
            }
        }
    }

    private func statusText(for section: ToolSection) -> String {
        if section == .keyRebinder {
            return hub.keyRebinder.currentKarabinerProfileName.isEmpty
                ? "NO PRESET"
                : hub.keyRebinder.currentKarabinerProfileName
        }
        return hub.isEnabled(section) ? "ON" : "OFF"
    }

    private func buttonTitle(for section: ToolSection) -> String {
        section == .keyRebinder ? "Next Preset" : hub.isEnabled(section) ? "Turn Off" : "Turn On"
    }
}

struct ToolCard: View {
    let section: ToolSection
    let isOn: Bool
    let statusText: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Text(statusText)
                    .font(.system(size: 11, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Text(section.rawValue)
                .font(.system(size: 18, weight: .bold))
            if let description = section.description {
                Text(description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(buttonTitle, action: action)
                .buttonStyle(PrimaryMonoButtonStyle(active: isOn))
        }
        .padding(16)
        .frame(minHeight: 150)
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.55)))
    }
}

struct Header: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .black))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.28)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryMonoButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(active ? Color.black : Color.white)
            .foregroundStyle(active ? Color.white : Color.black)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
