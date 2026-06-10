import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct ScreenRegion: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect

    var label: String {
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        return "\(x), \(y)  \(width)x\(height)"
    }
}

struct CaptureFrame: @unchecked Sendable {
    var rawImage: CGImage
    var correctedImage: CGImage
}

struct DetectionFrame: @unchecked Sendable {
    var frame: CaptureFrame
    var visibilityScore: Double
}

enum ProjectorTriggerMode: String, CaseIterable, Identifiable {
    case autoPiechartDetection
    case keybindToggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoPiechartDetection:
            return "Auto piechart detection"
        case .keybindToggle:
            return "Keybind toggle"
        }
    }
}

struct PersistedRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PersistedSettings: Codable {
    var projectorAlwaysOnTop: Bool
    var projectorShowTitlebar: Bool
    var projectorTriggerMode: String
    var projectorFrame: PersistedRect?
    var pieRegion: PersistedRect?
    var templateHeightRatio: Double
    var cropSize: Double
    var stretchMultiplier: Double
    var projectorToggleKeyCode: UInt16?
    var keybindLabel: String
}

@MainActor
final class ProjectorModel: ObservableObject {
    @Published var correctedImage: CGImage?
}

@MainActor
final class PiechartState: ObservableObject {
    private static let settingsKey = "mts.settings.v1"
    private static let defaultTemplateHeightRatio = 0.56
    private static let defaultCropSize = 1.00
    private static let defaultStretchMultiplier = 1.00

    @Published var isLive = false
    @Published private(set) var isProjectorVisible = false
    @Published var projectorAlwaysOnTop = true
    @Published var projectorShowTitlebar = false
    @Published var projectorTriggerMode: ProjectorTriggerMode = .autoPiechartDetection
    @Published var projectorFrame: CGRect?
    @Published var pieRegion: ScreenRegion?
    @Published var templateHeightRatio = PiechartState.defaultTemplateHeightRatio
    @Published var cropSize = PiechartState.defaultCropSize
    @Published var stretchMultiplier = PiechartState.defaultStretchMultiplier
    @Published var awaitingKeybindCapture = false
    @Published var keybindLabel = "Not set"
    @Published var rawPreview: CGImage?
    @Published var correctedPreview: CGImage?
    @Published var statusText = "Select the squashed pie area, then start capture."

    private let projector = ProjectorWindowController()
    private let projectorModel = ProjectorModel()
    private let alignmentWindow = PieAlignmentWindowController()
    private var liveTimer: Timer?
    private var isProcessingFrame = false
    private var captureGeneration = 0
    private var projectorToggleKeyCode: UInt16?
    private var keybindProjectorEnabled = false

    var primaryToggleTitle: String {
        if isLive { return "Stop" }
        if pieRegion == nil { return "Select Pie" }
        return "Start"
    }

    init() {
        alignmentWindow.onContentFrameChange = { [weak self] rect in
            Task { @MainActor in
                guard let self else { return }
                self.pieRegion = ScreenRegion(rect: rect)
                self.persistSettings()
                if !self.isLive {
                    self.statusText = "Pie area aligned at \(self.pieRegion?.label ?? "")."
                }
            }
        }
        projector.onFrameChange = { [weak self] frame in
            self?.projectorFrame = frame
            self?.persistSettings()
        }
        loadPersistedSettings()
        projectorTriggerMode = .autoPiechartDetection
        keybindProjectorEnabled = true
        alignmentWindow.updateTemplateHeightRatio(templateHeightRatio)
    }

    func toggleLive() {
        isLive ? stopLive() : startLive()
    }

    func toggleProjector() {
        if isLive {
            stopLive()
        } else if pieRegion == nil {
            selectPieRegion()
        } else {
            startLive()
        }
    }

