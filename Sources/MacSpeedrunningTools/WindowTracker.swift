import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WindowTracker: ObservableObject {
    @Published private(set) var windows: [TrackedWindow] = []

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            windows = []
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let nextWindows = rawWindows.compactMap { info -> TrackedWindow? in
            guard
                let number = info[kCGWindowNumber as String] as? UInt32,
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID != ownPID,
                let ownerName = info[kCGWindowOwnerName as String] as? String,
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return nil
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let memoryUsage = info[kCGWindowMemoryUsage as String] as? Int ?? 0
            let title = info[kCGWindowName as String] as? String ?? ""

            guard
                layer == 0,
                alpha > 0,
                frame.width >= 80,
                frame.height >= 80,
                !ownerName.isEmpty,
                !Self.isFinderDesktop(ownerName: ownerName, title: title, frame: frame)
            else {
                return nil
            }

            let id = CGWindowID(number)
            return TrackedWindow(
                id: id,
                ownerName: ownerName,
                ownerPID: ownerPID,
                title: title,
                frame: frame,
                layer: layer,
                alpha: alpha,
                memoryUsage: memoryUsage
            )
        }

        windows = nextWindows
    }

    func frontmostWindow() -> TrackedWindow? {
        refresh()

        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let appWindow = windows.first(where: { $0.ownerPID == frontmostPID }) {
            return appWindow
        }

        return windows.first
    }

    private static func isFinderDesktop(ownerName: String, title: String, frame: CGRect) -> Bool {
        guard ownerName == "Finder", title.isEmpty else { return false }

        return NSScreen.screens.contains { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }

            let displayBounds = CGDisplayBounds(displayID)
            return frame.width >= displayBounds.width * 0.95
                && frame.height >= displayBounds.height * 0.95
        }
    }
}
