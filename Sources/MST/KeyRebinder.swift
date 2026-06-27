import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import SwiftUI

enum RebindEndpointKind: String, Codable, CaseIterable, Identifiable {
    case keyboard
    case mouse

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct RebindEndpoint: Codable, Equatable, Identifiable, Hashable {
    var kind: RebindEndpointKind
    var code: String
    var label: String
    var modifiers: [String]? = nil

    var id: String {
        let modifierSuffix = (modifiers ?? []).isEmpty ? "" : ":\((modifiers ?? []).joined(separator: "+"))"
        return "\(kind.rawValue):\(code)\(modifierSuffix)"
    }
}

struct RebindMapping: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: RebindEndpoint
    var to: RebindEndpoint

    var warning: String? {
        guard from.kind == .keyboard, to.kind == .mouse else { return nil }
        return "Keyboard-to-mouse remaps do not key-repeat while held."
    }
}

struct RebindDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var vendorID: Int?
    var productID: Int?
    var isKeyboard: Bool
    var isMouse: Bool

    var typeLabel: String {
        switch (isKeyboard, isMouse) {
        case (true, true): "Keyboard + Mouse"
        case (true, false): "Keyboard"
        case (false, true): "Mouse"
        default: "HID"
        }
    }
}

struct RebindPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled: Bool
    var selectedDeviceID: String?
    var deviceName: String?
    var vendorID: Int?
    var productID: Int?
    var selectedDeviceIsKeyboard: Bool?
    var selectedDeviceIsMouse: Bool?
    var mappings: [RebindMapping]
    var shortcut: ToolShortcut?
}

struct KarabinerProfileSummary: Identifiable, Equatable {
    var name: String
    var isCurrent: Bool

    var id: String { name }
}

struct KarabinerSimpleModificationGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var vendorID: Int?
    var productID: Int?
    var isKeyboard: Bool
    var isMouse: Bool
    var mappings: [RebindMapping]
    var grabbedMappings: [RebindMapping]

    var isAllKeyboardsScope: Bool {
        isKeyboard && !isMouse && vendorID == nil && productID == nil
    }
}

private struct KarabinerCLIConnectedDevice: Decodable {
    var deviceID: UInt64?
    var identifiers: KarabinerCLIDeviceIdentifiers
    var manufacturer: String?
    var product: String?
    var isApple: Bool?
    var isBuiltInKeyboard: Bool?
    var isBuiltInPointingDevice: Bool?
    var locationID: UInt64?
    var transport: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case identifiers = "device_identifiers"
        case manufacturer
        case product
        case isApple = "is_apple"
        case isBuiltInKeyboard = "is_built_in_keyboard"
        case isBuiltInPointingDevice = "is_built_in_pointing_device"
        case locationID = "location_id"
        case transport
    }
}

private struct KarabinerCLIDeviceIdentifiers: Decodable {
    var vendorID: Int?
    var productID: Int?
    var isKeyboard: Bool?
    var isPointingDevice: Bool?
    var isVirtualDevice: Bool?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id"
        case productID = "product_id"
        case isKeyboard = "is_keyboard"
        case isPointingDevice = "is_pointing_device"
        case isVirtualDevice = "is_virtual_device"
    }
}

struct KarabinerConnectionStatus: Equatable {
    var appURL: URL?
    var isConsoleUserServerRunning: Bool
    var isCoreServiceRunning: Bool
    var isVirtualHIDDaemonRunning: Bool
    var configExists: Bool

    var isInstalled: Bool { appURL != nil }
    var isConnected: Bool {
        isInstalled && isConsoleUserServerRunning && isCoreServiceRunning && isVirtualHIDDaemonRunning
    }

    var title: String {
        if isConnected { return "Karabiner connected" }
        if isInstalled { return "Karabiner needs setup" }
        return "Karabiner not installed"
    }

    var detail: String {
        if isConnected {
            return "MST is reading and writing Karabiner profiles and simple modifications."
        }
        if isInstalled {
            return "Open Karabiner-Elements and finish its permissions/driver setup, then refresh this panel."
        }
        return "Install Karabiner-Elements before enabling rebinding presets."
    }
}

private struct KeyRebinderPersistedState: Codable {
    var presets: [RebindPreset]
    var selectedPresetID: UUID?
    var showAdvancedScopes: Bool?
    var profileShortcuts: [String: ToolShortcut]?
}

@MainActor
final class KeyRebinderController: ObservableObject {
    private typealias CGCursorIsVisibleFunction = @convention(c) () -> Int32

    private static let settingsKey = "macSpeedrunningTools.keyRebinder.settings.v1"
    private static let generatedRulePrefix = "MST Key Rebinder:"
    private static let grabbedLayerRulePrefix = "MST Key Rebinder Grabbed Layer:"
    private static let grabbedLayerVariableName = "mst_cursor_grabbed"
    private static let coreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    private static let cursorVisibilityFunction: CGCursorIsVisibleFunction? = {
        guard let coreGraphicsHandle,
              let symbol = dlsym(coreGraphicsHandle, "CGCursorIsVisible")
        else { return nil }
        return unsafeBitCast(symbol, to: CGCursorIsVisibleFunction.self)
    }()

    @Published var presets: [RebindPreset] = []
    @Published var selectedPresetID: UUID?
    @Published var detectedDevices: [RebindDevice] = []
    @Published var selectedSource: RebindEndpoint?
    @Published var recordingPresetID: UUID?
    @Published var recordingProfileName: String?
    @Published var profileShortcuts: [String: ToolShortcut] = [:]
    @Published private(set) var needsAccessibilityPermission = false
    @Published private(set) var karabinerStatus = KarabinerConnectionStatus(
        appURL: nil,
        isConsoleUserServerRunning: false,
        isCoreServiceRunning: false,
        isVirtualHIDDaemonRunning: false,
        configExists: false
    )
    @Published var karabinerProfiles: [KarabinerProfileSummary] = []
    @Published var karabinerSimpleGroups: [KarabinerSimpleModificationGroup] = []
    @Published var selectedKarabinerGroupID: String?
    @Published var currentKarabinerProfileName = ""
    @Published var showAdvancedScopes = false {
        didSet {
            save()
            ensureVisibleKarabinerGroupSelection()
        }
    }
    @Published var status = "Rebinds updated"
    @Published var lastAppliedSummary = "No direct Karabiner changes have been made from MST yet."

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var karabinerPollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastTriggerTimes: [UUID: CFAbsoluteTime] = [:]
    private var lastProfileTriggerTimes: [String: CFAbsoluteTime] = [:]
    private var lastObservedKarabinerModificationDate: Date?
    private var lastObservedKarabinerProfileName: String?
    private var karabinerPollCount = 0
    private var cursorGrabPollTimer: Timer?
    private var lastPublishedCursorGrabbed: Bool?
    private var cursorGrabLikely = false
    private var lastMouseEventLocation: CGPoint?
    private var pinnedHiddenMouseMoveCount = 0

    var isEnabled: Bool { presets.contains { $0.isEnabled } }

    var selectedPreset: RebindPreset? {
        guard let selectedPresetID else { return nil }
        return presets.first { $0.id == selectedPresetID }
    }

    var selectedDevice: RebindDevice? {
        guard let id = selectedPreset?.selectedDeviceID else { return nil }
        return detectedDevices.first { $0.id == id }
    }

    var selectedKarabinerGroup: KarabinerSimpleModificationGroup? {
        if let selectedKarabinerGroupID,
           let group = visibleKarabinerGroups.first(where: { $0.id == selectedKarabinerGroupID }) {
            return group
        }
        return visibleKarabinerGroups.first
    }

    var visibleKarabinerGroups: [KarabinerSimpleModificationGroup] {
        let groups = karabinerSimpleGroups.filter { !$0.isAllKeyboardsScope }
        guard !showAdvancedScopes else { return groups }
        return groups.filter { group in
            group.id.hasSuffix(":profile") || (group.vendorID == nil && group.productID == nil)
        }
    }

    init() {
        load()
        refreshDevices()
        refreshKarabinerStatus()
        refreshKarabinerConfiguration()
        installMonitors()
        installEventTap()
        startKarabinerPolling()
        startCursorGrabPolling()
    }

    func toggleSelectedPreset() {
        guard let id = selectedPresetID else { return }
        guard karabinerStatus.isConnected else {
            status = "Karabiner is not connected yet. Finish the setup checklist first."
            return
        }
        updatePreset(id) { $0.isEnabled.toggle() }
        applyKarabinerConfiguration()
    }

    func addPreset() {
        let nextNumber = presets.count + 1
        let preset = RebindPreset(
            name: "Preset \(nextNumber)",
            isEnabled: false,
            selectedDeviceID: nil,
            deviceName: nil,
            vendorID: nil,
            productID: nil,
            selectedDeviceIsKeyboard: nil,
            selectedDeviceIsMouse: nil,
            mappings: [],
            shortcut: nil
        )
        presets.append(preset)
        selectedPresetID = preset.id
        save()
    }

    func deleteSelectedPreset() {
        guard presets.count > 1, let id = selectedPresetID else { return }
        presets.removeAll { $0.id == id }
        selectedPresetID = presets.first?.id
        selectedSource = nil
        save()
        applyKarabinerConfiguration()
    }

    func renameSelectedPreset(_ name: String) {
        guard let id = selectedPresetID else { return }
        updatePreset(id) { $0.name = name.isEmpty ? "Untitled Preset" : name }
    }

    func selectPreset(_ id: UUID) {
        selectedPresetID = id
        selectedSource = nil
        save()
    }

    func selectDevice(_ device: RebindDevice) {
        guard let id = selectedPresetID else { return }
        updatePreset(id) { preset in
            preset.selectedDeviceID = device.id
            preset.deviceName = device.name
            preset.vendorID = device.vendorID
            preset.productID = device.productID
            preset.selectedDeviceIsKeyboard = device.isKeyboard
            preset.selectedDeviceIsMouse = device.isMouse
        }
    }

    func chooseSource(_ endpoint: RebindEndpoint) {
        selectedSource = endpoint
        status = "Selected \(endpoint.label). Choose a replacement below."
    }

    func mapSelectedSource(to target: RebindEndpoint) {
        guard let presetID = selectedPresetID, let selectedSource else { return }
        updatePreset(presetID) { preset in
            preset.mappings.removeAll { $0.from == selectedSource }
            if selectedSource != target {
                preset.mappings.append(RebindMapping(from: selectedSource, to: target))
            }
        }
        status = "\(selectedSource.label) now maps to \(target.label)."
        applyKarabinerConfiguration()
    }

    func removeMapping(_ mapping: RebindMapping) {
        guard let presetID = selectedPresetID else { return }
        updatePreset(presetID) { preset in
            preset.mappings.removeAll { $0.id == mapping.id }
        }
        applyKarabinerConfiguration()
    }