    func toggleProjectorVisibility() {
        guard isLive else { return }
        isProjectorVisible.toggle()
        projector.setVisible(isProjectorVisible)
        statusText = isProjectorVisible
            ? "Projector visible. Capture is running."
            : "Projector hidden. Capture is still running."
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

    func setProjectorTriggerMode(_ value: ProjectorTriggerMode) {
        projectorTriggerMode = value
        if value == .autoPiechartDetection {
            awaitingKeybindCapture = false
            keybindProjectorEnabled = true
            isProjectorVisible = isLive
            projector.setVisible(isProjectorVisible)
        } else {
            keybindProjectorEnabled = false
            isProjectorVisible = false
            projector.setVisible(false)
        }
        persistSettings()
    }

    func updateStretchMultiplier(_ value: Double) {
        stretchMultiplier = value
        persistSettings()
        if isLive {
            liveTick()
        } else if rawPreview != nil {
            refreshFromCurrentPreview()
        }
    }

    func updateTemplateHeightRatio(_ value: Double) {
        templateHeightRatio = value
        alignmentWindow.updateTemplateHeightRatio(value)
        persistSettings()
        if isLive {
            liveTick()
        } else if rawPreview != nil {
            refreshFromCurrentPreview()
        }
    }

    func updateCropSize(_ value: Double) {
        cropSize = value
        persistSettings()
        if isLive {
            liveTick()
        } else if rawPreview != nil {
            refreshFromCurrentPreview()
        }
    }

    func selectPieRegion() {
        if isLive {
            stopLive()
        }

        alignmentWindow.show(
            templateHeightRatio: templateHeightRatio,
            initialContentFrame: pieRegion?.rect
        )
        statusText = "Move and resize the transparent guide window until the ellipse matches the pie."
    }

    func clearRegion() {
        pieRegion = nil
        rawPreview = nil
        correctedPreview = nil
        projectorModel.correctedImage = nil
        isProjectorVisible = false
        projector.setVisible(false)
        alignmentWindow.hide()
        persistSettings()
        statusText = "Cleared the pie area."
    }

    func startLive() {
        if let contentFrame = alignmentWindow.currentContentFrame {
            pieRegion = ScreenRegion(rect: contentFrame)
            persistSettings()
        }

        guard pieRegion != nil else {
            statusText = "Select a pie area first."
            return
        }

        alignmentWindow.hide()
        projector.show(
            model: projectorModel,
            alwaysOnTop: projectorAlwaysOnTop,
            showTitlebar: projectorShowTitlebar,
            initialFrame: projectorFrame
        )
        if projectorModel.correctedImage == nil {
            projectorModel.correctedImage = correctedPreview
        }
        isLive = true
        captureGeneration += 1
        keybindProjectorEnabled = true
        isProjectorVisible = false
        projector.setVisible(false)
        statusText = "Capture started hidden. Press its keybind to show the projector."
        liveTick()
        scheduleLiveTimer()
    }

    func stopLive() {
        isLive = false
        captureGeneration += 1
        liveTimer?.invalidate()
        liveTimer = nil
        isProcessingFrame = false
        isProjectorVisible = false
        projector.setVisible(false)
        statusText = "Stopped."
    }

    private func scheduleLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.liveTick()
            }
        }
    }

    private func liveTick() {
        guard !isProcessingFrame, let pieRegion else { return }
        isProcessingFrame = true

        let projectorFrame = projector.frame
        let desktopBounds = Self.desktopBounds()
        let region = pieRegion.rect
        let cropSize = cropSize
        let templateHeightRatio = templateHeightRatio
        let stretchMultiplier = stretchMultiplier
        let generation = captureGeneration

        Task { [weak self] in
            let detection = await Task.detached(priority: .userInitiated) { () -> DetectionFrame? in
                guard let rawImage = Self.captureScreenImage(
                    region: region,
                    cropSize: cropSize,
                    templateHeightRatio: templateHeightRatio,
                    stretchMultiplier: stretchMultiplier,
                    projectorFrame: projectorFrame,
                    desktopBounds: desktopBounds
                ),
                let correctedImage = Self.correctedPieImage(
                    from: rawImage,
                    templateHeightRatio: templateHeightRatio,
                    stretchMultiplier: stretchMultiplier
                ) else {
                    return nil
                }

                let score = Self.pieVisibilityScore(for: rawImage, templateHeightRatio: templateHeightRatio)
                return DetectionFrame(
                    frame: CaptureFrame(rawImage: rawImage, correctedImage: correctedImage),
                    visibilityScore: score
                )
            }.value

            await MainActor.run {
                guard let self else { return }
                self.finishFrame(detection, generation: generation)
            }
        }
    }

    private func finishFrame(_ detection: DetectionFrame?, generation: Int) {
        defer {
            if generation == captureGeneration {
                isProcessingFrame = false
            }
        }

        guard isLive, generation == captureGeneration else {
            return
        }

        guard let detection else {
            statusText = "Live capture failed. Check Screen Recording permission."
            rawPreview = nil
            correctedPreview = nil
            projectorModel.correctedImage = nil
            projector.setVisible(isProjectorVisible)
            return
        }

        rawPreview = detection.frame.rawImage
        correctedPreview = detection.frame.correctedImage
        projectorModel.correctedImage = detection.frame.correctedImage

        projector.setVisible(isProjectorVisible)
        statusText = detection.visibilityScore >= 0.58
            ? "Piechart detected."
            : "Projector running. Adjust the selected pie area if the circle looks wrong."
    }

    private func refreshFromCurrentPreview() {
        guard let rawPreview,
              let corrected = Self.correctedPieImage(
                from: rawPreview,
                templateHeightRatio: templateHeightRatio,
                stretchMultiplier: stretchMultiplier
              ) else {
            return
        }

        correctedPreview = corrected
        projectorModel.correctedImage = corrected
        statusText = "Updated the circle fit."
    }

    private func loadPersistedSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) else {
            return
        }

        projectorAlwaysOnTop = settings.projectorAlwaysOnTop
        projectorShowTitlebar = settings.projectorShowTitlebar
        projectorTriggerMode = .autoPiechartDetection
        projectorFrame = settings.projectorFrame?.cgRect
        if let pieRegion = settings.pieRegion {
            self.pieRegion = ScreenRegion(rect: pieRegion.cgRect)
        }
        templateHeightRatio = settings.templateHeightRatio
        cropSize = settings.cropSize
        stretchMultiplier = settings.stretchMultiplier
        projectorToggleKeyCode = settings.projectorToggleKeyCode
        keybindLabel = "Not set"
        keybindProjectorEnabled = true
    }

    private func persistSettings() {
        let settings = PersistedSettings(
            projectorAlwaysOnTop: projectorAlwaysOnTop,
            projectorShowTitlebar: projectorShowTitlebar,
            projectorTriggerMode: ProjectorTriggerMode.autoPiechartDetection.rawValue,
            projectorFrame: projector.frame.map { PersistedRect($0) } ?? projectorFrame.map { PersistedRect($0) },
            pieRegion: pieRegion.map { PersistedRect($0.rect) },
            templateHeightRatio: templateHeightRatio,
            cropSize: cropSize,
            stretchMultiplier: stretchMultiplier,
            projectorToggleKeyCode: projectorToggleKeyCode,
            keybindLabel: "Not set"
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.settingsKey)
        defaults.synchronize()
    }

    private static func desktopBounds() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }
    }

    nonisolated private static func captureScreenImage(
        region: CGRect,
        cropSize: Double,
        templateHeightRatio: Double,
        stretchMultiplier: Double,
        projectorFrame: CGRect?,
        desktopBounds: CGRect
    ) -> CGImage? {
        let effectiveRegion = expandedCaptureRect(
            in: region,
            cropSize: cropSize,
            templateHeightRatio: templateHeightRatio,
            stretchMultiplier: stretchMultiplier,
            desktopBounds: desktopBounds
        )
        let imageRect = quartzRect(fromAppKitRect: effectiveRegion, desktopBounds: desktopBounds)
        guard let cgImage = CGWindowListCreateImage(
            imageRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        guard let projectorFrame else {
            return cgImage
        }

        let quartzProjectorFrame = quartzRect(fromAppKitRect: projectorFrame, desktopBounds: desktopBounds)
        let quartzRegion = quartzRect(fromAppKitRect: effectiveRegion, desktopBounds: desktopBounds)
        let overlap = quartzRegion.intersection(quartzProjectorFrame)
        guard !overlap.isNull, !overlap.isEmpty else {
            return cgImage
        }

        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(
            CGRect(
                x: overlap.minX - quartzRegion.minX,
                y: overlap.minY - quartzRegion.minY,
                width: overlap.width,
                height: overlap.height
            )
        )
        return context.makeImage() ?? cgImage
    }

    nonisolated private static func expandedCaptureRect(
        in rect: CGRect,
        cropSize: Double,
        templateHeightRatio: Double,
        stretchMultiplier: Double,
        desktopBounds: CGRect
    ) -> CGRect {
        let croppedRect = centeredCropRect(in: rect, cropSize: cropSize)
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

    nonisolated private static func centeredCropRect(in rect: CGRect, cropSize: Double) -> CGRect {
        let clampedCrop = min(max(cropSize, 0.35), 1.0)
        let width = rect.width * clampedCrop
        let height = rect.height * clampedCrop
        return CGRect(
            x: rect.midX - (width * 0.5),
            y: rect.midY - (height * 0.5),
            width: width,
            height: height
        )
    }

    nonisolated private static func correctedPieImage(
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

    nonisolated private static func pieVisibilityScore(for image: CGImage, templateHeightRatio: Double) -> Double {
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
                        let hue = Self.hue(red: red, green: green, blue: blue)
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
                    let offset = sampleY * bytesPerRow + sampleX * 4
                    let blue = Double(bytes[offset]) / 255.0
                    let green = Double(bytes[offset + 1]) / 255.0
                    let red = Double(bytes[offset + 2]) / 255.0
                    let brightness = max(red, green, blue)
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

            let innerBrightness = Self.pixelBrightness(bytes: bytes, bytesPerRow: bytesPerRow, x: innerX, y: innerY)
            let outerBrightness = Self.pixelBrightness(bytes: bytes, bytesPerRow: bytesPerRow, x: outerX, y: outerY)
            borderContrast += abs(innerBrightness - outerBrightness)
            borderCount += 1
        }

        let normalizedBorderContrast = borderCount > 0 ? borderContrast / borderCount : 0
        return (fillCoverage * 0.45) + (midlineCoverage * 0.35) + (normalizedBorderContrast * 1.25)
    }

    nonisolated private static func pixelBrightness(bytes: UnsafePointer<UInt8>, bytesPerRow: Int, x: Int, y: Int) -> Double {
        let offset = y * bytesPerRow + x * 4
        let blue = Double(bytes[offset]) / 255.0
        let green = Double(bytes[offset + 1]) / 255.0
        let red = Double(bytes[offset + 2]) / 255.0
        return max(red, green, blue)
    }

    nonisolated private static func hue(red: Double, green: Double, blue: Double) -> Double {
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

    nonisolated private static func quartzRect(fromAppKitRect rect: CGRect, desktopBounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: desktopBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

struct BetterPiechartToolView: View {
    @ObservedObject var state: PiechartState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(title: "Better Piechart", subtitle: ToolSection.piechart.description)

            Button(action: state.toggleProjector) {
                Label(state.primaryToggleTitle, systemImage: state.isLive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryMonoButtonStyle(active: state.isLive))

            ToolKeybindSection(section: .piechart)

            SectionBox(title: "Projector") {
                Toggle("Better Piechart Projector Always On Top", isOn: Binding(
                    get: { state.projectorAlwaysOnTop },
                    set: { state.setProjectorAlwaysOnTop($0) }
                ))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show Titlebar", isOn: Binding(
                        get: { state.projectorShowTitlebar },
                        set: { state.setProjectorShowTitlebar($0) }
                    ))

                    Text("Turn this on to move and position the projector.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SectionBox(title: "Pie Area") {
                HStack {
                    Text(state.pieRegion?.label ?? "No pie area selected yet.")
                        .font(.system(.body, design: state.pieRegion == nil ? .default : .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select Pie") {
                        state.selectPieRegion()
                    }
                    Button("Clear") {
                        state.clearRegion()
                    }
                    .disabled(state.pieRegion == nil)
                }
                .buttonStyle(.bordered)
            }

            SectionBox(title: "Projector Fit") {
                HStack {
                    Text("Template Height")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2f", state.templateHeightRatio))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { state.templateHeightRatio },
                        set: { state.updateTemplateHeightRatio($0) }
                    ),
                    in: 0.08...0.90,
                    step: 0.01
                )

                Text("This is the ellipse guide height relative to its width. Match it to the flattened in-game pie first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Crop Size")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2fx", state.cropSize))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { state.cropSize },
                        set: { state.updateCropSize($0) }
                    ),
                    in: 0.45...1.00,
                    step: 0.01
                )

                Text("Smaller values crop tighter around the center of the selected pie area, then scale the result back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Circle Fit")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2fx", state.stretchMultiplier))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { state.stretchMultiplier },
                        set: { state.updateStretchMultiplier($0) }
                    ),
                    in: 0.80...1.35,
                    step: 0.01
                )

                Text("The app auto-unsquashes using the selected box shape, then applies this multiplier for the final circle fit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SectionBox(title: "Previews") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Raw Capture")
                        .font(.headline)
                    CapturePreviewCard(image: state.rawPreview, templateHeightRatio: state.templateHeightRatio)
                        .frame(height: 160)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Corrected Pie")
                        .font(.headline)
                    CorrectedPiePreviewCard(image: state.correctedPreview)
                        .frame(height: 180)
                }
            }

            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapturePreviewCard: View {
    var image: CGImage?
    var templateHeightRatio: Double

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

                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: drawSize.width, height: drawSize.height)

                    Ellipse()
                        .stroke(Color.yellow.opacity(0.95), lineWidth: 2)
                        .frame(width: drawSize.width * 0.96, height: drawSize.width * templateHeightRatio)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "scope")
                            .font(.system(size: 28))
                        Text("Select a pie area to start previewing.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CorrectedPiePreviewCard: View {
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
                    .clipShape(Circle())
                    .padding(18)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 2)
                    .padding(18)
            }
        }
    }
}

