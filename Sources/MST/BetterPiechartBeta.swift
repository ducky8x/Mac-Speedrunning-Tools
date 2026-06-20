import AppKit
import CoreGraphics
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SwiftUI
import VideoToolbox

struct PiechartBetaWindowCandidate: Identifiable, Hashable {
    let id: CGWindowID
    let displayName: String
    let sizeDescription: String
}

private struct PiechartBetaPersistedSettings: Codable {
    private static let templateHeightBase = 0.50
    private static let cropSizeBase = 0.45
    private static let stretchMultiplierBase = 0.93

    var projectorAlwaysOnTop: Bool
    var projectorShowTitlebar: Bool
    var projectorFPS: Double
    var projectorFrame: PersistedRect?
    var selectedWindowDisplayName: String?
    var selectedWindowSizeDescription: String?
    var thinWidth: Int
    var thinHeight: Int
    var entityCounterYOffset: Double
    var templateHeightScale: Double
    var cropSizeScale: Double
    var stretchMultiplierScale: Double
    var templateCenterX: Double
    var templateCenterY: Double

    enum CodingKeys: String, CodingKey {
        case projectorAlwaysOnTop
        case projectorShowTitlebar
        case projectorFPS
        case projectorFrame
        case selectedWindowDisplayName
        case selectedWindowSizeDescription
        case thinWidth
        case thinHeight
        case entityCounterYOffset
        case templateHeightScale
        case cropSizeScale
        case stretchMultiplierScale
        case templateHeightRatio
        case cropSize
        case stretchMultiplier
        case templateCenterX
        case templateCenterY
    }

    init(
        projectorAlwaysOnTop: Bool,
        projectorShowTitlebar: Bool,
        projectorFPS: Double,
        projectorFrame: PersistedRect?,
        selectedWindowDisplayName: String?,
        selectedWindowSizeDescription: String?,
        thinWidth: Int,
        thinHeight: Int,
        entityCounterYOffset: Double,
        templateHeightScale: Double,
        cropSizeScale: Double,
        stretchMultiplierScale: Double,
        templateCenterX: Double,
        templateCenterY: Double
    ) {
        self.projectorAlwaysOnTop = projectorAlwaysOnTop
        self.projectorShowTitlebar = projectorShowTitlebar
        self.projectorFPS = projectorFPS
        self.projectorFrame = projectorFrame
        self.selectedWindowDisplayName = selectedWindowDisplayName
        self.selectedWindowSizeDescription = selectedWindowSizeDescription
        self.thinWidth = thinWidth
        self.thinHeight = thinHeight
        self.entityCounterYOffset = entityCounterYOffset
        self.templateHeightScale = templateHeightScale
        self.cropSizeScale = cropSizeScale
        self.stretchMultiplierScale = stretchMultiplierScale
        self.templateCenterX = templateCenterX
        self.templateCenterY = templateCenterY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        projectorAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .projectorAlwaysOnTop) ?? true
        projectorShowTitlebar = try container.decodeIfPresent(Bool.self, forKey: .projectorShowTitlebar) ?? false
        projectorFPS = try container.decodeIfPresent(Double.self, forKey: .projectorFPS) ?? 60
        projectorFrame = try container.decodeIfPresent(PersistedRect.self, forKey: .projectorFrame)
        selectedWindowDisplayName = try container.decodeIfPresent(String.self, forKey: .selectedWindowDisplayName)
        selectedWindowSizeDescription = try container.decodeIfPresent(String.self, forKey: .selectedWindowSizeDescription)
        thinWidth = try container.decodeIfPresent(Int.self, forKey: .thinWidth) ?? 384
        thinHeight = try container.decodeIfPresent(Int.self, forKey: .thinHeight) ?? 1080
        entityCounterYOffset = try container.decodeIfPresent(Double.self, forKey: .entityCounterYOffset) ?? 37

        if let scale = try container.decodeIfPresent(Double.self, forKey: .templateHeightScale) {
            templateHeightScale = scale
        } else if let ratio = try container.decodeIfPresent(Double.self, forKey: .templateHeightRatio) {
            templateHeightScale = ratio / Self.templateHeightBase
        } else {
            templateHeightScale = 1
        }

        if let scale = try container.decodeIfPresent(Double.self, forKey: .cropSizeScale) {
            cropSizeScale = scale
        } else if let crop = try container.decodeIfPresent(Double.self, forKey: .cropSize) {
            cropSizeScale = crop / Self.cropSizeBase
        } else {
            cropSizeScale = 1
        }

        if let scale = try container.decodeIfPresent(Double.self, forKey: .stretchMultiplierScale) {
            stretchMultiplierScale = scale
        } else if let stretch = try container.decodeIfPresent(Double.self, forKey: .stretchMultiplier) {
            stretchMultiplierScale = stretch / Self.stretchMultiplierBase
        } else {
            stretchMultiplierScale = 1
        }

