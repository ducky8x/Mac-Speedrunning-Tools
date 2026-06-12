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
    var projectorAlwaysOnTop: Bool
    var projectorShowTitlebar: Bool
    var projectorFPS: Double
    var thinWidth: Int
    var thinHeight: Int
    var templateHeightScale: Double
    var cropSizeScale: Double
    var stretchMultiplierScale: Double
    var templateCenterX: Double
    var templateCenterY: Double
}

private struct PiechartBetaDetection {
    let rawCrop: CGImage
    let correctedImage: CGImage
    let cropRect: CGRect
    let visibilityScore: Double
}

@MainActor
final class PiechartBetaState: ObservableObject {
    private static let betaSettingsKey = "mts.piechartbeta.settings.v2"
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
    @Published var statusText = "Set your thin resolution, refresh Minecraft windows, then start the thin projector."
    @Published var detectionText = "Waiting for a thin-mode Minecraft window."
    @Published var projectorFPS = 60.0
    @Published var thinWidth = 384
    @Published var thinHeight = 1080
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
    private var pendingCaptureRestart: Task<Void, Never>?
    private var projectorEnabledByShortcut = true
    private var lastThinModeMatch = false

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
    }

    func toggle() {
        isLive ? stop() : start()
    }

    func toggleProjectorVisibility() {
        guard isLive else { return }
        projectorEnabledByShortcut.toggle()
        applyProjectorVisibility()
        statusText = projectorEnabledByShortcut
            ? "Projector will appear automatically when the selected window is in thin mode."
            : "Projector hidden until you toggle it back on."
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
        projectorFPS = value.rounded()
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

    func updateTemplateHeightScale(_ value: Double) {
        templateHeightScale = value
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateCropSizeScale(_ value: Double) {
        cropSizeScale = value
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateStretchMultiplierScale(_ value: Double) {
        stretchMultiplierScale = value
        persistSettings()
        refreshFromCurrentPreview()
    }

    func updateTemplateCenter(_ normalizedPoint: CGPoint) {
        templateCenterNormalized = Self.clampedNormalizedPoint(normalizedPoint)
        persistSettings()
        refreshFromCurrentPreview()
    }

    func importThinSetup() {
        let windowID = selectedWindowID ?? shareableWindows.first?.windowID
        guard let windowID,
              let bounds = Self.currentWindowBounds(windowID: windowID) else {
            statusText = "Select a Minecraft window first, then import the thin setup."
            return
        }

        selectedWindowID = windowID
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
                let width = Int(window.frame.width.rounded())
                let height = Int(window.frame.height.rounded())
                return PiechartBetaWindowCandidate(
                    id: window.windowID,
                    displayName: Self.displayName(for: window),
                    sizeDescription: "\(width) x \(height)"
                )
            }

            if selectedWindowID == nil || !availableWindows.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = availableWindows.first?.id
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
        projectorEnabledByShortcut = true
        lastThinModeMatch = false
        projector.show(
            model: projectorModel,
            alwaysOnTop: projectorAlwaysOnTop,
            showTitlebar: projectorShowTitlebar
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
        rawPiePreview = nil
        correctedPreview = nil
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
            projectorModel.correctedImage = nil
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
            templateCenterNormalized: templateCenterNormalized
        ) else {
            if CFAbsoluteTimeGetCurrent() - lastDetectionTime > 0.5 {
                rawPiePreview = nil
                correctedPreview = nil
                projectorModel.correctedImage = nil
                isProjectorVisible = false
                projector.setVisible(false)
                detectionText = "No pie detected in the thin-mode crop yet."
                statusText = "Thin mode detected. Open F3 with the piechart visible."
            }
            return
        }

        lastDetectionTime = CFAbsoluteTimeGetCurrent()
        rawPiePreview = detection.rawCrop
        correctedPreview = detection.correctedImage
        projectorModel.correctedImage = detection.correctedImage
        applyProjectorVisibility()
        detectionText = String(
            format: "Thin crop %.0f, %.0f  %.0f x %.0f | score %.2f | template %.2fx | crop %.2fx | fit %.2fx",
            detection.cropRect.minX,
            detection.cropRect.minY,
            detection.cropRect.width,
            detection.cropRect.height,
            detection.visibilityScore,
            templateHeightScale,
            cropSizeScale,
            stretchMultiplierScale
        )
        statusText = "Thin mode detected. Pie projector ready."
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
        applyProjectorVisibility()
        statusText = "Updated BetterPiechart^2 fit."
    }

    private func applyProjectorVisibility() {
        let shouldShow = isLive && projectorEnabledByShortcut && lastThinModeMatch && projectorModel.correctedImage != nil
        isProjectorVisible = shouldShow
        projector.setVisible(shouldShow)
    }

    private func selectedWindow() -> SCWindow? {
        guard let selectedWindowID else { return nil }
        return shareableWindows.first { $0.windowID == selectedWindowID }
    }

    private func loadPersistedSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.betaSettingsKey),
              let settings = try? JSONDecoder().decode(PiechartBetaPersistedSettings.self, from: data) else {
            return
        }

        projectorAlwaysOnTop = settings.projectorAlwaysOnTop
        projectorShowTitlebar = settings.projectorShowTitlebar
        projectorFPS = settings.projectorFPS
        thinWidth = settings.thinWidth
        thinHeight = settings.thinHeight
        templateHeightScale = settings.templateHeightScale
        cropSizeScale = settings.cropSizeScale
        stretchMultiplierScale = settings.stretchMultiplierScale
        templateCenterNormalized = Self.clampedNormalizedPoint(
            CGPoint(x: settings.templateCenterX, y: settings.templateCenterY)
        )
    }

    private func persistSettings() {
        let settings = PiechartBetaPersistedSettings(
            projectorAlwaysOnTop: projectorAlwaysOnTop,
            projectorShowTitlebar: projectorShowTitlebar,
            projectorFPS: projectorFPS,
            thinWidth: thinWidth,
            thinHeight: thinHeight,
            templateHeightScale: templateHeightScale,
            cropSizeScale: cropSizeScale,
            stretchMultiplierScale: stretchMultiplierScale,
            templateCenterX: templateCenterNormalized.x,
            templateCenterY: templateCenterNormalized.y
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.betaSettingsKey)
    }

    private static func displayName(for window: SCWindow) -> String {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        let joined = [appName, title]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return joined.isEmpty ? "Window \(window.windowID)" : joined
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
        templateCenterNormalized: CGPoint
    ) -> PiechartBetaDetection? {
        let factor = max(1, min(2, Int(captureScale.rounded(.down))))
        let cropWidth = min(image.width, 340 * factor)
        let cropHeight = min(image.height, 340 * factor)
        let cropX = max(0, image.width - cropWidth)
        let cropY = max(0, image.height - cropHeight - (100 * factor))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        guard let rawCrop = image.cropping(to: cropRect.integral) else { return nil }
        let visibilityScore = pieVisibilityScore(for: rawCrop, templateHeightRatio: templateHeightRatio)
        guard visibilityScore >= 0.58,
              let corrected = correctedThinPieImage(
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
            cropRect: cropRect,
            visibilityScore: visibilityScore
        )
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

    private static func pieVisibilityScore(for image: CGImage, templateHeightRatio: Double) -> Double {
        guard let provider = image.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return 0
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let centerX = Double(width) * 0.5
        let centerY = Double(height) * 0.5
        let radiusX = Double(width) * 0.47
        let radiusY = min(Double(height) * 0.47, radiusX * max(0.08, templateHeightRatio))
        let step = max(1, min(width, height) / 80)

        var insideCount = 0.0
        var filledCount = 0.0
        var saturatedCount = 0.0
        var hueBins = Array(repeating: 0.0, count: 12)

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let nx = (Double(x) - centerX) / radiusX
                let ny = (Double(y) - centerY) / radiusY
                if (nx * nx) + (ny * ny) <= 1.0 {
                    insideCount += 1
                    let offset = y * bytesPerRow + x * 4
                    let blue = Double(bytes[offset]) / 255.0
                    let green = Double(bytes[offset + 1]) / 255.0
                    let red = Double(bytes[offset + 2]) / 255.0
                    let maxChannel = max(red, green, blue)
                    let minChannel = min(red, green, blue)
                    let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
                    let brightness = maxChannel
                    if brightness > 0.14 {
                        filledCount += 1
                    }
                    if saturation > 0.16 && brightness > 0.18 && brightness < 0.98 {
                        saturatedCount += 1
                        let hue = hue(red: red, green: green, blue: blue)
                        let bin = min(hueBins.count - 1, max(0, Int((hue * Double(hueBins.count)).rounded(.down))))
                        hueBins[bin] += 1
                    }
                }
                x += step
            }
            y += step
        }

        let fillCoverage = insideCount > 0 ? filledCount / insideCount : 0
        let significantHueBins = hueBins.filter { saturatedCount > 0 ? ($0 / saturatedCount) > 0.08 : false }.count

        let midlineRows = [-0.18, -0.06, 0.06, 0.18]
        var rowCoverageSum = 0.0
        var rowCoverageCount = 0.0

        for relativeY in midlineRows {
            let sampleY = Int((centerY + (radiusY * relativeY)).rounded())
            guard (0..<height).contains(sampleY) else { continue }

            var rowInside = 0.0
            var rowFilled = 0.0
            var sampleX = 0
            while sampleX < width {
                let nx = (Double(sampleX) - centerX) / radiusX
                let ny = (Double(sampleY) - centerY) / radiusY
                if (nx * nx) + (ny * ny) <= 1.0 {
                    rowInside += 1
                    let brightness = pixelBrightness(bytes: bytes, bytesPerRow: bytesPerRow, x: sampleX, y: sampleY)
                    if brightness > 0.14 {
                        rowFilled += 1
                    }
                }
                sampleX += step
            }

            if rowInside > 0 {
                rowCoverageSum += rowFilled / rowInside
                rowCoverageCount += 1
            }
        }

        let midlineCoverage = rowCoverageCount > 0 ? rowCoverageSum / rowCoverageCount : 0
        guard fillCoverage > 0.42, midlineCoverage > 0.48, significantHueBins >= 2 else {
            return 0
        }

        let borderSamples = 48
        var borderContrast = 0.0
        var borderCount = 0.0

        for sampleIndex in 0..<borderSamples {
            let angle = (Double(sampleIndex) / Double(borderSamples)) * Double.pi * 2.0
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)

            let innerX = Int((centerX + (radiusX * 0.94 * cosAngle)).rounded())
            let innerY = Int((centerY + (radiusY * 0.94 * sinAngle)).rounded())
            let outerX = Int((centerX + (radiusX * 1.05 * cosAngle)).rounded())
            let outerY = Int((centerY + (radiusY * 1.05 * sinAngle)).rounded())

            guard (0..<width).contains(innerX),
                  (0..<height).contains(innerY),
                  (0..<width).contains(outerX),
                  (0..<height).contains(outerY) else {
                continue
            }

            let innerBrightness = pixelBrightness(bytes: bytes, bytesPerRow: bytesPerRow, x: innerX, y: innerY)
            let outerBrightness = pixelBrightness(bytes: bytes, bytesPerRow: bytesPerRow, x: outerX, y: outerY)
            borderContrast += abs(innerBrightness - outerBrightness)
            borderCount += 1
        }

        let normalizedBorderContrast = borderCount > 0 ? borderContrast / borderCount : 0
        return (fillCoverage * 0.45) + (midlineCoverage * 0.35) + (normalizedBorderContrast * 1.25)
    }

    private static func pixelBrightness(
        bytes: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> Double {
        let offset = y * bytesPerRow + x * 4
        let blue = Double(bytes[offset]) / 255.0
        let green = Double(bytes[offset + 1]) / 255.0
        let red = Double(bytes[offset + 2]) / 255.0
        return max(red, green, blue)
    }

    private static func hue(red: Double, green: Double, blue: Double) -> Double {
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel
        guard delta > 0.0001 else { return 0 }

        let hue: Double
        if maxChannel == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxChannel == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }

        let normalized = hue / 6.0
        return normalized >= 0 ? normalized : normalized + 1.0
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

            ToolKeybindSection(section: .piechartBeta)

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
                        set: { state.selectedWindowID = $0 == 0 ? nil : $0 }
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