struct ProjectedPieView: View {
    var image: CGImage?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.84

            ZStack {
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: side, height: side)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.72), lineWidth: 2)
                        .frame(width: side, height: side)
                }
            }
        }
    }
}

struct ProjectorHostView: View {
    @ObservedObject var model: ProjectorModel

    var body: some View {
        ProjectedPieView(image: model.correctedImage)
            .background(Color.clear)
            .ignoresSafeArea()
    }
}

final class ProjectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ProjectorWindowController: NSObject, NSWindowDelegate {
    private var window: ProjectorPanel?
    private weak var model: ProjectorModel?
    private var alwaysOnTop = true
    private var showTitlebar = false
    var onFrameChange: ((CGRect) -> Void)?

    var frame: CGRect? { window?.frame }

    func show(model: ProjectorModel, alwaysOnTop: Bool, showTitlebar: Bool, initialFrame: CGRect? = nil) {
        self.model = model
        self.alwaysOnTop = alwaysOnTop
        self.showTitlebar = showTitlebar

        rebuildWindowIfNeeded(initialFrame: initialFrame)

        applyWindowLevel()

        if window?.isVisible != true && initialFrame == nil {
            window?.center()
        }
        window?.orderFrontRegardless()
        if let frame = window?.frame {
            onFrameChange?(frame)
        }
    }