        templateCenterX = try container.decodeIfPresent(Double.self, forKey: .templateCenterX) ?? 0.5
        templateCenterY = try container.decodeIfPresent(Double.self, forKey: .templateCenterY) ?? 0.5
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectorAlwaysOnTop, forKey: .projectorAlwaysOnTop)
        try container.encode(projectorShowTitlebar, forKey: .projectorShowTitlebar)
        try container.encode(projectorFPS, forKey: .projectorFPS)
        try container.encodeIfPresent(projectorFrame, forKey: .projectorFrame)
        try container.encodeIfPresent(selectedWindowDisplayName, forKey: .selectedWindowDisplayName)
        try container.encodeIfPresent(selectedWindowSizeDescription, forKey: .selectedWindowSizeDescription)
        try container.encode(thinWidth, forKey: .thinWidth)
        try container.encode(thinHeight, forKey: .thinHeight)
        try container.encode(entityCounterYOffset, forKey: .entityCounterYOffset)
        try container.encode(templateHeightScale, forKey: .templateHeightScale)
        try container.encode(cropSizeScale, forKey: .cropSizeScale)
        try container.encode(stretchMultiplierScale, forKey: .stretchMultiplierScale)
        try container.encode(templateCenterX, forKey: .templateCenterX)
        try container.encode(templateCenterY, forKey: .templateCenterY)
    }
}

private struct PiechartBetaDetection {
    let rawCrop: CGImage
    let correctedImage: CGImage
    let entityCounterImage: CGImage?
    let cropRect: CGRect
}

@MainActor
final class PiechartBetaState: ObservableObject {
    private static let betaSettingsKey = "mts.piechartbeta.settings.v3"
    private static let legacySettingsKeys = [
        "mts.piechartbeta.settings.v2",
        "mts.piechartbeta.settings.v1"
    ]
    private static let thinTolerance = 5
    private static let templateHeightBase = 0.50
    private static let cropSizeBase = 0.45
    private static let stretchMultiplierBase = 0.93

    @Published var isLive = false
    @Published private(set) var isProjectorVisible = false
    @Published var projectorAlwaysOnTop = true
    @Published var projectorShowTitlebar = false
    @Published private(set) var availableWindows: [PiechartBetaWindowCandidate] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var rawPiePreview: CGImage?
    @Published var correctedPreview: CGImage?
    @Published var entityCounterPreview: CGImage?
    @Published var statusText = "Set your thin resolution, refresh Minecraft windows, then start the thin projector."
    @Published var detectionText = "Waiting for a thin-mode Minecraft window."
    @Published var projectorFPS = 60.0
    @Published var thinWidth = 384
    @Published var thinHeight = 1080
    @Published var entityCounterYOffset = 37.0
    @Published var templateHeightScale = 1.00
    @Published var cropSizeScale = 1.00
    @Published var stretchMultiplierScale = 1.00
    @Published private(set) var templateCenterNormalized = CGPoint(x: 0.5, y: 0.5)

    private let projector = ProjectorWindowController()
    private let projectorModel = ProjectorModel()
    private var shareableWindows: [SCWindow] = []
    private var stream: SCStream?
    private var streamOutput: PiechartBetaStreamOutput?
    private let sampleQueue = DispatchQueue(label: "MST.BetterPiechartBeta.SampleQueue")
    private var captureScale = 1.0
    private var lastDetectionTime = CFAbsoluteTimeGetCurrent()
    private var lastPreviewUpdateTime: CFAbsoluteTime = 0
    private var lastStatusUpdateTime: CFAbsoluteTime = 0
    private var pendingCaptureRestart: Task<Void, Never>?
    private var lastThinModeMatch = false
    private var projectorFrame: CGRect?
    private var selectedWindowDisplayName: String?
    private var selectedWindowSizeDescription: String?

    var primaryToggleTitle: String {
        isLive ? "Stop BetterPiechart^2" : "Start BetterPiechart^2"
    }

    var effectiveTemplateHeightRatio: Double {
        min(0.90, max(0.08, Self.templateHeightBase * templateHeightScale))
    }

    var effectiveCropSize: Double {
        min(1.00, max(0.35, Self.cropSizeBase * cropSizeScale))
    }

    var effectiveStretchMultiplier: Double {
        min(1.35, max(0.60, Self.stretchMultiplierBase * stretchMultiplierScale))
    }

    init() {
        loadPersistedSettings()
        projector.onFrameChange = { [weak self] frame in
            self?.projectorFrame = frame
            self?.persistSettings()
        }
    }

    func toggle() {
        isLive ? stop() : start()
    }

