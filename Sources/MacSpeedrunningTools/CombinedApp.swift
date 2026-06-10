import AppKit
import SwiftUI

@main
struct MacSpeedrunningToolsApp: App {
    @NSApplicationDelegateAdaptor(CombinedAppDelegate.self) private var appDelegate
    @StateObject private var hub = ToolHub()

    var body: some Scene {
        WindowGroup("Mac Speedrunning Tools") {
            RootView()
                .environmentObject(hub)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class CombinedAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum ToolSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case nbb = "BetterNBB"
    case backdrop = "WindowBackdrop"
    case piechart = "Better Piechart"
    case crosshair = "MACrosshair"

    var id: Self { self }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .nbb: "map"
        case .backdrop: "macwindow"
        case .piechart: "chart.pie"
        case .crosshair: "scope"
        }
    }
}

@MainActor
final class ToolHub: ObservableObject {
    @Published var selection: ToolSection = .overview
    @Published var simpleMode = false

    @Published var nbb = BetterNBBToolController()
    @Published var backdrop = WindowBackdropState()
    @Published var piechart = PiechartState()
    @Published var crosshair = MacrosshairController()

    func isEnabled(_ section: ToolSection) -> Bool {
        switch section {
        case .overview: true
        case .nbb: nbb.isEnabled
        case .backdrop: backdrop.isBackdropEnabled
        case .piechart: piechart.isLive
        case .crosshair: crosshair.isVisible
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
            piechart.toggleLive()
        case .crosshair:
            crosshair.toggle()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var hub: ToolHub

    var body: some View {
        Group {
            if hub.simpleMode {
                SimpleModeView()
            } else {
                ComplexModeView()
            }
        }
        .background(Color.black)
        .foregroundStyle(Color.white)
        .tint(.white)
    }
}

struct ComplexModeView: View {
    @EnvironmentObject private var hub: ToolHub

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.16))
            mainContent
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Speedrunning Tools")
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
                        if section != .overview {
                            Circle()
                                .fill(hub.isEnabled(section) ? Color.white : Color.clear)
                                .stroke(Color.white.opacity(0.65), lineWidth: 1)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                    .background(hub.selection == section ? Color.white : Color.clear)
                    .foregroundStyle(hub.selection == section ? Color.black : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Spacer()

            Button {
                hub.simpleMode = true
            } label: {
                Label("Simple Mode", systemImage: "rectangle.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4)))
            }
            .buttonStyle(.plain)
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

    private let buttons: [ToolSection] = [.nbb, .backdrop, .piechart, .crosshair, .overview]
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
                        VStack(spacing: 10) {
                            Image(systemName: section == .overview ? "arrow.up.left.and.arrow.down.right" : section.icon)
                                .font(.system(size: 28, weight: .semibold))
                            Text(section == .overview ? "Complex Mode" : section.rawValue)
                                .font(.system(size: 15, weight: .bold))
                            Text(section == .overview ? "Expand" : hub.isEnabled(section) ? "On" : "Off")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 136)
                        .background(section != .overview && hub.isEnabled(section) ? Color.white : Color.black)
                        .foregroundStyle(section != .overview && hub.isEnabled(section) ? Color.black : Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    hub.simpleMode = false
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 28, weight: .semibold))
                        Text("All Settings")
                            .font(.system(size: 15, weight: .bold))
                        Text("Open")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 136)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 620)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverviewView: View {
    @EnvironmentObject private var hub: ToolHub

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Overview", subtitle: "Four speedrunning utilities in one black-and-white control surface.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(ToolSection.allCases.filter { $0 != .overview }) { section in
                    ToolCard(section: section, isOn: hub.isEnabled(section)) {
                        hub.toggle(section)
                    }
                }
            }
        }
    }
}

struct ToolCard: View {
    let section: ToolSection
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: section.icon)
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 11, weight: .black))
            }
            Text(section.rawValue)
                .font(.system(size: 18, weight: .bold))
            Button(isOn ? "Turn Off" : "Turn On", action: action)
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
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .black))
            Text(subtitle)
                .foregroundStyle(.secondary)
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