    func setAlwaysOnTop(_ value: Bool) {
        alwaysOnTop = value
        applyWindowLevel()
    }

    func setShowTitlebar(_ value: Bool) {
        guard showTitlebar != value else { return }
        showTitlebar = value
        rebuildWindowIfNeeded()
    }

    func setVisible(_ isVisible: Bool) {
        guard let window else { return }
        if isVisible {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    func windowDidMove(_ notification: Notification) {
        if let frame = window?.frame {
            onFrameChange?(frame)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let frame = window?.frame {
            onFrameChange?(frame)
        }
    }

    private func applyWindowLevel() {
        guard let window else { return }
        window.level = alwaysOnTop ? .statusBar : .normal
    }

    private func rebuildWindowIfNeeded(initialFrame: CGRect? = nil) {
        guard let model else { return }
        let preserveFrame = window?.frame
        let wasVisible = window?.isVisible ?? false

        window?.delegate = nil
        window?.orderOut(nil)

        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let defaultFrame = preserveFrame ?? initialFrame ?? CGRect(
            x: screenFrame.midX - 190,
            y: screenFrame.midY - 170,
            width: 380,
            height: 340
        )

        let styleMask: NSWindow.StyleMask = showTitlebar
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.borderless]

        let window = ProjectorPanel(
            contentRect: defaultFrame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProjectorHostView(model: model))

        if showTitlebar {
            window.title = "Better Piechart Projector"
            window.hasShadow = true
            window.ignoresMouseEvents = false
            window.isMovableByWindowBackground = false
            window.titleVisibility = .visible
        } else {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isMovableByWindowBackground = false
        }

        self.window = window
        applyWindowLevel()

        if wasVisible {
            window.orderFrontRegardless()
        }
    }
}

@MainActor
final class PieAlignmentWindowController: NSWindowController, NSWindowDelegate {
    var onContentFrameChange: ((CGRect) -> Void)?
    var currentContentFrame: CGRect? {
        guard let window else { return nil }
        return window.contentRect(forFrameRect: window.frame)
    }

    private var templateHeightRatio = 0.56

    func show(templateHeightRatio: Double, initialContentFrame: CGRect?) {
        self.templateHeightRatio = templateHeightRatio

        if window == nil {
            let baseContentRect = initialContentFrame ?? CGRect(x: 240, y: 240, width: 420, height: 240)
            let panel = NSPanel(
                contentRect: baseContentRect,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.delegate = self
            panel.title = "Pie Alignment"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.titlebarAppearsTransparent = true
            panel.contentView = NSHostingView(rootView: PieAlignmentGuideView(templateHeightRatio: templateHeightRatio))
            self.window = panel
        }

        if let window {
            if let hostingView = window.contentView as? NSHostingView<PieAlignmentGuideView> {
                hostingView.rootView = PieAlignmentGuideView(templateHeightRatio: templateHeightRatio)
            }

            if let initialContentFrame {
                let frameRect = window.frameRect(forContentRect: initialContentFrame)
                window.setFrame(frameRect, display: true)
            }

            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            publishFrame()
        }
    }

    func updateTemplateHeightRatio(_ value: Double) {
        templateHeightRatio = value
        if let window, let hostingView = window.contentView as? NSHostingView<PieAlignmentGuideView> {
            hostingView.rootView = PieAlignmentGuideView(templateHeightRatio: value)
            window.display()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        publishFrame()
    }

    func windowDidResize(_ notification: Notification) {
        publishFrame()
    }

    func windowWillClose(_ notification: Notification) {
        publishFrame()
    }

    private func publishFrame() {
        guard let rect = currentContentFrame else { return }
        onContentFrameChange?(rect)
    }
}

struct PieAlignmentGuideView: View {
    var templateHeightRatio: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.06)

                Rectangle()
                    .stroke(Color.yellow.opacity(0.95), lineWidth: 2)

                Ellipse()
                    .stroke(Color.yellow.opacity(0.95), lineWidth: 3)
                    .frame(
                        width: max(1, proxy.size.width - 10),
                        height: max(1, (proxy.size.width - 10) * templateHeightRatio)
                    )
            }
        }
    }
}