    func setProjectorAlwaysOnTop(_ value: Bool) {
        projectorAlwaysOnTop = value
        projector.setAlwaysOnTop(value)
        persistSettings()
    }

    func setProjectorShowTitlebar(_ value: Bool) {
        projectorShowTitlebar = value
        projector.setShowTitlebar(value)
        persistSettings()
    }

    func setProjectorFPS(_ value: Double) {
        projectorFPS = Self.clampedProjectorFPS(value)
        persistSettings()
        restartCaptureSoon()
    }

    func setThinWidth(_ value: Int) {
        thinWidth = max(64, value)
        persistSettings()
        restartCaptureSoon()
    }

    func setThinHeight(_ value: Int) {
        thinHeight = max(64, value)
        persistSettings()
        restartCaptureSoon()
    }

    func setSelectedWindowID(_ value: CGWindowID?) {
        selectedWindowID = value
        if let value,
           let selected = availableWindows.first(where: { $0.id == value }) {
            selectedWindowDisplayName = selected.displayName
            selectedWindowSizeDescription = selected.sizeDescription
        }
        persistSettings()
        restartCaptureSoon()
    }

    func setEntityCounterYOffset(_ value: Double) {
        entityCounterYOffset = min(90, max(20, value.rounded()))
        persistSettings()
    }

    func updateTemplateHeightScale(_ value: Double) {
        templateHeightScale = min(1.80, max(0.60, value))
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateCropSizeScale(_ value: Double) {
        cropSizeScale = min(2.20, max(0.80, value))
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateStretchMultiplierScale(_ value: Double) {
        stretchMultiplierScale = min(1.45, max(0.70, value))
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateTemplateCenter(_ normalizedPoint: CGPoint) {
        templateCenterNormalized = Self.clampedNormalizedPoint(normalizedPoint)
        persistSettings()
        refreshFromCurrentPreview()
        statusText = String(
            format: "Saved pie location at %.2f, %.2f.",
            templateCenterNormalized.x,
            templateCenterNormalized.y
        )
    }

    func importThinSetup() {
        let windowID = selectedWindowID ?? shareableWindows.first?.windowID
        guard let windowID,
              let bounds = Self.currentWindowBounds(windowID: windowID) else {
            statusText = "Select a Minecraft window first, then import the thin setup."
            return
        }

        selectedWindowID = windowID
        if let selected = availableWindows.first(where: { $0.id == windowID }) {
            selectedWindowDisplayName = selected.displayName
            selectedWindowSizeDescription = selected.sizeDescription
        }
        thinWidth = max(64, Int(bounds.width.rounded()))
        thinHeight = max(64, Int(bounds.height.rounded()))
        persistSettings()
        restartCaptureSoon()
        statusText = "Imported thin setup at \(thinWidth) x \(thinHeight)."
    }

    private func restartCaptureSoon() {
        pendingCaptureRestart?.cancel()
        guard isLive else { return }
        pendingCaptureRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.startCapture()
        }
    }

    func refreshWindows() {
        Task { await refreshWindows() }
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let minecraftWindows = content.windows.filter { window in
                guard window.owningApplication?.processID != ownPID else { return false }
                return Self.isMinecraftWindow(window)
            }

            shareableWindows = minecraftWindows
            availableWindows = minecraftWindows.map { window in
                return PiechartBetaWindowCandidate(
                    id: window.windowID,
                    displayName: Self.displayName(for: window),
                    sizeDescription: Self.sizeDescription(for: window)
                )
            }

            var shouldSaveSelectedWindow = false
            if selectedWindowID == nil || !availableWindows.contains(where: { $0.id == selectedWindowID }) {
                if let restoredID = restoredWindowID(from: availableWindows) {
                    selectedWindowID = restoredID
                    shouldSaveSelectedWindow = true
                } else {
                    selectedWindowID = availableWindows.first?.id
                    shouldSaveSelectedWindow = selectedWindowDisplayName == nil
                }
            }

            if shouldSaveSelectedWindow,
               let selectedWindowID,
               let selected = availableWindows.first(where: { $0.id == selectedWindowID }) {
                selectedWindowDisplayName = selected.displayName
                selectedWindowSizeDescription = selected.sizeDescription
                persistSettings()
            }

            statusText = availableWindows.isEmpty
                ? "No Minecraft windows found. Open Minecraft, then refresh."
                : "Found \(availableWindows.count) Minecraft window\(availableWindows.count == 1 ? "" : "s")."
        } catch {
            statusText = "Could not list windows. Grant Screen Recording permission, then try again."
        }
    }

    func start() {
        guard !isLive else { return }

        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                statusText = "Screen Recording permission is required for BetterPiechart^2."
                return
            }
        }