    func beginRecordingShortcut(for presetID: UUID) {
        recordingPresetID = presetID
    }

    func clearShortcut(for presetID: UUID) {
        updatePreset(presetID) { $0.shortcut = nil }
    }

    func refreshDevices() {
        if let karabinerDevices = connectedKarabinerDevices(), !karabinerDevices.isEmpty {
            detectedDevices = Self.genericDevices + karabinerDevices
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
            ],
            [
                kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            detectedDevices = []
            return
        }

        var merged: [String: RebindDevice] = [:]
        for device in devices {
            let vendorID = intProperty(kIOHIDVendorIDKey, from: device)
            let productID = intProperty(kIOHIDProductIDKey, from: device)
            let usage = intProperty(kIOHIDPrimaryUsageKey, from: device)
            let product = stringProperty(kIOHIDProductKey, from: device)
            let manufacturer = stringProperty(kIOHIDManufacturerKey, from: device)
            let name = [manufacturer, product].compactMap { $0 }.joined(separator: " ")
            let fallbackName = product ?? manufacturer ?? "Unknown HID Device"
            let id = "\(vendorID ?? -1):\(productID ?? -1):\(name.isEmpty ? fallbackName : name)"
            var existing = merged[id] ?? RebindDevice(
                id: id,
                name: name.isEmpty ? fallbackName : name,
                vendorID: vendorID,
                productID: productID,
                isKeyboard: false,
                isMouse: false
            )
            if usage == kHIDUsage_GD_Keyboard { existing.isKeyboard = true }
            if usage == kHIDUsage_GD_Mouse { existing.isMouse = true }
            merged[id] = existing
        }

        detectedDevices = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let genericDevices = [
        RebindDevice(
            id: "karabiner:any-mouse",
            name: "All Pointing Devices",
            vendorID: nil,
            productID: nil,
            isKeyboard: false,
            isMouse: true
        )
    ]

    func refreshKarabinerStatus() {
        let fileManager = FileManager.default
        let appURLs = [
            URL(fileURLWithPath: "/Applications/Karabiner-Elements.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Karabiner-Elements.app")
        ]
        let appURL = appURLs.first { fileManager.fileExists(atPath: $0.path) }
        karabinerStatus = KarabinerConnectionStatus(
            appURL: appURL,
            isConsoleUserServerRunning: processIsRunning("karabiner_console_user_server"),
            isCoreServiceRunning: processIsRunning("Karabiner-Core-Service"),
            isVirtualHIDDaemonRunning: processIsRunning("Karabiner-VirtualHIDDevice-Daemon"),
            configExists: fileManager.fileExists(atPath: KarabinerConfigurationWriter.configURL.path)
        )
        refreshKarabinerConfiguration()
    }

    func refreshKarabinerConfiguration() {
        do {
            let state = try Self.readKarabinerConfigurationState()
            currentKarabinerProfileName = state.currentProfileName
            karabinerProfiles = state.profiles
            karabinerSimpleGroups = state.groups
            rememberObservedKarabinerState(profileName: state.currentProfileName)
            ensureVisibleKarabinerGroupSelection()
        } catch {
            karabinerProfiles = []
            karabinerSimpleGroups = []
            selectedKarabinerGroupID = nil
            rememberObservedKarabinerState(profileName: nil)
        }
    }

    func selectKarabinerProfile(_ name: String) {
        let cliURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        guard FileManager.default.fileExists(atPath: cliURL.path) else {
            status = "Karabiner CLI was not found."
            return
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--select-profile", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                status = "Rebinds updated"
            } else {
                status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
            }
            selectedKarabinerGroupID = nil
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func cycleKarabinerProfile() {
        refreshKarabinerConfiguration()
        guard !karabinerProfiles.isEmpty else {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
            return
        }
        let currentIndex = karabinerProfiles.firstIndex { $0.isCurrent } ?? 0
        let nextIndex = karabinerProfiles.index(after: currentIndex) == karabinerProfiles.endIndex
            ? karabinerProfiles.startIndex
            : karabinerProfiles.index(after: currentIndex)
        selectKarabinerProfile(karabinerProfiles[nextIndex].name)
    }

    func addKarabinerProfile() {
        do {
            var root = try Self.loadKarabinerRoot()
            var profiles = root["profiles"] as? [[String: Any]] ?? []
            let existingNames = Set(profiles.compactMap { $0["name"] as? String })
            var number = profiles.count + 1
            var name = "Untitled Preset"
            while existingNames.contains(name) {
                number += 1
                name = "Untitled Preset \(number)"
            }

            for index in profiles.indices {
                profiles[index]["selected"] = false
            }
            profiles.append([
                "name": name,
                "selected": true,
                "complex_modifications": ["rules": []],
                "devices": [],
                "virtual_hid_keyboard": ["keyboard_type_v2": "ansi"]
            ])
            root["profiles"] = profiles
            try Self.writeKarabinerRoot(root)
            selectKarabinerProfile(name)
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func renameKarabinerProfile(from oldName: String, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != oldName else { return }

        do {
            var root = try Self.loadKarabinerRoot()
            var profiles = root["profiles"] as? [[String: Any]] ?? []
            guard let index = profiles.firstIndex(where: { ($0["name"] as? String) == oldName }) else {
                status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
                return
            }
            guard !profiles.contains(where: { ($0["name"] as? String) == trimmedName }) else {
                status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
                return
            }

            profiles[index]["name"] = trimmedName
            root["profiles"] = profiles
            try Self.writeKarabinerRoot(root)

            if let shortcut = profileShortcuts.removeValue(forKey: oldName) {
                profileShortcuts[trimmedName] = shortcut
                save()
            }

            if currentKarabinerProfileName == oldName || karabinerProfiles.first(where: { $0.name == oldName })?.isCurrent == true {
                selectKarabinerProfile(trimmedName)
            } else {
                status = "Rebinds updated"
                refreshKarabinerConfiguration()
            }
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func beginRecordingProfileShortcut(_ profileName: String) {
        recordingProfileName = profileName
    }

    func clearProfileShortcut(_ profileName: String) {
        profileShortcuts[profileName] = nil
        save()
    }

    func selectKarabinerGroup(_ id: String) {
        selectedKarabinerGroupID = id
    }

    func toggleAdvancedScopes() {
        showAdvancedScopes.toggle()
    }

    func addKarabinerSimpleModification() {
        guard let group = selectedKarabinerGroup else { return }
        let from = group.isMouse && !group.isKeyboard
            ? KeyRebinderLibrary.mouse[0]
            : KeyRebinderLibrary.keyboard.first(where: { $0.code == "caps_lock" }) ?? KeyRebinderLibrary.keyboard[0]
        let to = KeyRebinderLibrary.keyboard.first(where: { $0.code == "escape" }) ?? KeyRebinderLibrary.keyboard[0]
        do {
            try mutateKarabinerSimpleModifications(groupID: group.id) { modifications in
                modifications.append(Self.simpleModification(from: from, to: to))
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func updateKarabinerSimpleModification(groupID: String, index: Int, from: RebindEndpoint? = nil, to: RebindEndpoint? = nil) {
        do {
            try mutateKarabinerSimpleModifications(groupID: groupID) { modifications in
                guard modifications.indices.contains(index) else { return }
                var modification = modifications[index]
                if let from {
                    modification["from"] = Self.simpleFromObject(from)
                }
                if let to {
                    modification["to"] = [Self.toObject(to)]
                }
                modifications[index] = modification
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func setKarabinerSimpleModification(groupID: String, from: RebindEndpoint, to: RebindEndpoint) {
        do {
            try mutateKarabinerSimpleModifications(groupID: groupID) { modifications in
                let fromObject = Self.simpleFromObject(from)
                if from == to {
                    modifications.removeAll { modification in
                        NSDictionary(dictionary: modification["from"] as? [String: Any] ?? [:]).isEqual(to: fromObject)
                    }
                    return
                }

                let nextModification = Self.simpleModification(from: from, to: to)
                if let index = modifications.firstIndex(where: { modification in
                    NSDictionary(dictionary: modification["from"] as? [String: Any] ?? [:]).isEqual(to: fromObject)
                }) {
                    modifications[index] = nextModification
                } else {
                    modifications.append(nextModification)
                }
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func setKarabinerGrabbedModification(groupID: String, from: RebindEndpoint, to: RebindEndpoint) {
        do {
            try mutateKarabinerGrabbedModifications(groupID: groupID) { mappings in
                mappings.removeAll { $0.from == from }
                if from != to {
                    mappings.append(RebindMapping(from: from, to: to))
                }
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func deleteKarabinerGrabbedModification(groupID: String, from: RebindEndpoint) {
        do {
            try mutateKarabinerGrabbedModifications(groupID: groupID) { mappings in
                mappings.removeAll { $0.from == from }
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func deleteKarabinerSimpleModification(groupID: String, index: Int) {
        do {
            try mutateKarabinerSimpleModifications(groupID: groupID) { modifications in
                guard modifications.indices.contains(index) else { return }
                modifications.remove(at: index)
            }
            status = "Rebinds updated"
            refreshKarabinerConfiguration()
        } catch {
            status = "Rebinds failed to update. Check your connection with Karabiner Elements and try again."
        }
    }

    func importKarabinerGroupAsPreset(_ group: KarabinerSimpleModificationGroup) {
        let preset = RebindPreset(
            name: "Karabiner: \(group.title)",
            isEnabled: false,
            selectedDeviceID: nil,
            deviceName: group.title,
            vendorID: group.vendorID,
            productID: group.productID,
            selectedDeviceIsKeyboard: group.isKeyboard,
            selectedDeviceIsMouse: group.isMouse,
            mappings: group.mappings,
            shortcut: nil
        )
        presets.append(preset)
        selectedPresetID = preset.id
        save()
        status = "Imported \(group.title) as an MST preset."
    }

    func openKarabiner() {
        refreshKarabinerStatus()
        if let appURL = karabinerStatus.appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://karabiner-elements.pqrs.org/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openKarabinerDownload() {
        if let url = URL(string: "https://karabiner-elements.pqrs.org/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealKarabinerConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([KarabinerConfigurationWriter.configURL])
    }

    private func startKarabinerPolling() {
        karabinerPollTimer?.invalidate()
        karabinerPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollKarabinerChanges()
            }
        }
        if let karabinerPollTimer {
            RunLoop.main.add(karabinerPollTimer, forMode: .common)
        }
    }

    private func startCursorGrabPolling() {
        publishCursorGrabStateIfNeeded(force: true)
        cursorGrabPollTimer?.invalidate()
        cursorGrabPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishCursorGrabStateIfNeeded()
            }
        }
        if let cursorGrabPollTimer {
            RunLoop.main.add(cursorGrabPollTimer, forMode: .common)
        }
    }

    private func publishCursorGrabStateIfNeeded(force: Bool = false) {
        guard let isCursorVisible = Self.cursorIsVisible() else { return }
        if isCursorVisible {
            resetCursorGrabHeuristic()
        }
        let isCursorGrabbed = !isCursorVisible && cursorGrabLikely
        guard force || lastPublishedCursorGrabbed != isCursorGrabbed else { return }
        guard setKarabinerVariable(name: Self.grabbedLayerVariableName, value: isCursorGrabbed) else { return }
        lastPublishedCursorGrabbed = isCursorGrabbed
    }

    private func resetCursorGrabHeuristic() {
        cursorGrabLikely = false
        pinnedHiddenMouseMoveCount = 0
        lastMouseEventLocation = nil
    }

    private func observeMouseMotion(_ event: CGEvent) {
        guard let isCursorVisible = Self.cursorIsVisible() else { return }
        let location = event.location
        defer {
            lastMouseEventLocation = location
            publishCursorGrabStateIfNeeded()
        }

        guard !isCursorVisible else {
            resetCursorGrabHeuristic()
            return
        }

        let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        guard deltaX != 0 || deltaY != 0 else { return }

        guard let previousLocation = lastMouseEventLocation else { return }
        let distance = hypot(location.x - previousLocation.x, location.y - previousLocation.y)
        if distance <= 2.0 {
            pinnedHiddenMouseMoveCount += 1
            if pinnedHiddenMouseMoveCount >= 1 {
                cursorGrabLikely = true
            }
        } else {
            cursorGrabLikely = false
            pinnedHiddenMouseMoveCount = 0
        }
    }

    private static func cursorIsVisible() -> Bool? {
        cursorVisibilityFunction?() != 0
    }

    private func setKarabinerVariable(name: String, value: Bool) -> Bool {
        let cliURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        guard FileManager.default.fileExists(atPath: cliURL.path),
              let data = try? JSONSerialization.data(withJSONObject: [name: value]),
              let json = String(data: data, encoding: .utf8)
        else { return false }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--set-variables", json]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func pollKarabinerChanges() {
        karabinerPollCount += 1
        let fileManager = FileManager.default
        let configURL = KarabinerConfigurationWriter.configURL
        let modificationDate = (try? fileManager.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        let profileName = Self.currentKarabinerProfileName()

        let configChanged = modificationDate != lastObservedKarabinerModificationDate
        let profileChanged = profileName != lastObservedKarabinerProfileName
        if configChanged || profileChanged {
            refreshKarabinerConfiguration()
        }

        if karabinerPollCount.isMultiple(of: 5) {
            refreshKarabinerStatus()
        }
    }

    private func rememberObservedKarabinerState(profileName: String?) {
        lastObservedKarabinerProfileName = profileName
        let configURL = KarabinerConfigurationWriter.configURL
        lastObservedKarabinerModificationDate = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
    }

    private func ensureVisibleKarabinerGroupSelection() {
        if let selectedKarabinerGroupID,
           visibleKarabinerGroups.contains(where: { $0.id == selectedKarabinerGroupID }) {
            return
        }
        selectedKarabinerGroupID = visibleKarabinerGroups.first?.id
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let shouldPassEvent = MainActor.assumeIsolated {
                self.handle(event)
            }
            return shouldPassEvent ? event : nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                _ = self?.handle(event)
            }
        }
    }

    private func installEventTap() {
        let eventTypes: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = eventTypes.reduce(CGEventMask(0)) { result, eventType in
            result | CGEventMask(1 << eventType.rawValue)
        }
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userData in
                guard let userData else {
                    return Unmanaged.passUnretained(event)
                }
                let keyEvent = event.copy() ?? event
                Task { @MainActor in
                    let controller = Unmanaged<KeyRebinderController>.fromOpaque(userData).takeUnretainedValue()
                    if type == .keyDown {
                        controller.handle(keyEvent)
                    } else if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
                        controller.observeMouseMotion(keyEvent)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userData
        ) else {
            needsAccessibilityPermission = true
            promptForAccessibilityPermission()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        needsAccessibilityPermission = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        publishCursorGrabStateIfNeeded()

        if let recordingProfileName {
            guard !event.isARepeat else { return false }
            if let shortcut = ToolShortcut.from(event: event) {
                profileShortcuts[recordingProfileName] = shortcut
                self.recordingProfileName = nil
                save()
                status = "Rebinds updated"
            }
            return false
        }

        if let recordingPresetID {
            guard !event.isARepeat else { return false }
            if let shortcut = ToolShortcut.from(event: event) {
                updatePreset(recordingPresetID) { $0.shortcut = shortcut }
                self.recordingPresetID = nil
            }
            return false
        }

        guard !event.isARepeat else { return true }
        triggerProfile(matching: event)
        triggerPreset(matching: event)
        return true
    }

    private func handle(_ event: CGEvent) {
        publishCursorGrabStateIfNeeded()

        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        for (profileName, shortcut) in profileShortcuts where shortcut.matches(event) {
            triggerProfile(profileName)
        }
        for preset in presets where preset.shortcut?.matches(event) == true {
            triggerPreset(preset.id)
        }
    }

    private func triggerProfile(matching event: NSEvent) {
        for (profileName, shortcut) in profileShortcuts where shortcut.matches(event) {
            triggerProfile(profileName)
        }
    }

    private func triggerProfile(_ profileName: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastProfileTriggerTimes[profileName], now - last < 0.18 { return }
        lastProfileTriggerTimes[profileName] = now
        selectKarabinerProfile(profileName)
    }

    private func triggerPreset(matching event: NSEvent) {
        for preset in presets where preset.shortcut?.matches(event) == true {
            triggerPreset(preset.id)
        }
    }

    private func triggerPreset(_ presetID: UUID) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastTriggerTimes[presetID], now - last < 0.12 { return }
        lastTriggerTimes[presetID] = now
        updatePreset(presetID) { $0.isEnabled.toggle() }
        applyKarabinerConfiguration()
    }

    private func promptForAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func processIsRunning(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func connectedKarabinerDevices() -> [RebindDevice]? {
        let cliURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        guard FileManager.default.fileExists(atPath: cliURL.path) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = cliURL
        process.arguments = ["--list-connected-devices"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let cliDevices = try JSONDecoder().decode([KarabinerCLIConnectedDevice].self, from: data)
            return cliDevices.compactMap { device in
                guard device.identifiers.isVirtualDevice != true else { return nil }
                let isKeyboard = device.identifiers.isKeyboard == true
                let isMouse = device.identifiers.isPointingDevice == true
                guard isKeyboard || isMouse else { return nil }

                let product = device.product ?? "Unknown Device"
                let name = [device.manufacturer, product].compactMap { $0 }.joined(separator: " ")
                let idParts = [
                    device.deviceID.map { "device:\($0)" },
                    device.identifiers.vendorID.map { "vid:\($0)" },
                    device.identifiers.productID.map { "pid:\($0)" },
                    device.locationID.map { "loc:\($0)" },
                    isKeyboard ? "keyboard" : nil,
                    isMouse ? "mouse" : nil
                ].compactMap { $0 }

                return RebindDevice(
                    id: idParts.joined(separator: ":"),
                    name: name.isEmpty ? product : name,
                    vendorID: device.identifiers.vendorID,
                    productID: device.identifiers.productID,
                    isKeyboard: isKeyboard,
                    isMouse: isMouse
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            return nil
        }
    }

    private static func readKarabinerConfigurationState() throws -> (
        currentProfileName: String,
        profiles: [KarabinerProfileSummary],
        groups: [KarabinerSimpleModificationGroup]
    ) {
        let data = try Data(contentsOf: KarabinerConfigurationWriter.configURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return ("", [], [])
        }

        let profilesJSON = root["profiles"] as? [[String: Any]] ?? []
        let cliCurrent = currentKarabinerProfileName()
        let selectedProfileIndex = profilesJSON.firstIndex { profile in
            if let cliCurrent {
                return (profile["name"] as? String) == cliCurrent
            }
            return (profile["selected"] as? Bool) == true
        } ?? 0
        let currentProfile = profilesJSON.indices.contains(selectedProfileIndex) ? profilesJSON[selectedProfileIndex] : [:]
        let currentName = (currentProfile["name"] as? String) ?? cliCurrent ?? ""

        let profiles = profilesJSON.map { profile in
            let name = profile["name"] as? String ?? "Unnamed Profile"
            return KarabinerProfileSummary(name: name, isCurrent: name == currentName)
        }

        var groups: [KarabinerSimpleModificationGroup] = []
        let profileLevelMods = currentProfile["simple_modifications"] as? [[String: Any]] ?? []
        let grabbedMappingsByScope = grabbedLayerMappingsByScope(from: currentProfile)
        groups.append(KarabinerSimpleModificationGroup(
            id: "\(currentName):profile",
            title: "For all devices",
            detail: "\(profileLevelMods.count) modification\(profileLevelMods.count == 1 ? "" : "s")",
            vendorID: nil,
            productID: nil,
            isKeyboard: true,
            isMouse: true,
            mappings: mappings(from: profileLevelMods),
            grabbedMappings: grabbedMappingsByScope["profile"] ?? []
        ))

        let devices = currentProfile["devices"] as? [[String: Any]] ?? []
        for (index, device) in devices.enumerated() {
            let identifiers = device["identifiers"] as? [String: Any] ?? [:]
            let isKeyboard = identifiers["is_keyboard"] as? Bool == true
            let isMouse = identifiers["is_pointing_device"] as? Bool == true
            guard isKeyboard || isMouse else {
                continue
            }
            guard !isAllKeyboardsScope(identifiers: identifiers) else {
                continue
            }
            let mods = device["simple_modifications"] as? [[String: Any]] ?? []
            groups.append(KarabinerSimpleModificationGroup(
                id: "\(currentName):device:\(index)",
                title: deviceTitle(for: identifiers),
                detail: identifiersDescription(identifiers),
                vendorID: intValue(identifiers["vendor_id"]),
                productID: intValue(identifiers["product_id"]),
                isKeyboard: isKeyboard,
                isMouse: isMouse,
                mappings: mappings(from: mods),
                grabbedMappings: grabbedMappingsByScope[layerScopeKey(for: identifiers)] ?? []
            ))
        }

        return (currentName, profiles, groups)
    }

    private static func currentKarabinerProfileName() -> String? {
        let cliURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        guard FileManager.default.fileExists(atPath: cliURL.path) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = cliURL
        process.arguments = ["--show-current-profile-name"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        } catch {
            return nil
        }
    }

    private static func mappings(from simpleModifications: [[String: Any]]) -> [RebindMapping] {
        simpleModifications.compactMap { mod in
            guard let from = endpoint(from: mod["from"] as? [String: Any]),
                  let toArray = mod["to"] as? [[String: Any]],
                  let to = endpoint(from: toArray.first)
            else { return nil }
            return RebindMapping(from: from, to: to)
        }
    }

    private static func endpoint(from object: [String: Any]?) -> RebindEndpoint? {
        guard let object else { return nil }
        if let code = object["key_code"] as? String {
            let modifiers = normalizedOutputModifiers(from: object["modifiers"])
            if !modifiers.isEmpty,
               let endpoint = KeyRebinderLibrary.allKeyboardOutputs.first(where: { $0.code == code && normalizedModifiers($0.modifiers) == modifiers }) {
                return endpoint
            }
            return KeyRebinderLibrary.keyboard.first { $0.code == code } ?? RebindEndpoint(kind: .keyboard, code: code, label: code)
        }
        if let code = object["pointing_button"] as? String {
            return KeyRebinderLibrary.mouse.first { $0.code == code } ?? RebindEndpoint(kind: .mouse, code: code, label: code)
        }
        return nil
    }

    private static func normalizedOutputModifiers(from value: Any?) -> [String] {
        if let modifiers = value as? [String] {
            return normalizedModifiers(modifiers)
        }
        return []
    }

    private static func normalizedModifiers(_ modifiers: [String]?) -> [String] {
        (modifiers ?? []).sorted()
    }

    private static func deviceTitle(for identifiers: [String: Any]) -> String {
        if identifiers["is_pointing_device"] as? Bool == true,
           identifiers["vendor_id"] == nil,
           identifiers["product_id"] == nil {
            return "All Pointing Devices"
        }
        let type = identifiers["is_pointing_device"] as? Bool == true ? "Pointing Device" : "Keyboard"
        let vendor = identifiers["vendor_id"].map { "\($0)" } ?? "any"
        let product = identifiers["product_id"].map { "\($0)" } ?? "any"
        return "\(type) [VID: \(vendor), PID: \(product)]"
    }

    private static func isAllKeyboardsScope(identifiers: [String: Any]) -> Bool {
        identifiers["is_keyboard"] as? Bool == true &&
            identifiers["is_pointing_device"] as? Bool != true &&
            identifiers["vendor_id"] == nil &&
            identifiers["product_id"] == nil
    }

    private static func identifiersDescription(_ identifiers: [String: Any]) -> String {
        let parts = identifiers.keys.sorted().map { key in
            "\(key): \(identifiers[key] ?? "")"
        }
        return parts.joined(separator: ", ")
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func loadKarabinerRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: KarabinerConfigurationWriter.configURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func writeKarabinerRoot(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: KarabinerConfigurationWriter.configURL, options: .atomic)
    }

    private static func selectedKarabinerProfileIndex(in profiles: [[String: Any]]) -> Int {
        if let current = currentKarabinerProfileName(),
           let index = profiles.firstIndex(where: { ($0["name"] as? String) == current }) {
            return index
        }
        return profiles.firstIndex { ($0["selected"] as? Bool) == true } ?? 0
    }

    private func mutateKarabinerSimpleModifications(
        groupID: String,
        apply: (inout [[String: Any]]) -> Void
    ) throws {
        var root = try Self.loadKarabinerRoot()
        var profiles = root["profiles"] as? [[String: Any]] ?? []
        let profileIndex = Self.selectedKarabinerProfileIndex(in: profiles)
        guard profiles.indices.contains(profileIndex) else { return }
        var profile = profiles[profileIndex]

        if groupID.hasSuffix(":profile") {
            var modifications = profile["simple_modifications"] as? [[String: Any]] ?? []
            apply(&modifications)
            profile["simple_modifications"] = modifications
        } else if let deviceIndex = Self.deviceIndex(from: groupID) {
            var devices = profile["devices"] as? [[String: Any]] ?? []
            guard devices.indices.contains(deviceIndex) else { return }
            var device = devices[deviceIndex]
            var modifications = device["simple_modifications"] as? [[String: Any]] ?? []
            apply(&modifications)
            device["simple_modifications"] = modifications
            if modifications.contains(where: { ($0["from"] as? [String: Any])?["pointing_button"] != nil }) {
                device["ignore"] = false
            }
            devices[deviceIndex] = device
            profile["devices"] = devices
        }

        try Self.rebuildGrabbedLayerRule(for: groupID, in: &profile)
        profiles[profileIndex] = profile
        root["profiles"] = profiles
        try Self.writeKarabinerRoot(root)
    }

    private func mutateKarabinerGrabbedModifications(
        groupID: String,
        apply: (inout [RebindMapping]) -> Void
    ) throws {
        var root = try Self.loadKarabinerRoot()
        var profiles = root["profiles"] as? [[String: Any]] ?? []
        let profileIndex = Self.selectedKarabinerProfileIndex(in: profiles)
        guard profiles.indices.contains(profileIndex) else { return }
        var profile = profiles[profileIndex]

        let scope = try Self.grabbedLayerScope(for: groupID, in: profile)
        var mappings = Self.grabbedLayerMappingsByScope(from: profile)[scope.key] ?? []
        apply(&mappings)

        var complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        var rules = complex["rules"] as? [[String: Any]] ?? []
        let ruleDescription = Self.grabbedLayerRuleDescription(for: scope.key)
        rules.removeAll { ($0["description"] as? String) == ruleDescription }

        if !mappings.isEmpty {
            let simpleMappings = Self.simpleMappings(for: groupID, in: profile)
            rules.append(Self.grabbedLayerRule(
                description: ruleDescription,
                mappings: mappings,
                simpleMappings: simpleMappings,
                deviceIdentifiers: scope.deviceIdentifiers
            ))
        }

        complex["rules"] = rules
        profile["complex_modifications"] = complex
        profiles[profileIndex] = profile
        root["profiles"] = profiles
        try Self.writeKarabinerRoot(root)
    }

    private static func deviceIndex(from groupID: String) -> Int? {
        guard let range = groupID.range(of: ":device:", options: .backwards) else { return nil }
        return Int(groupID[range.upperBound...])
    }

    private static func grabbedLayerRuleDescription(for scopeKey: String) -> String {
        "\(grabbedLayerRulePrefix) \(scopeKey)"
    }

    private static func grabbedLayerScope(
        for groupID: String,
        in profile: [String: Any]
    ) throws -> (key: String, deviceIdentifiers: [String: Any]?) {
        if groupID.hasSuffix(":profile") {
            return ("profile", nil)
        }
        guard let deviceIndex = deviceIndex(from: groupID),
              let devices = profile["devices"] as? [[String: Any]],
              devices.indices.contains(deviceIndex)
        else {
            throw NSError(domain: "KeyRebinder", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected remap scope no longer exists."])
        }
        let identifiers = devices[deviceIndex]["identifiers"] as? [String: Any] ?? [:]
        return (layerScopeKey(for: identifiers), identifiers)
    }

    private static func simpleMappings(for groupID: String, in profile: [String: Any]) -> [RebindMapping] {
        if groupID.hasSuffix(":profile") {
            return mappings(from: profile["simple_modifications"] as? [[String: Any]] ?? [])
        }
        guard let deviceIndex = deviceIndex(from: groupID),
              let devices = profile["devices"] as? [[String: Any]],
              devices.indices.contains(deviceIndex)
        else { return [] }
        return mappings(from: devices[deviceIndex]["simple_modifications"] as? [[String: Any]] ?? [])
    }

    private static func grabbedLayerRule(
        description: String,
        mappings: [RebindMapping],
        simpleMappings: [RebindMapping],
        deviceIdentifiers: [String: Any]?
    ) -> [String: Any] {
        let manipulators = mappings.map { mapping in
            let effectiveSource = simpleMappings.first { $0.from == mapping.from }?.to ?? mapping.from
            var conditions: [[String: Any]] = [[
                "type": "variable_if",
                "name": grabbedLayerVariableName,
                "value": true
            ]]
            if let deviceIdentifiers {
                conditions.append([
                    "type": "device_if",
                    "identifiers": [deviceIdentifiers]
                ])
            }
            return [
                "type": "basic",
                "description": grabbedLayerManipulatorDescription(for: mapping.from),
                "from": complexFromObject(effectiveSource),
                "to": [toObject(mapping.to)],
                "conditions": conditions
            ]
        }
        return [
            "description": description,
            "manipulators": manipulators
        ]
    }

    private static func rebuildGrabbedLayerRule(for groupID: String, in profile: inout [String: Any]) throws {
        let scope = try grabbedLayerScope(for: groupID, in: profile)
        let mappings = grabbedLayerMappingsByScope(from: profile)[scope.key] ?? []
        guard !mappings.isEmpty else { return }

        var complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        var rules = complex["rules"] as? [[String: Any]] ?? []
        let ruleDescription = grabbedLayerRuleDescription(for: scope.key)
        rules.removeAll { ($0["description"] as? String) == ruleDescription }
        rules.append(grabbedLayerRule(
            description: ruleDescription,
            mappings: mappings,
            simpleMappings: simpleMappings(for: groupID, in: profile),
            deviceIdentifiers: scope.deviceIdentifiers
        ))
        complex["rules"] = rules
        profile["complex_modifications"] = complex
    }

    private static func grabbedLayerMappingsByScope(from profile: [String: Any]) -> [String: [RebindMapping]] {
        let complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        let rules = complex["rules"] as? [[String: Any]] ?? []
        return rules.reduce(into: [:]) { result, rule in
            guard let description = rule["description"] as? String,
                  description.hasPrefix(grabbedLayerRulePrefix)
            else { return }
            let scopeKey = description
                .dropFirst(grabbedLayerRulePrefix.count)
                .trimmingCharacters(in: .whitespaces)
            guard !scopeKey.isEmpty else { return }
            let manipulators = rule["manipulators"] as? [[String: Any]] ?? []
            let mappings = manipulators.compactMap(grabbedLayerMapping(from:))
            if !mappings.isEmpty {
                result[scopeKey] = mappings
            }
        }
    }

    private static func grabbedLayerMapping(from manipulator: [String: Any]) -> RebindMapping? {
        guard let toArray = manipulator["to"] as? [[String: Any]],
              let to = endpoint(from: toArray.first)
        else { return nil }
        let originalSource = (manipulator["description"] as? String)
            .flatMap(endpointFromGrabbedLayerManipulatorDescription)
        let source = originalSource ?? endpoint(from: manipulator["from"] as? [String: Any])
        guard let source else { return nil }
        return RebindMapping(from: source, to: to)
    }

    private static func grabbedLayerManipulatorDescription(for endpoint: RebindEndpoint) -> String {
        "source=\(endpoint.kind.rawValue):\(endpoint.code)"
    }

    private static func endpointFromGrabbedLayerManipulatorDescription(_ description: String) -> RebindEndpoint? {
        guard description.hasPrefix("source=") else { return nil }
        let value = description.dropFirst("source=".count)
        guard let separator = value.firstIndex(of: ":") else { return nil }
        let kindValue = String(value[..<separator])
        let code = String(value[value.index(after: separator)...])
        guard let kind = RebindEndpointKind(rawValue: kindValue) else { return nil }
        switch kind {
        case .keyboard:
            return KeyRebinderLibrary.keyboard.first { $0.code == code } ?? RebindEndpoint(kind: kind, code: code, label: code)
        case .mouse:
            return KeyRebinderLibrary.mouse.first { $0.code == code } ?? RebindEndpoint(kind: kind, code: code, label: code)
        }
    }

    private static func layerScopeKey(for identifiers: [String: Any]) -> String {
        let keys = ["vendor_id", "product_id", "is_keyboard", "is_pointing_device"]
        let parts = keys.compactMap { key -> String? in
            guard let value = identifiers[key] else { return nil }
            if let bool = value as? Bool { return "\(key)=\(bool)" }
            if let number = value as? NSNumber {
                if key.hasPrefix("is_") { return "\(key)=\(number.boolValue)" }
                return "\(key)=\(number.intValue)"
            }
            if let string = value as? String { return "\(key)=\(string)" }
            return nil
        }
        return "device:\(parts.joined(separator: ","))"
    }

    private static func simpleModification(from: RebindEndpoint, to: RebindEndpoint) -> [String: Any] {
        [
            "from": simpleFromObject(from),
            "to": [toObject(to)]
        ]
    }

    private static func simpleFromObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        switch endpoint.kind {
        case .keyboard:
            return ["key_code": endpoint.code]
        case .mouse:
            return ["pointing_button": endpoint.code]
        }
    }

    private static func complexFromObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        switch endpoint.kind {
        case .keyboard:
            return ["key_code": endpoint.code, "modifiers": ["optional": ["any"]]]
        case .mouse:
            return ["pointing_button": endpoint.code, "modifiers": ["optional": ["any"]]]
        }
    }

    private static func toObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        var object: [String: Any]
        switch endpoint.kind {
        case .keyboard:
            object = ["key_code": endpoint.code]
        case .mouse:
            object = ["pointing_button": endpoint.code]
        }
        if let modifiers = endpoint.modifiers, !modifiers.isEmpty {
            object["modifiers"] = modifiers
        }
        return object
    }

    private func updatePreset(_ id: UUID, apply: (inout RebindPreset) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        apply(&presets[index])
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let state = try? JSONDecoder().decode(KeyRebinderPersistedState.self, from: data) {
            presets = state.presets
            selectedPresetID = state.selectedPresetID ?? state.presets.first?.id
            showAdvancedScopes = state.showAdvancedScopes ?? false
            profileShortcuts = state.profileShortcuts ?? [:]
        }

        if presets.isEmpty {
            let preset = RebindPreset(
                name: "MacOS Preset",
                isEnabled: false,
                selectedDeviceID: nil,
                deviceName: nil,
                vendorID: nil,
                productID: nil,
                selectedDeviceIsKeyboard: nil,
                selectedDeviceIsMouse: nil,
                mappings: [],
                shortcut: nil
            )
            presets = [preset]
            selectedPresetID = preset.id
            save()
        }
    }

    private func save() {
        let state = KeyRebinderPersistedState(
            presets: presets,
            selectedPresetID: selectedPresetID,
            showAdvancedScopes: showAdvancedScopes,
            profileShortcuts: profileShortcuts
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
            UserDefaults.standard.synchronize()
        }
    }

    private func intProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    func applyKarabinerConfiguration() {
        refreshKarabinerStatus()
        guard karabinerStatus.isConnected else {
            status = "Karabiner is not connected. MST did not write any rules."
            return
        }
        do {
            let summary = try KarabinerConfigurationWriter.write(presets: presets, rulePrefix: Self.generatedRulePrefix)
            lastAppliedSummary = summary
            status = "Applied enabled presets to Karabiner."
            refreshKarabinerStatus()
            refreshKarabinerConfiguration()
        } catch {
            status = "Could not update Karabiner: \(error.localizedDescription)"
        }
    }
}

enum KeyRebinderLibrary {
    static let keyboard: [RebindEndpoint] = [
        key("escape", "Esc"), key("f1", "F1"), key("f2", "F2"), key("f3", "F3"), key("f4", "F4"), key("f5", "F5"), key("f6", "F6"), key("f7", "F7"), key("f8", "F8"), key("f9", "F9"), key("f10", "F10"), key("f11", "F11"), key("f12", "F12"),
        key("grave_accent_and_tilde", "~\n`"), key("1", "!\n1"), key("2", "@\n2"), key("3", "#\n3"), key("4", "$\n4"), key("5", "%\n5"), key("6", "^\n6"), key("7", "&\n7"), key("8", "*\n8"), key("9", "(\n9"), key("0", ")\n0"), key("hyphen", "_\n-"), key("equal_sign", "+\n="), key("delete_or_backspace", "Backspace"),
        key("tab", "Tab"), key("q", "Q"), key("w", "W"), key("e", "E"), key("r", "R"), key("t", "T"), key("y", "Y"), key("u", "U"), key("i", "I"), key("o", "O"), key("p", "P"), key("open_bracket", "{\n["), key("close_bracket", "}\n]"), key("backslash", "|\n\\"),
        key("caps_lock", "Caps Lock"), key("a", "A"), key("s", "S"), key("d", "D"), key("f", "F"), key("g", "G"), key("h", "H"), key("j", "J"), key("k", "K"), key("l", "L"), key("semicolon", ":\n;"), key("quote", "\"\n'"), key("return_or_enter", "Enter"),
        key("left_shift", "Shift"), key("z", "Z"), key("x", "X"), key("c", "C"), key("v", "V"), key("b", "B"), key("n", "N"), key("m", "M"), key("comma", "<\n,"), key("period", ">\n."), key("slash", "?\n/"), key("right_shift", "Shift"),
        key("left_control", "Ctrl"), key("left_option", "Opt"), key("left_command", "Cmd"), key("spacebar", "Space"), key("right_command", "Cmd"), key("right_option", "Opt"), key("right_control", "Ctrl"), key("application", "Menu"),
        key("print_screen", "PrtSc"), key("scroll_lock", "Scroll\nLock"), key("pause", "Pause\nBreak"),
        key("insert", "Insert"), key("home", "Home"), key("page_up", "PgUp"), key("delete_forward", "Delete"), key("end", "End"), key("page_down", "PgDn"),
        key("up_arrow", "↑"), key("left_arrow", "←"), key("down_arrow", "↓"), key("right_arrow", "→"),
        key("keypad_num_lock", "Num\nLock"), key("keypad_slash", "/"), key("keypad_asterisk", "*"), key("keypad_hyphen", "-"),
        key("keypad_7", "7\nHome"), key("keypad_8", "8\n↑"), key("keypad_9", "9\nPgUp"), key("keypad_plus", "+"),
        key("keypad_4", "4\n←"), key("keypad_5", "5"), key("keypad_6", "6\n→"),
        key("keypad_1", "1\nEnd"), key("keypad_2", "2\n↓"), key("keypad_3", "3\nPgDn"), key("keypad_enter", "Enter"),
        key("keypad_0", "0 Ins"), key("keypad_period", ". Del")
    ]

    static let accentKeyboard: [RebindEndpoint] = [
        accent("q", "œ"), accent("w", "∑"), accent("e", "´"), accent("r", "®"), accent("t", "†"), accent("y", "¥"), accent("u", "¨"), accent("i", "ˆ"), accent("o", "ø"), accent("p", "π"),
        accent("a", "å"), accent("s", "ß"), accent("d", "∂"), accent("f", "ƒ"), accent("g", "©"), accent("h", "˙"), accent("j", "∆"), accent("k", "˚"), accent("l", "¬"),
        accent("z", "Ω"), accent("x", "≈"), accent("c", "ç"), accent("v", "√"), accent("b", "∫"), accent("n", "˜"), accent("m", "µ"),
        accent("spacebar", "NBSP")
    ]

    static var allKeyboardOutputs: [RebindEndpoint] {
        keyboard + accentKeyboard
    }

    static let mouse: [RebindEndpoint] = [
        mouse("button1", "Left Click"),
        mouse("button2", "Right Click"),
        mouse("button3", "Middle Click"),
        mouse("button4", "Mouse Button 4"),
        mouse("button5", "Mouse Button 5"),
        mouse("button6", "Mouse Button 6"),
        mouse("button7", "Mouse Button 7"),
        mouse("button8", "Mouse Button 8")
    ]

    private static func key(_ code: String, _ label: String) -> RebindEndpoint {
        RebindEndpoint(kind: .keyboard, code: code, label: label)
    }

    private static func accent(_ code: String, _ label: String) -> RebindEndpoint {
        RebindEndpoint(kind: .keyboard, code: code, label: label, modifiers: ["left_option"])
    }

    private static func mouse(_ code: String, _ label: String) -> RebindEndpoint {
        RebindEndpoint(kind: .mouse, code: code, label: label)
    }
}

private enum KarabinerConfigurationWriter {
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/karabiner/karabiner.json")
    }

    static func write(presets: [RebindPreset], rulePrefix: String) throws -> String {
        let url = configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root = try loadRoot(from: url)
        var profiles = root["profiles"] as? [[String: Any]] ?? [["name": "Default profile", "selected": true]]
        let selectedIndex = selectedProfileIndex(in: profiles)
        if profiles.indices.contains(selectedIndex) == false {
            profiles.append(["name": "Default profile", "selected": true])
        }

        var profile = profiles[selectedIndex]
        var complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        var rules = complex["rules"] as? [[String: Any]] ?? []
        rules.removeAll { rule in
            guard let description = rule["description"] as? String else { return false }
            return description.hasPrefix(rulePrefix)
        }
        complex["rules"] = rules
        profile["complex_modifications"] = complex

        var devices = profile["devices"] as? [[String: Any]] ?? []
        devices = removePresetSimpleModifications(from: devices, presets: presets)
        let simpleModificationCount = appendEnabledSimpleModifications(to: &devices, presets: presets)
        profile["devices"] = devices

        profiles[selectedIndex] = profile
        root["profiles"] = profiles

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)

        let enabledPresetCount = presets.filter { $0.isEnabled && !$0.mappings.isEmpty }.count
        let profileName = profile["name"] as? String ?? "selected profile"
        return "Wrote \(simpleModificationCount) simple modification\(simpleModificationCount == 1 ? "" : "s") into Karabiner profile \"\(profileName)\". \(enabledPresetCount) preset\(enabledPresetCount == 1 ? "" : "s") are active."
    }

    private static func loadRoot(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [
                "global": ["check_for_updates_on_startup": true],
                "profiles": [["name": "Default profile", "selected": true, "complex_modifications": ["rules": []]]]
            ]
        }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func selectedProfileIndex(in profiles: [[String: Any]]) -> Int {
        if let currentName = currentKarabinerProfileName(),
           let index = profiles.firstIndex(where: { ($0["name"] as? String) == currentName }) {
            return index
        }
        return profiles.firstIndex { ($0["selected"] as? Bool) == true } ?? 0
    }

    private static func currentKarabinerProfileName() -> String? {
        let cliURL = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
        guard FileManager.default.fileExists(atPath: cliURL.path) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = cliURL
        process.arguments = ["--show-current-profile-name"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        } catch {
            return nil
        }
    }

    private static func fromObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        switch endpoint.kind {
        case .keyboard:
            return ["key_code": endpoint.code, "modifiers": ["optional": ["any"]]]
        case .mouse:
            return ["pointing_button": endpoint.code, "modifiers": ["optional": ["any"]]]
        }
    }

    private static func simpleFromObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        switch endpoint.kind {
        case .keyboard:
            return ["key_code": endpoint.code]
        case .mouse:
            return ["pointing_button": endpoint.code]
        }
    }

    private static func toObject(_ endpoint: RebindEndpoint) -> [String: Any] {
        var object: [String: Any]
        switch endpoint.kind {
        case .keyboard:
            object = ["key_code": endpoint.code]
        case .mouse:
            object = ["pointing_button": endpoint.code]
        }
        if let modifiers = endpoint.modifiers, !modifiers.isEmpty {
            object["modifiers"] = modifiers
        }
        return object
    }

    private static func deviceIdentifiers(for preset: RebindPreset, source: RebindEndpoint) -> [String: Any]? {
        var identifier: [String: Any] = [:]
        if let vendorID = preset.vendorID { identifier["vendor_id"] = vendorID }
        if let productID = preset.productID { identifier["product_id"] = productID }
        switch source.kind {
        case .keyboard:
            identifier["is_keyboard"] = true
        case .mouse:
            identifier["is_pointing_device"] = true
        }
        guard !identifier.isEmpty else { return nil }
        return identifier
    }

    private static func simpleModification(for mapping: RebindMapping) -> [String: Any] {
        [
            "from": simpleFromObject(mapping.from),
            "to": [toObject(mapping.to)]
        ]
    }

    private static func removePresetSimpleModifications(from devices: [[String: Any]], presets: [RebindPreset]) -> [[String: Any]] {
        devices.map { device in
            var nextDevice = device
            guard let deviceIdentifiers = device["identifiers"] as? [String: Any],
                  var simpleModifications = device["simple_modifications"] as? [[String: Any]]
            else {
                return nextDevice
            }

            simpleModifications.removeAll { simpleModification in
                presets.contains { preset in
                    preset.mappings.contains { mapping in
                        guard let identifiers = self.deviceIdentifiers(for: preset, source: mapping.from),
                              identifiersMatch(deviceIdentifiers, identifiers),
                              dictionariesEqual(simpleModification["from"] as? [String: Any], simpleFromObject(mapping.from))
                        else { return false }
                        return true
                    }
                }
            }

            nextDevice["simple_modifications"] = simpleModifications
            return nextDevice
        }
    }

    private static func appendEnabledSimpleModifications(to devices: inout [[String: Any]], presets: [RebindPreset]) -> Int {
        var count = 0
        for preset in presets where preset.isEnabled {
            for mapping in preset.mappings {
                guard let identifiers = deviceIdentifiers(for: preset, source: mapping.from) else { continue }
                let deviceIndex = indexOfDevice(matching: identifiers, in: devices)
                if let deviceIndex {
                    var device = devices[deviceIndex]
                    var simpleModifications = device["simple_modifications"] as? [[String: Any]] ?? []
                    let simpleModification = simpleModification(for: mapping)
                    if !simpleModifications.contains(where: { dictionariesEqual($0, simpleModification) }) {
                        simpleModifications.append(simpleModification)
                        count += 1
                    }
                    device["simple_modifications"] = simpleModifications
                    if mapping.from.kind == .mouse {
                        device["ignore"] = false
                    }
                    devices[deviceIndex] = device
                } else {
                    var device: [String: Any] = [
                        "identifiers": identifiers,
                        "simple_modifications": [simpleModification(for: mapping)]
                    ]
                    if mapping.from.kind == .mouse {
                        device["ignore"] = false
                    }
                    devices.append(device)
                    count += 1
                }
            }
        }
        return count
    }

    private static func indexOfDevice(matching identifiers: [String: Any], in devices: [[String: Any]]) -> Int? {
        devices.firstIndex { device in
            guard let existing = device["identifiers"] as? [String: Any] else { return false }
            return identifiersMatch(existing, identifiers)
        }
    }

    private static func identifiersMatch(_ existing: [String: Any], _ expected: [String: Any]) -> Bool {
        expected.allSatisfy { key, value in
            jsonValue(existing[key], equals: value)
        }
    }

    private static func dictionariesEqual(_ lhs: [String: Any]?, _ rhs: [String: Any]) -> Bool {
        guard let lhs else { return false }
        return NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private static func arraysEqual(_ lhs: [[String: Any]]?, _ rhs: [[String: Any]]) -> Bool {
        guard let lhs else { return false }
        return NSArray(array: lhs).isEqual(to: rhs)
    }

    private static func jsonValue(_ lhs: Any?, equals rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as NSNumber, rhs as Int):
            return lhs.intValue == rhs
        case let (lhs as NSNumber, rhs as Bool):
            return lhs.boolValue == rhs
        default:
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private enum RebindLayerViewMode: String, Identifiable {
    case normal
    case rebinded
    case ungrabbed
    case grabbed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "Normal"
        case .rebinded: "Rebinded"
        case .ungrabbed: "Ungrabbed"
        case .grabbed: "Grabbed"
        }
    }
    var sourceTitle: String {
        switch self {
        case .normal: "Normal Layout"
        case .rebinded: "Rebinded Layout"
        case .ungrabbed: "Ungrabbed Layout"
        case .grabbed: "Grabbed Layout"
        }
    }
    var sourceSubtitle: String {
        switch self {
        case .normal: "Original keyboard and mouse output."
        case .rebinded: "Choose the key or mouse button to rebind."
        case .ungrabbed: "Choose the key or mouse button for the ungrabbed layer."
        case .grabbed: "Choose the key or mouse button for the cursor-grabbed layer."
        }
    }
    var targetSubtitle: String {
        switch self {
        case .normal: "Normal layout is unchanged."
        case .rebinded: "Choose the output for the selected control."
        case .ungrabbed: "Choose the output while the cursor is not grabbed."
        case .grabbed: "Choose the output while the cursor is grabbed."
        }
    }

    var isEditable: Bool {
        self != .normal
    }

    var editsGrabbedLayer: Bool {
        self == .grabbed
    }
}

struct KeyRebinderSettingsView: View {
    @ObservedObject var controller: KeyRebinderController
    @State private var targetKind: RebindEndpointKind = .keyboard
    @State private var visualSelectedSource: RebindEndpoint?
    @State private var visualLayerMode: RebindLayerViewMode = .rebinded
    @State private var showGrabbedLayerControls = false
    @State private var showAccentTargets = false
    @State private var editingProfileName: String?
    @State private var editingProfileText = ""
    @FocusState private var focusedProfileName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Key Rebinder", subtitle: ToolSection.keyRebinder.description)

            presetSection
            karabinerStatusSection
            remapScopeSection
            visualRebindSection
            statusSection
        }
    }

    private var karabinerStatusSection: some View {
        SectionBox(title: "Karabiner Connection") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: controller.karabinerStatus.isConnected ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(controller.karabinerStatus.isConnected ? Color.green : Color.yellow)
                    .modifier(MSTPreserveSemanticColor())
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(controller.karabinerStatus.title)
                            .font(.system(size: 16, weight: .black))
                        Spacer()
                        Button {
                            controller.refreshKarabinerStatus()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(controller.karabinerStatus.detail)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                        KarabinerCheck(label: "App installed", isOK: controller.karabinerStatus.isInstalled)
                        KarabinerCheck(label: "User server running", isOK: controller.karabinerStatus.isConsoleUserServerRunning)
                        KarabinerCheck(label: "Core service running", isOK: controller.karabinerStatus.isCoreServiceRunning)
                        KarabinerCheck(label: "Virtual HID active", isOK: controller.karabinerStatus.isVirtualHIDDaemonRunning)
                    }

                    Text("MST writes rows directly into the active Karabiner profile's simple_modifications, so the same rows appear in Karabiner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(controller.karabinerStatus.isInstalled ? "Open Karabiner" : "Install Karabiner") {
                            controller.openKarabiner()
                        }
                        Button("Download Page") {
                            controller.openKarabinerDownload()
                        }
                        Button("Accessibility Settings") {
                            controller.openAccessibilitySettings()
                        }
                        Button("Show Config") {
                            controller.revealKarabinerConfig()
                        }
                        .disabled(!controller.karabinerStatus.configExists)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var karabinerProfilesSection: some View {
        SectionBox(title: "Karabiner Profiles") {
            if controller.karabinerProfiles.isEmpty {
                Text("No Karabiner profiles found.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.karabinerProfiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.isCurrent ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(profile.isCurrent ? Color.white : Color.secondary)
                            Text(profile.name)
                                .font(.system(size: 13, weight: .bold))
                            Spacer()
                            Button(profile.isCurrent ? "Active" : "Switch") {
                                controller.selectKarabinerProfile(profile.name)
                            }
                            .buttonStyle(.bordered)
                            .disabled(profile.isCurrent)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.24)))
                    }
                }
            }
        }
    }

    private var karabinerSimpleModificationsSection: some View {
        SectionBox(title: "Karabiner Simple Modifications") {
            if controller.karabinerSimpleGroups.isEmpty {
                Text("No simple modifications found in the active Karabiner profile.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.karabinerSimpleGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.system(size: 13, weight: .black))
                                    Text(group.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import as MST Preset") {
                                    controller.importKarabinerGroupAsPreset(group)
                                }
                                .buttonStyle(.bordered)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(group.mappings) { mapping in
                                    HStack(spacing: 8) {
                                        Text(mapping.from.label.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                        Text(mapping.to.label.replacingOccurrences(of: "\n", with: " "))
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.24)))
                    }
                }
            }
        }
    }

    private var presetSection: some View {
        SectionBox(title: "Presets") {
            VStack(alignment: .leading, spacing: 12) {
                if controller.karabinerProfiles.isEmpty {
                    Text("No Karabiner profiles found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.karabinerProfiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.isCurrent ? "largecircle.fill.circle" : "circle")
                                .frame(width: 18)

                            if editingProfileName == profile.name {
                                TextField("Preset name", text: $editingProfileText)
                                    .font(.system(size: 13, weight: .bold))
                                    .textFieldStyle(.plain)
                                    .focused($focusedProfileName, equals: profile.name)
                                    .onSubmit {
                                        finishEditingProfileName(oldName: profile.name)
                                    }
                                    .onExitCommand {
                                        cancelEditingProfileName()
                                    }
                            } else {
                                Text(profile.name)
                                    .font(.system(size: 13, weight: .bold))
                                    .lineLimit(1)
                                    .onTapGesture(count: 2) {
                                        startEditingProfileName(profile.name)
                                    }
                            }

                            Spacer()

                            Button {
                                controller.beginRecordingProfileShortcut(profile.name)
                            } label: {
                                Label(controller.recordingProfileName == profile.name ? "Press keys..." : profileShortcutTitle(for: profile.name), systemImage: "command")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                controller.clearProfileShortcut(profile.name)
                            } label: {
                                Label("Clear", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.profileShortcuts[profile.name] == nil)

                            Button(profile.isCurrent ? "Active" : "Switch") {
                                controller.selectKarabinerProfile(profile.name)
                            }
                            .buttonStyle(.bordered)
                            .disabled(profile.isCurrent)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(profile.isCurrent ? Color.white : Color.clear)
                        .foregroundStyle(profile.isCurrent ? Color.black : Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.32)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            guard editingProfileName == nil else { return }
                            controller.selectKarabinerProfile(profile.name)
                        }
                    }
                }

                HStack {
                    Button {
                        controller.addKarabinerProfile()
                    } label: {
                        Label("Add Preset", systemImage: "plus")
                    }

                    Button {
                        controller.refreshKarabinerStatus()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func profileShortcutTitle(for profileName: String) -> String {
        controller.profileShortcuts[profileName]?.displayName ?? "Set Keybind"
    }

    private func startEditingProfileName(_ profileName: String) {
        editingProfileName = profileName
        editingProfileText = profileName
        DispatchQueue.main.async {
            focusedProfileName = profileName
        }
    }

    private func finishEditingProfileName(oldName: String) {
        controller.renameKarabinerProfile(from: oldName, to: editingProfileText)
        cancelEditingProfileName()
    }

    private func cancelEditingProfileName() {
        editingProfileName = nil
        editingProfileText = ""
        focusedProfileName = nil
    }

    private var remapScopeSection: some View {
        SectionBox(title: "Remap Scope") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { controller.showAdvancedScopes },
                        set: { _ in controller.toggleAdvancedScopes() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Text(controller.showAdvancedScopes ? "Showing Karabiner device scopes." : "Showing only global scopes: For all devices and All Pointing Devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.visibleKarabinerGroups.isEmpty {
                Text("No Karabiner simple modification groups found.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(controller.visibleKarabinerGroups) { group in
                        Button {
                            controller.selectKarabinerGroup(group.id)
                            visualSelectedSource = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: group.isMouse && !group.isKeyboard ? "computermouse" : group.isKeyboard && !group.isMouse ? "keyboard" : "square.grid.2x2")
                                    Text(group.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .lineLimit(2)
                                }
                                Text(group.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(controller.selectedKarabinerGroup?.id == group.id ? Color.white : Color.black)
                            .foregroundStyle(controller.selectedKarabinerGroup?.id == group.id ? Color.black : Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.34)))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var visualRebindSection: some View {
        SectionBox(title: "Remaps") {
            if let group = controller.selectedKarabinerGroup {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title)
                                .font(.system(size: 14, weight: .black))
                            Text(visualInstruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let visualSelectedSource {
                            Button {
                                if !visualLayerMode.editsGrabbedLayer,
                                   let index = group.mappings.firstIndex(where: { $0.from == visualSelectedSource }) {
                                    controller.deleteKarabinerSimpleModification(groupID: group.id, index: index)
                                } else if visualLayerMode.editsGrabbedLayer {
                                    controller.deleteKarabinerGrabbedModification(groupID: group.id, from: visualSelectedSource)
                                }
                            } label: {
                                Label("Clear Selected", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!visualLayerMode.isEditable || activeMappings(for: group).contains(where: { $0.from == visualSelectedSource }) == false)
                        }
                    }

                    HStack(spacing: 12) {
                        Picker("Layer", selection: $visualLayerMode) {
                            ForEach(visibleLayerModes) { layer in
                                Text(layer.title).tag(layer)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: showGrabbedLayerControls ? 420 : 320)

                        Toggle("Advanced", isOn: Binding(
                            get: { showGrabbedLayerControls },
                            set: { setGrabbedLayerControlsVisible($0) }
                        ))
                        .toggleStyle(.switch)
                    }

                    VisualRebindBoard(
                        title: visualLayerMode.sourceTitle,
                        subtitle: visualLayerMode.sourceSubtitle,
                        mappings: activeMappings(for: group),
                        selectedSource: visualSelectedSource,
                        enabledSources: sourceEndpoints(for: group),
                        enabledTargets: [],
                        mode: .source
                    ) { endpoint in
                        visualSelectedSource = endpoint
                    }

                    VisualRebindBoard(
                        title: "Rebind Options",
                        subtitle: visualLayerMode.targetSubtitle,
                        mappings: [],
                        selectedSource: nil,
                        enabledSources: [],
                        enabledTargets: targetEndpoints,
                        mode: .target,
                        accentMode: showAccentTargets
                    ) { endpoint in
                        guard let visualSelectedSource else { return }
                        guard visualLayerMode.isEditable else { return }
                        if visualLayerMode.editsGrabbedLayer {
                            controller.setKarabinerGrabbedModification(groupID: group.id, from: visualSelectedSource, to: endpoint)
                        } else {
                            controller.setKarabinerSimpleModification(groupID: group.id, from: visualSelectedSource, to: endpoint)
                        }
                    }
                    .opacity(visualSelectedSource == nil || !visualLayerMode.isEditable ? 0.48 : 1)
                    .disabled(visualSelectedSource == nil || !visualLayerMode.isEditable)

                    HStack {
                        Spacer()
                        Toggle("Accents", isOn: $showAccentTargets)
                            .toggleStyle(.switch)
                    }
                }
            } else {
                Text("Select a remap scope.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var visualInstruction: String {
        if let visualSelectedSource {
            if visualLayerMode.isEditable {
                return "Selected \(visualSelectedSource.label.replacingOccurrences(of: "\n", with: " ")). Pick its \(visualLayerMode.title.lowercased()) output below."
            }
            return "Selected \(visualSelectedSource.label.replacingOccurrences(of: "\n", with: " "))."
        }
        if visualLayerMode.isEditable {
            return "Pick a source on the top board, then pick its output on the bottom board."
        }
        return "Showing the unchanged keyboard and mouse layout."
    }

    private func activeMappings(for group: KarabinerSimpleModificationGroup) -> [RebindMapping] {
        switch visualLayerMode {
        case .normal:
            return []
        case .rebinded, .ungrabbed:
            return group.mappings
        case .grabbed:
            return group.grabbedMappings
        }
    }

    private var visibleLayerModes: [RebindLayerViewMode] {
        showGrabbedLayerControls ? [.normal, .ungrabbed, .grabbed] : [.normal, .rebinded]
    }

    private func setGrabbedLayerControlsVisible(_ isVisible: Bool) {
        showGrabbedLayerControls = isVisible
        switch (isVisible, visualLayerMode) {
        case (true, .rebinded):
            visualLayerMode = .ungrabbed
        case (false, .ungrabbed), (false, .grabbed):
            visualLayerMode = .rebinded
        default:
            break
        }
    }

    private func sourceEndpoints(for group: KarabinerSimpleModificationGroup) -> [RebindEndpoint] {
        if group.isMouse && !group.isKeyboard {
            return KeyRebinderLibrary.mouse
        }
        if group.isKeyboard && !group.isMouse {
            return KeyRebinderLibrary.keyboard
        }
        return KeyRebinderLibrary.keyboard + KeyRebinderLibrary.mouse
    }

    private var targetEndpoints: [RebindEndpoint] {
        KeyRebinderLibrary.allKeyboardOutputs + KeyRebinderLibrary.mouse
    }

    private var deviceSection: some View {
        SectionBox(title: "Detected Devices") {
            HStack {
                Button {
                    controller.refreshDevices()
                    controller.refreshKarabinerStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            if controller.detectedDevices.isEmpty {
                Text("No keyboard or mouse devices detected.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(controller.detectedDevices) { device in
                        Button {
                            controller.selectDevice(device)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: device.isKeyboard ? "keyboard" : "computermouse")
                                    Text(device.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .lineLimit(2)
                                }
                                Text(device.typeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("VID \(device.vendorID.map(String.init) ?? "?")  PID \(device.productID.map(String.init) ?? "?")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(controller.selectedPreset?.selectedDeviceID == device.id ? Color.white : Color.black)
                            .foregroundStyle(controller.selectedPreset?.selectedDeviceID == device.id ? Color.black : Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.34)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var targetSection: some View {
        SectionBox(title: "Bind To") {
            Picker("Target Type", selection: $targetKind) {
                ForEach(RebindEndpointKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if targetKind == .keyboard {
                RebindKeyboardView(mappings: [], selectedSource: nil) { endpoint in
                    controller.mapSelectedSource(to: endpoint)
                }
            } else {
                RebindMouseView(mappings: [], selectedSource: nil) { endpoint in
                    controller.mapSelectedSource(to: endpoint)
                }
            }
        }
    }

    private var mappingsSection: some View {
        SectionBox(title: "Mappings") {
            let mappings = controller.selectedKarabinerGroup?.mappings ?? []
            if mappings.isEmpty {
                Text("No mappings in this scope yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mappings) { mapping in
                        HStack(spacing: 10) {
                            Text(mapping.from.label.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(.body, design: .monospaced))
                            Image(systemName: "arrow.right")
                            Text(mapping.to.label.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(.body, design: .monospaced))
                            if mapping.warning != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help(mapping.warning ?? "")
                            }
                            Spacer()
                        }
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.24)))
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Text(controller.status)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(controller.status == "Rebinds updated" ? Color.green : Color.yellow)
            .modifier(MSTPreserveSemanticColor())
    }
}

struct KarabinerCheck: View {
    let label: String
    let isOK: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOK ? Color.green : Color.secondary)
                .modifier(MSTPreserveSemanticColor())
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18)))
    }
}

struct EndpointPicker: View {
    let endpoint: RebindEndpoint
    let endpoints: [RebindEndpoint]
    let onChange: (RebindEndpoint) -> Void

    private var options: [RebindEndpoint] {
        endpoints.contains(endpoint) ? endpoints : [endpoint] + endpoints
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.code) {
                    onChange(option)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(endpoint.code)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(width: 168, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }
}

enum VisualRebindBoardMode {
    case source
    case target
}

struct VisualRebindBoard: View {
    let title: String
    let subtitle: String
    let mappings: [RebindMapping]
    let selectedSource: RebindEndpoint?
    let enabledSources: [RebindEndpoint]
    let enabledTargets: [RebindEndpoint]
    let mode: VisualRebindBoardMode
    var accentMode = false
    let action: (RebindEndpoint) -> Void

    private var enabledEndpoints: Set<RebindEndpoint> {
        switch mode {
        case .source:
            Set(enabledSources)
        case .target:
            Set(enabledTargets)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .target {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                RebindKeyboardView(
                    mappings: mappings,
                    selectedSource: selectedSource,
                    enabledEndpoints: enabledEndpoints,
                    accentMode: mode == .target && accentMode,
                    chooseSource: action
                )
                .layoutPriority(1)

                VisualMousePanel(
                    mappings: mappings,
                    selectedSource: selectedSource,
                    enabledEndpoints: enabledEndpoints,
                    action: action
                )
                .frame(width: 230)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.025))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct VisualMousePanel: View {
    let mappings: [RebindMapping]
    let selectedSource: RebindEndpoint?
    let enabledEndpoints: Set<RebindEndpoint>
    let action: (RebindEndpoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOUSE")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                mouseButton("button1", width: 70, height: 74)
                mouseButton("button3", width: 46, height: 74)
                mouseButton("button2", width: 70, height: 74)
            }

            VStack(spacing: 6) {
                mouseButton("button4", width: 192, height: 36)
                mouseButton("button5", width: 192, height: 36)
                mouseButton("button6", width: 192, height: 36)
                mouseButton("button7", width: 192, height: 36)
                mouseButton("button8", width: 192, height: 42)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func mouseButton(_ code: String, width: CGFloat, height: CGFloat) -> some View {
        let endpoint = KeyRebinderLibrary.mouse.first { $0.code == code } ?? KeyRebinderLibrary.mouse[0]
        let isEnabled = enabledEndpoints.contains(endpoint)
        return RebindKeyButton(
            endpoint: endpoint,
            width: width,
            height: height,
            isSelected: selectedSource == endpoint,
            isEnabled: isEnabled,
            mapping: mappings.first { $0.from == endpoint },
            action: { action(endpoint) }
        )
    }
}

struct RebindKeyboardView: View {
    let mappings: [RebindMapping]
    let selectedSource: RebindEndpoint?
    var enabledEndpoints: Set<RebindEndpoint>? = nil
    var accentMode = false
    let chooseSource: (RebindEndpoint) -> Void

    private var mainRows: [[KeyboardKeySpec]] {
        [
            row([("escape", 1), (nil, 0.55), ("f1", 1), ("f2", 1), ("f3", 1), ("f4", 1), (nil, 0.45), ("f5", 1), ("f6", 1), ("f7", 1), ("f8", 1), (nil, 0.45), ("f9", 1), ("f10", 1), ("f11", 1), ("f12", 1)]),
            row([("grave_accent_and_tilde", 1), ("1", 1), ("2", 1), ("3", 1), ("4", 1), ("5", 1), ("6", 1), ("7", 1), ("8", 1), ("9", 1), ("0", 1), ("hyphen", 1), ("equal_sign", 1), ("delete_or_backspace", 2)]),
            row([("tab", 1.5), ("q", 1), ("w", 1), ("e", 1), ("r", 1), ("t", 1), ("y", 1), ("u", 1), ("i", 1), ("o", 1), ("p", 1), ("open_bracket", 1), ("close_bracket", 1), ("backslash", 1.5)]),
            row([("caps_lock", 1.85), ("a", 1), ("s", 1), ("d", 1), ("f", 1), ("g", 1), ("h", 1), ("j", 1), ("k", 1), ("l", 1), ("semicolon", 1), ("quote", 1), ("return_or_enter", 2.15)]),
            row([("left_shift", 2.35), ("z", 1), ("x", 1), ("c", 1), ("v", 1), ("b", 1), ("n", 1), ("m", 1), ("comma", 1), ("period", 1), ("slash", 1), ("right_shift", 2.65)]),
            row([("left_control", 1.25), ("left_option", 1.25), ("left_command", 1.35), ("spacebar", 6.35), ("right_command", 1.35), ("right_option", 1.25), ("application", 1.25), ("right_control", 1.25)])
        ]
    }

    private var navRows: [[KeyboardKeySpec]] {
        [
            row([("print_screen", 1), ("scroll_lock", 1), ("pause", 1)]),
            row([(nil, 1), (nil, 1), (nil, 1)]),
            row([("insert", 1), ("home", 1), ("page_up", 1)]),
            row([("delete_forward", 1), ("end", 1), ("page_down", 1)]),
            row([(nil, 1), ("up_arrow", 1), (nil, 1)]),
            row([("left_arrow", 1), ("down_arrow", 1), ("right_arrow", 1)])
        ]
    }

    private var numpadRows: [[KeyboardKeySpec]] {
        [
            row([("keypad_num_lock", 1), ("keypad_slash", 1), ("keypad_asterisk", 1), ("keypad_hyphen", 1)]),
            row([("keypad_7", 1), ("keypad_8", 1), ("keypad_9", 1), ("keypad_plus", 1)]),
            row([("keypad_4", 1), ("keypad_5", 1), ("keypad_6", 1), (nil, 1)]),
            row([("keypad_1", 1), ("keypad_2", 1), ("keypad_3", 1), ("keypad_enter", 1)]),
            row([("keypad_0", 2), ("keypad_period", 1), (nil, 1)])
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 6
            let totalUnits: CGFloat = 15.9 + 3 + 4
            let maxKeyWidth = (geometry.size.width - 52) / totalUnits
            let keyWidth = min(42, max(28, maxKeyWidth))
            let keyHeight = max(42, keyWidth * 0.86)

            HStack(alignment: .top, spacing: 16) {
                keyboardGroup(mainRows, keyWidth: keyWidth, keyHeight: keyHeight, gap: gap)
                keyboardGroup(navRows, keyWidth: keyWidth, keyHeight: keyHeight, gap: gap)
                keyboardGroup(numpadRows, keyWidth: keyWidth, keyHeight: keyHeight, gap: gap)
            }
            .padding(10)
            .background(Color.white.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
        }
        .frame(minHeight: 328)
    }

    private func keyboardGroup(_ rows: [[KeyboardKeySpec]], keyWidth: CGFloat, keyHeight: CGFloat, gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(row) { key in
                        if let endpoint = endpoint(for: key) {
                            let isEnabled = enabledEndpoints?.contains(endpoint) ?? true
                            RebindKeyButton(
                                endpoint: endpoint,
                                width: keyWidth * CGFloat(key.widthUnits) + gap * CGFloat(max(0, key.widthUnits - 1)),
                                height: keyHeight,
                                isSelected: selectedSource == endpoint,
                                isEnabled: isEnabled,
                                mapping: mappings.first { $0.from == endpoint },
                                action: { chooseSource(endpoint) }
                            )
                        } else {
                            Color.clear
                                .frame(width: keyWidth * CGFloat(key.widthUnits) + gap * CGFloat(max(0, key.widthUnits - 1)), height: keyHeight)
                        }
                    }
                }
            }
        }
    }

    private func row(_ specs: [(String?, Double)]) -> [KeyboardKeySpec] {
        specs.compactMap { code, width in
            guard let code else {
                return KeyboardKeySpec(endpoint: nil, widthUnits: width)
            }
            guard let endpoint = KeyRebinderLibrary.keyboard.first(where: { $0.code == code }) else { return nil }
            return KeyboardKeySpec(endpoint: endpoint, widthUnits: width)
        }
    }

    private func endpoint(for key: KeyboardKeySpec) -> RebindEndpoint? {
        guard let endpoint = key.endpoint else { return nil }
        guard accentMode,
              let accentEndpoint = KeyRebinderLibrary.accentKeyboard.first(where: { $0.code == endpoint.code })
        else {
            return endpoint
        }
        return accentEndpoint
    }
}

struct KeyboardKeySpec: Identifiable {
    let id = UUID()
    let endpoint: RebindEndpoint?
    let widthUnits: Double
}

struct RebindMouseView: View {
    let mappings: [RebindMapping]
    let selectedSource: RebindEndpoint?
    var enabledEndpoints: Set<RebindEndpoint>? = nil
    let chooseSource: (RebindEndpoint) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                mouseButton("button4", width: 150, height: 42)
                mouseButton("button5", width: 150, height: 42)
                mouseButton("button6", width: 150, height: 42)
                mouseButton("button7", width: 150, height: 42)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    mouseButton("button1", width: 138, height: 72)
                    mouseButton("button3", width: 70, height: 72)
                    mouseButton("button2", width: 138, height: 72)
                }
                mouseButton("button8", width: 362, height: 56)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 92, height: 4)
                            .padding(.bottom, 10)
                    }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16)))
    }

    private func mouseButton(_ code: String, width: CGFloat, height: CGFloat) -> some View {
        let endpoint = KeyRebinderLibrary.mouse.first { $0.code == code } ?? KeyRebinderLibrary.mouse[0]
        return RebindKeyButton(
            endpoint: endpoint,
            width: width,
            height: height,
            isSelected: selectedSource == endpoint,
            isEnabled: enabledEndpoints?.contains(endpoint) ?? true,
            mapping: mappings.first { $0.from == endpoint },
            action: { chooseSource(endpoint) }
        )
    }
}

struct RebindKeyButton: View {
    let endpoint: RebindEndpoint
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    var isEnabled = true
    let mapping: RebindMapping?
    let action: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                action()
            }
        } label: {
            VStack(spacing: 3) {
                keyText
                mappingText
            }
            .frame(width: width, height: height)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .overlay(buttonBorder)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.28)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(helpText)
    }

    private var keyText: some View {
        Text(keyLabel)
            .font(keyFont)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.65)
    }

    @ViewBuilder
    private var mappingText: some View {
        if let mapping, let mappedLabel {
            HStack(spacing: 3) {
                Image(systemName: mapping.warning == nil ? "arrow.right" : "exclamationmark.triangle.fill")
                    .font(warningFont)
                    .foregroundColor(mapping.warning == nil ? Color.secondary : Color.yellow)
                Text(mappedLabel)
                    .font(mappedFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
    }

    private var buttonBorder: some View {
        RoundedRectangle(cornerRadius: 7)
            .stroke(borderColor, lineWidth: borderWidth)
    }

    private var helpText: String {
        mapping?.warning ?? endpoint.label.replacingOccurrences(of: "\n", with: " ")
    }

    private var mappedLabel: String? {
        mapping?.to.label.replacingOccurrences(of: "\n", with: " ")
    }

    private var keyLabel: String { endpoint.label }
    private var keyFont: Font { .system(size: 13, weight: .bold) }
    private var mappedFont: Font { .system(size: 9, weight: .bold) }
    private var warningFont: Font { .system(size: 8, weight: .black) }
    private var backgroundColor: Color { isSelected ? .white : Color(red: 0.035, green: 0.04, blue: 0.05) }
    private var foregroundColor: Color { isSelected ? .black : .white }
    private var borderColor: Color {
        if mapping?.warning != nil { return Color.yellow.opacity(0.95) }
        if mapping != nil { return Color(red: 0.35, green: 0.62, blue: 1.0) }
        return Color.white.opacity(0.22)
    }
    private var borderWidth: CGFloat { mapping == nil ? 1 : 2 }
}
