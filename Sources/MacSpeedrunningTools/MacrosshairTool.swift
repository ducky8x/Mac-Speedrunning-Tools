import AppKit
import SwiftUI

@MainActor
final class CrosshairSettings: ObservableObject {
    @Published var color: NSColor = .white { didSet { save(); view?.needsDisplay = true } }
    @Published var lineLength: CGFloat = 12 { didSet { save(); view?.needsDisplay = true } }
    @Published var lineThickness: CGFloat = 2 { didSet { save(); view?.needsDisplay = true } }
    @Published var showDot = true { didSet { save(); view?.needsDisplay = true } }
    @Published var dotSize: CGFloat = 4 { didSet { save(); view?.needsDisplay = true } }
    @Published var opacity: CGFloat = 0.85 { didSet { save(); view?.needsDisplay = true } }
    @Published var offsetX: CGFloat = 0 { didSet { save(); view?.needsDisplay = true } }
    @Published var offsetY: CGFloat = 0 { didSet { save(); view?.needsDisplay = true } }

    weak var view: CrosshairView?
    private var isLoading = false

    init() {
        load()
    }

    private enum Key {
        static let color = "macrosshair.color"
        static let lineLength = "macrosshair.lineLength"
        static let lineThickness = "macrosshair.lineThickness"
        static let showDot = "macrosshair.showDot"
        static let dotSize = "macrosshair.dotSize"
        static let opacity = "macrosshair.opacity"
        static let offsetX = "macrosshair.offsetX"
        static let offsetY = "macrosshair.offsetY"
    }

    private func save() {
        guard !isLoading else { return }
        let defaults = UserDefaults.standard
        defaults.set(color.hexString, forKey: Key.color)
        defaults.set(Double(lineLength), forKey: Key.lineLength)
        defaults.set(Double(lineThickness), forKey: Key.lineThickness)
        defaults.set(showDot, forKey: Key.showDot)
        defaults.set(Double(dotSize), forKey: Key.dotSize)
        defaults.set(Double(opacity), forKey: Key.opacity)
        defaults.set(Double(offsetX), forKey: Key.offsetX)
        defaults.set(Double(offsetY), forKey: Key.offsetY)
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let defaults = UserDefaults.standard
        if let hex = defaults.string(forKey: Key.color), let savedColor = NSColor.fromHex(hex) { color = savedColor }
        if defaults.object(forKey: Key.lineLength) != nil { lineLength = CGFloat(defaults.double(forKey: Key.lineLength)) }
        if defaults.object(forKey: Key.lineThickness) != nil { lineThickness = CGFloat(defaults.double(forKey: Key.lineThickness)) }
        if defaults.object(forKey: Key.showDot) != nil { showDot = defaults.bool(forKey: Key.showDot) }
        if defaults.object(forKey: Key.dotSize) != nil { dotSize = CGFloat(defaults.double(forKey: Key.dotSize)) }
        if defaults.object(forKey: Key.opacity) != nil { opacity = CGFloat(defaults.double(forKey: Key.opacity)) }
        if defaults.object(forKey: Key.offsetX) != nil { offsetX = CGFloat(defaults.double(forKey: Key.offsetX)) }
        if defaults.object(forKey: Key.offsetY) != nil { offsetY = CGFloat(defaults.double(forKey: Key.offsetY)) }
    }
}

extension NSColor {
    var hexString: String {
        let srgb = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255))
        )
    }

    static func fromHex(_ string: String) -> NSColor? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

final class CrosshairView: NSView {
    var settings: CrosshairSettings

    init(frame: NSRect, settings: CrosshairSettings) {
        self.settings = settings
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: NSRect) {
        let centerX = bounds.midX + settings.offsetX
        let centerY = bounds.midY + settings.offsetY
        let length = settings.lineLength
        let thickness = settings.lineThickness
        settings.color.withAlphaComponent(settings.opacity).setFill()
        NSRect(x: centerX - thickness / 2, y: centerY - length, width: thickness, height: length * 2).fill()
        NSRect(x: centerX - length, y: centerY - thickness / 2, width: length * 2, height: thickness).fill()
        if settings.showDot {
            let dot = settings.dotSize
            NSBezierPath(ovalIn: NSRect(x: centerX - dot / 2, y: centerY - dot / 2, width: dot, height: dot)).fill()
        }
    }
}

@MainActor
final class MacrosshairController: ObservableObject {
    @Published var isVisible = false
    let settings = CrosshairSettings()

    private var overlayWindow: NSWindow?
    private var crosshairView: CrosshairView?

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    func toggle() {
        setVisible(!isVisible)
    }

    private func show() {
        if overlayWindow == nil {
            let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let view = CrosshairView(frame: frame, settings: settings)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.contentView = view
            settings.view = view
            overlayWindow = window
            crosshairView = view
        }
        overlayWindow?.orderFrontRegardless()
        isVisible = true
    }

    private func hide() {
        overlayWindow?.orderOut(nil)
        isVisible = false
    }
}