        isLive = true
        lastThinModeMatch = false
        lastPreviewUpdateTime = 0
        lastStatusUpdateTime = 0
        projector.show(
            model: projectorModel,
            alwaysOnTop: projectorAlwaysOnTop,
            showTitlebar: projectorShowTitlebar,
            initialFrame: projectorFrame
        )
        projector.setVisible(false)
        statusText = "Starting thin-mode ScreenCaptureKit window capture..."

        Task { await startCapture() }
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        isProjectorVisible = false
        lastThinModeMatch = false
        projector.setVisible(false)
        projectorModel.correctedImage = nil
        projectorModel.entityCounterImage = nil
        rawPiePreview = nil
        correctedPreview = nil
        entityCounterPreview = nil
        lastPreviewUpdateTime = 0
        lastStatusUpdateTime = 0
        pendingCaptureRestart?.cancel()
        pendingCaptureRestart = nil
        statusText = "Stopped."
        detectionText = "Waiting for a thin-mode Minecraft window."

        Task { await stopCapture() }
    }

    private func startCapture() async {
        if shareableWindows.isEmpty {
            await refreshWindows()
        }

        guard isLive else { return }
        guard let window = selectedWindow() ?? shareableWindows.first else {
            isLive = false
            projector.setVisible(false)
            statusText = "No Minecraft window selected."
            return
        }

        if selectedWindowID != window.windowID {
            selectedWindowID = window.windowID
            selectedWindowDisplayName = Self.displayName(for: window)
            selectedWindowSizeDescription = Self.sizeDescription(for: window)
            persistSettings()
        }

        await stopCapture()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let captureGeometry = Self.captureGeometry(
            thinWidth: thinWidth,
            thinHeight: thinHeight
        )
        captureScale = captureGeometry.scale

        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.excludesCurrentProcessAudio = false
        config.scalesToFit = true
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, Int32(projectorFPS.rounded())))
        )
        config.width = captureGeometry.width
        config.height = captureGeometry.height

        let output = PiechartBetaStreamOutput { [weak self] image in
            Task { @MainActor in
                self?.receiveWindowFrame(image)
            }
        } onError: { [weak self] error in
            Task { @MainActor in
                self?.statusText = "Capture stopped: \(error.localizedDescription)"
                self?.isLive = false
                self?.isProjectorVisible = false
                self?.projector.setVisible(false)
            }
        }

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
            streamOutput = output
            statusText = "Watching \(Self.displayName(for: window)) for thin mode near \(thinWidth) x \(thinHeight)."
        } catch {
            isLive = false
            projector.setVisible(false)
            statusText = "Could not start capture: \(error.localizedDescription)"
        }
    }

    private func stopCapture() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
    }

    private func receiveWindowFrame(_ image: CGImage) {
        guard isLive else { return }

        guard let windowID = selectedWindowID,
              let bounds = Self.currentWindowBounds(windowID: windowID)
        else {
            isProjectorVisible = false
            projector.setVisible(false)
            detectionText = "Selected window is no longer available."
            statusText = "Refresh the Minecraft window list."
            return
        }

        let thinModeMatch = Self.matchesThinResolution(
            bounds: bounds,
            thinWidth: thinWidth,
            thinHeight: thinHeight
        )
        lastThinModeMatch = thinModeMatch

        guard thinModeMatch else {
            rawPiePreview = nil
            correctedPreview = nil
            entityCounterPreview = nil
            projectorModel.correctedImage = nil
            projectorModel.entityCounterImage = nil
            isProjectorVisible = false
            projector.setVisible(false)
            detectionText = "Window size \(Int(bounds.width.rounded())) x \(Int(bounds.height.rounded())) is not within ±\(Self.thinTolerance)px of thin mode."
            statusText = "Waiting for the selected Minecraft window to enter thin mode."
            return
        }

        guard let detection = Self.detectThinPie(
            in: image,
            captureScale: captureScale,
            templateHeightRatio: effectiveTemplateHeightRatio,
            cropSize: effectiveCropSize,
            stretchMultiplier: effectiveStretchMultiplier,
            templateCenterNormalized: templateCenterNormalized,
            entityCounterYOffset: entityCounterYOffset
        ) else {
            if CFAbsoluteTimeGetCurrent() - lastDetectionTime > 0.5 {
                rawPiePreview = nil
                correctedPreview = nil
                entityCounterPreview = nil
                projectorModel.correctedImage = nil
                projectorModel.entityCounterImage = nil
                isProjectorVisible = false
                projector.setVisible(false)
                detectionText = "No pie detected in the thin-mode crop yet."
                statusText = "Thin mode detected. Open F3 with the piechart visible."
            }
            return
        }

        lastDetectionTime = CFAbsoluteTimeGetCurrent()
        projectorModel.correctedImage = detection.correctedImage
        projectorModel.entityCounterImage = detection.entityCounterImage
        applyProjectorVisibility()

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPreviewUpdateTime >= (1.0 / 15.0) {
            lastPreviewUpdateTime = now
            rawPiePreview = detection.rawCrop
            correctedPreview = detection.correctedImage
            entityCounterPreview = detection.entityCounterImage
        }

        if now - lastStatusUpdateTime >= 0.25 {
            lastStatusUpdateTime = now
            detectionText = String(
                format: "Thin crop %.0f, %.0f  %.0f x %.0f | template %.2fx | crop %.2fx | fit %.2fx",
                detection.cropRect.minX,
                detection.cropRect.minY,
                detection.cropRect.width,
                detection.cropRect.height,
                templateHeightScale,
                cropSizeScale,
                stretchMultiplierScale
            )
            statusText = "Thin mode detected. Projector is open."
        }
    }

    private func refreshFromCurrentPreview() {
        guard let rawPiePreview,
              let corrected = Self.correctedThinPieImage(
                from: rawPiePreview,
                templateHeightRatio: effectiveTemplateHeightRatio,
                cropSize: effectiveCropSize,
                stretchMultiplier: effectiveStretchMultiplier,
                templateCenterNormalized: templateCenterNormalized
              ) else {
            return
        }

        correctedPreview = corrected
        projectorModel.correctedImage = corrected
        projectorModel.entityCounterImage = entityCounterPreview
        applyProjectorVisibility()
        statusText = "Updated BetterPiechart^2 fit."
    }

    private func applyProjectorVisibility() {
        let shouldShow = isLive && lastThinModeMatch && projectorModel.correctedImage != nil
        isProjectorVisible = shouldShow
        projector.setVisible(shouldShow)
    }

    private func selectedWindow() -> SCWindow? {
        guard let selectedWindowID else { return nil }
        return shareableWindows.first { $0.windowID == selectedWindowID }
    }

    private func restoredWindowID(from windows: [PiechartBetaWindowCandidate]) -> CGWindowID? {
        if let selectedWindowDisplayName,
           let selectedWindowSizeDescription,
           let exact = windows.first(where: {
               $0.displayName == selectedWindowDisplayName &&
               $0.sizeDescription == selectedWindowSizeDescription
           }) {
            return exact.id
        }

        if let selectedWindowDisplayName,
           let nameMatch = windows.first(where: { $0.displayName == selectedWindowDisplayName }) {
            return nameMatch.id
        }

        return nil
    }

    private func loadPersistedSettings() {
        guard let settings = Self.loadSettingsFromDefaults() else {
            return
        }

        projectorAlwaysOnTop = settings.projectorAlwaysOnTop
        projectorShowTitlebar = settings.projectorShowTitlebar
        projectorFPS = Self.clampedProjectorFPS(settings.projectorFPS)
        projectorFrame = settings.projectorFrame?.cgRect
        selectedWindowDisplayName = settings.selectedWindowDisplayName
        selectedWindowSizeDescription = settings.selectedWindowSizeDescription
        thinWidth = settings.thinWidth
        thinHeight = settings.thinHeight
        entityCounterYOffset = min(90, max(20, settings.entityCounterYOffset))
        templateHeightScale = min(1.80, max(0.60, settings.templateHeightScale))
        cropSizeScale = min(2.20, max(0.80, settings.cropSizeScale))
        stretchMultiplierScale = min(1.45, max(0.70, settings.stretchMultiplierScale))
        templateCenterNormalized = Self.clampedNormalizedPoint(
            CGPoint(x: settings.templateCenterX, y: settings.templateCenterY)
        )
        persistSettings()
    }

    private static func loadSettingsFromDefaults() -> PiechartBetaPersistedSettings? {
        let defaults = UserDefaults.standard
        for key in [betaSettingsKey] + legacySettingsKeys {
            guard let data = defaults.data(forKey: key),
                  let settings = try? JSONDecoder().decode(PiechartBetaPersistedSettings.self, from: data) else {
                continue
            }
            return settings
        }

        return nil
    }

    private func persistSettings() {
        let settings = PiechartBetaPersistedSettings(
            projectorAlwaysOnTop: projectorAlwaysOnTop,
            projectorShowTitlebar: projectorShowTitlebar,
            projectorFPS: projectorFPS,
            projectorFrame: projector.frame.map { PersistedRect($0) } ?? projectorFrame.map { PersistedRect($0) },
            selectedWindowDisplayName: selectedWindowDisplayName,
            selectedWindowSizeDescription: selectedWindowSizeDescription,
            thinWidth: thinWidth,
            thinHeight: thinHeight,
            entityCounterYOffset: entityCounterYOffset,
            templateHeightScale: templateHeightScale,
            cropSizeScale: cropSizeScale,
            stretchMultiplierScale: stretchMultiplierScale,
            templateCenterX: templateCenterNormalized.x,
            templateCenterY: templateCenterNormalized.y
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.betaSettingsKey)
        defaults.synchronize()
    }

    private static func displayName(for window: SCWindow) -> String {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        let joined = [appName, title]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return joined.isEmpty ? "Window \(window.windowID)" : joined
    }

    private static func sizeDescription(for window: SCWindow) -> String {
        let width = Int(window.frame.width.rounded())
        let height = Int(window.frame.height.rounded())
        return "\(width) x \(height)"
    }

    private static func clampedProjectorFPS(_ value: Double) -> Double {
        min(120, max(10, value.rounded()))
    }

    private static func isMinecraftWindow(_ window: SCWindow) -> Bool {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        let combined = "\(appName) \(title)".lowercased()
        guard combined.contains("minecraft") else { return false }
        return !combined.contains("launcher")
    }

    private static func captureGeometry(thinWidth: Int, thinHeight: Int) -> (width: Int, height: Int, scale: Double) {
        let screenScale = max(1.0, NSScreen.main?.backingScaleFactor ?? 1)
        let factor = min(screenScale, 16384.0 / max(1, Double(thinHeight)))
        let width = max(1, Int((Double(thinWidth) * factor).rounded()))
        let height = max(1, Int((Double(thinHeight) * factor).rounded()))
        let scale = Double(max(1, min(2, Int(factor.rounded(.down)))))
        return (width, height, scale)
    }

    private static func currentWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }
        return bounds
    }

    private static func matchesThinResolution(bounds: CGRect, thinWidth: Int, thinHeight: Int) -> Bool {
        abs(Int(bounds.width.rounded()) - thinWidth) <= thinTolerance &&
        abs(Int(bounds.height.rounded()) - thinHeight) <= thinTolerance
    }

    private static func detectThinPie(
        in image: CGImage,
        captureScale: Double,
        templateHeightRatio: Double,
        cropSize: Double,
        stretchMultiplier: Double,
        templateCenterNormalized: CGPoint,
        entityCounterYOffset: Double
    ) -> PiechartBetaDetection? {
        let factor = max(1, min(2, Int(captureScale.rounded(.down))))
        let cropWidth = min(image.width, 340 * factor)
        let cropHeight = min(image.height, 340 * factor)
        let cropX = max(0, image.width - cropWidth)
        let cropY = max(0, image.height - cropHeight - (100 * factor))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        guard let rawCrop = image.cropping(to: cropRect.integral) else { return nil }
        let entityCounterImage = entityCounterCrop(
            in: image,
            factor: factor,
            yOffset: entityCounterYOffset
        )
        guard let corrected = correctedThinPieImage(
                from: rawCrop,
                templateHeightRatio: templateHeightRatio,
                cropSize: cropSize,
                stretchMultiplier: stretchMultiplier,
                templateCenterNormalized: templateCenterNormalized
              ) else {
            return nil
        }

        return PiechartBetaDetection(
            rawCrop: rawCrop,
            correctedImage: corrected,
            entityCounterImage: entityCounterImage,
            cropRect: cropRect
        )
    }

    private static func entityCounterCrop(
        in image: CGImage,
        factor: Int,
        yOffset: Double
    ) -> CGImage? {
        let counterWidth = min(image.width, 67 * factor)
        let counterHeight = min(image.height, 9 * factor)
        let counterX = min(max(0, 1 * factor), max(0, image.width - counterWidth))
        let counterY = min(
            max(0, Int((yOffset * Double(factor)).rounded())),
            max(0, image.height - counterHeight)
        )
        let cropRect = CGRect(x: counterX, y: counterY, width: counterWidth, height: counterHeight).integral
        return image.cropping(to: cropRect)
    }

    private static func correctedThinPieImage(
        from rawImage: CGImage,
        templateHeightRatio: Double,
        cropSize: Double,
        stretchMultiplier: Double,
        templateCenterNormalized: CGPoint
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: rawImage.width, height: rawImage.height)
        let effectiveRect = expandedCaptureRect(
            in: bounds,
            cropSize: cropSize,
            templateHeightRatio: templateHeightRatio,
            stretchMultiplier: stretchMultiplier,
            templateCenterNormalized: templateCenterNormalized,
            desktopBounds: bounds
        )

        guard let tightened = rawImage.cropping(to: effectiveRect.integral) else {
            return nil
        }

        return correctedPieImage(
            from: tightened,
            templateHeightRatio: templateHeightRatio,
            stretchMultiplier: stretchMultiplier
        )
    }

    private static func expandedCaptureRect(
        in rect: CGRect,
        cropSize: Double,
        templateHeightRatio: Double,
        stretchMultiplier: Double,
        templateCenterNormalized: CGPoint,
        desktopBounds: CGRect
    ) -> CGRect {
        let croppedRect = centeredCropRect(
            in: rect,
            cropSize: cropSize,
            centerNormalized: templateCenterNormalized
        )
        let safeTemplateHeightRatio = max(0.08, templateHeightRatio)
        let verticalUnsquash = (1.0 / safeTemplateHeightRatio) * stretchMultiplier

        let desiredWidth = max(croppedRect.width, croppedRect.height * verticalUnsquash)
        let desiredHeight = croppedRect.height

        let expandedRect = CGRect(
            x: croppedRect.midX - (desiredWidth * 0.5),
            y: croppedRect.midY - (desiredHeight * 0.5),
            width: desiredWidth,
            height: desiredHeight
        )

        return expandedRect.intersection(desktopBounds)
    }

    private static func centeredCropRect(
        in rect: CGRect,
        cropSize: Double,
        centerNormalized: CGPoint
    ) -> CGRect {
        let clampedCrop = min(max(cropSize, 0.35), 1.0)
        let width = rect.width * clampedCrop
        let height = rect.height * clampedCrop
        let clampedCenter = clampedNormalizedPoint(centerNormalized)
        let centerX = rect.minX + (rect.width * clampedCenter.x)
        let centerY = rect.minY + (rect.height * clampedCenter.y)
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX - width
        let maxY = rect.maxY - height
        return CGRect(
            x: min(max(minX, centerX - (width * 0.5)), maxX),
            y: min(max(minY, centerY - (height * 0.5)), maxY),
            width: width,
            height: height
        )
    }

    private static func correctedPieImage(
        from rawImage: CGImage,
        templateHeightRatio: Double,
        stretchMultiplier: Double
    ) -> CGImage? {
        let sourceWidth = rawImage.width
        let sourceHeight = rawImage.height
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }

        let safeTemplateHeightRatio = max(0.08, templateHeightRatio)
        let verticalUnsquash = (1.0 / safeTemplateHeightRatio) * stretchMultiplier
        let scaledHeight = max(1, Int((Double(sourceHeight) * verticalUnsquash).rounded()))
        let stretchedWidth = sourceWidth
        let squareSide = max(stretchedWidth, scaledHeight)

        guard let context = CGContext(
            data: nil,
            width: squareSide,
            height: squareSide,
            bitsPerComponent: 8,
            bytesPerRow: squareSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: squareSide, height: squareSide))
        context.interpolationQuality = .none

        let drawRect = CGRect(
            x: CGFloat(squareSide - stretchedWidth) * 0.5,
            y: CGFloat(squareSide - scaledHeight) * 0.5,
            width: CGFloat(stretchedWidth),
            height: CGFloat(scaledHeight)
        )
        context.draw(rawImage, in: drawRect)
        return context.makeImage()
    }

    private static func clampedNormalizedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1.0, max(0.0, point.x)),
            y: min(1.0, max(0.0, point.y))
        )
    }
}

private final class PiechartBetaStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (CGImage) -> Void
    private let onError: (Error) -> Void

    init(onFrame: @escaping (CGImage) -> Void, onError: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if let cgImage {
            onFrame(cgImage)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else { return false }

        return status == .complete
    }
}

struct BetterPiechartBetaToolView: View {
    @ObservedObject var state: PiechartBetaState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "BetterPiechart^2 (Beta)", subtitle: "Thin-mode auto projector for the F3 piechart.")

            Button(action: state.toggle) {
                Label(state.primaryToggleTitle, systemImage: state.isLive ? "stop.fill" : "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryMonoButtonStyle(active: state.isLive))

            SectionBox(title: "Thin Setup") {
                HStack {
                    Stepper("Width: \(state.thinWidth)", value: Binding(
                        get: { state.thinWidth },
                        set: { state.setThinWidth($0) }
                    ), in: 64...4096)
                    Stepper("Height: \(state.thinHeight)", value: Binding(
                        get: { state.thinHeight },
                        set: { state.setThinHeight($0) }
                    ), in: 64...16384)
                }

                Text("Toggle your Thin mode and click Import Thin Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Import Thin Setup") {
                    state.importThinSetup()
                }
                .buttonStyle(.bordered)
            }

            SectionBox(title: "Minecraft Window") {
                HStack {
                    Picker("Window", selection: Binding(
                        get: { state.selectedWindowID ?? 0 },
                        set: { state.setSelectedWindowID($0 == 0 ? nil : $0) }
                    )) {
                        if state.availableWindows.isEmpty {
                            Text("No Minecraft windows").tag(CGWindowID(0))
                        } else {
                            ForEach(state.availableWindows) { window in
                                Text("\(window.displayName)  \(window.sizeDescription)").tag(window.id)
                            }
                        }
                    }
                    Button {
                        state.refreshWindows()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            SectionBox(title: "Projector") {
                Toggle("Always On Top", isOn: Binding(
                    get: { state.projectorAlwaysOnTop },
                    set: { state.setProjectorAlwaysOnTop($0) }
                ))
                Toggle("Show Titlebar", isOn: Binding(
                    get: { state.projectorShowTitlebar },
                    set: { state.setProjectorShowTitlebar($0) }
                ))
                SliderRow(
                    title: "Projector FPS",
                    value: Binding(
                        get: { state.projectorFPS },
                        set: { state.setProjectorFPS($0) }
                    ),
                    range: 10...120,
                    suffix: "fps"
                )
                SliderRow(
                    title: "Entity Counter Y",
                    value: Binding(
                        get: { state.entityCounterYOffset },
                        set: { state.setEntityCounterYOffset($0) }
                    ),
                    range: 20...90,
                    suffix: "px"
                )
            }

            SectionBox(title: "Projector Fit") {
                HStack {
                    Text("Template Height")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2fx", state.templateHeightScale))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.templateHeightScale },
                        set: { state.updateTemplateHeightScale($0) }
                    ),
                    in: 0.60...1.80,
                    step: 0.01
                )

                HStack {
                    Text("Crop Size")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2fx", state.cropSizeScale))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.cropSizeScale },
                        set: { state.updateCropSizeScale($0) }
                    ),
                    in: 0.80...2.20,
                    step: 0.01
                )

                HStack {
                    Text("Circle Fit")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2fx", state.stretchMultiplierScale))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { state.stretchMultiplierScale },
                        set: { state.updateStretchMultiplierScale($0) }
                    ),
                    in: 0.70...1.45,
                    step: 0.01
                )
            }

            SectionBox(title: "Previews") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Thin Pie Crop")
                        .font(.headline)
                    PiechartBetaTemplatePreviewCard(
                        image: state.rawPiePreview,
                        templateHeightRatio: state.effectiveTemplateHeightRatio,
                        templateCenterNormalized: state.templateCenterNormalized,
                        onTemplateCenterChanged: state.updateTemplateCenter
                    )
                        .frame(height: 170)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Rounded Pie")
                        .font(.headline)
                    CorrectedPiePreviewCard(image: state.correctedPreview)
                        .frame(height: 180)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Entity Counter")
                        .font(.headline)
                    PiechartBetaEntityCounterPreviewCard(image: state.entityCounterPreview)
                        .frame(height: 70)
                }
            }

            Text(state.detectionText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await state.refreshWindows()
        }
    }
}

struct PiechartBetaEntityCounterPreviewCard: View {
    var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black)

            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            } else {
                Text("No entity counter yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PiechartBetaTemplatePreviewCard: View {
    var image: CGImage?
    var templateHeightRatio: Double
    var templateCenterNormalized: CGPoint
    var onTemplateCenterChanged: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)

                if let image {
                    let inset: CGFloat = 12
                    let availableWidth = max(1, proxy.size.width - (inset * 2))
                    let availableHeight = max(1, proxy.size.height - (inset * 2))
                    let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    let containerAspect = availableWidth / availableHeight
                    let drawSize: CGSize = {
                        if imageAspect > containerAspect {
                            let width = availableWidth
                            return CGSize(width: width, height: width / imageAspect)
                        } else {
                            let height = availableHeight
                            return CGSize(width: height * imageAspect, height: height)
                        }
                    }()
                    let origin = CGPoint(
                        x: (proxy.size.width - drawSize.width) * 0.5,
                        y: (proxy.size.height - drawSize.height) * 0.5
                    )
                    let center = CGPoint(
                        x: origin.x + (drawSize.width * templateCenterNormalized.x),
                        y: origin.y + (drawSize.height * templateCenterNormalized.y)
                    )

                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: drawSize.width, height: drawSize.height)
                        .position(x: origin.x + (drawSize.width * 0.5), y: origin.y + (drawSize.height * 0.5))

                    Ellipse()
                        .stroke(Color.yellow.opacity(0.95), lineWidth: 2)
                        .frame(width: drawSize.width * 0.96, height: drawSize.width * templateHeightRatio)
                        .position(center)

                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 8, height: 8)
                        .position(center)

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let normalized = CGPoint(
                                        x: (value.location.x - origin.x) / max(1, drawSize.width),
                                        y: (value.location.y - origin.y) / max(1, drawSize.height)
                                    )
                                    onTemplateCenterChanged(normalized)
                                }
                        )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "scope")
                            .font(.system(size: 28))
                        Text("Start the beta projector to move the pie template.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
