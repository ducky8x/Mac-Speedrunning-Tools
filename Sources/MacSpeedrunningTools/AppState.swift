import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowBackdropState: ObservableObject {
    @Published var windows: [TrackedWindow] = []
    @Published var activeWindow: TrackedWindow?
    @Published var backgroundColor = Color(red: 0.08, green: 0.11, blue: 0.13)
    @Published var emptyZoneColor = Color.black
    @Published var imageURL: URL?
    @Published var imageFitMode = ImageFitMode.keepAspectRatio
    @Published var opacity = 1.0
    @Published var blurRadius = 0.0
    @Published var coverMenuBar = false
    @Published var status = "Press Start, then click any window. The rest of that display becomes the backdrop."
    @Published var isBackdropEnabled = false {
        didSet { isBackdropEnabled ? startBackdrop() : stopBackdrop() }
    }

    private let tracker = WindowTracker()
    private let backdropController = BackdropWindowController()
    private var cancellables: Set<AnyCancellable> = []
    private var syncTimer: Timer?

    init() {
        tracker.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                guard let self else { return }
                self.windows = windows
            }
            .store(in: &cancellables)

        tracker.start()
    }

    func refreshWindows() {
        tracker.refresh()
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            imageURL = panel.url
        }
    }

    func clearImage() {
        imageURL = nil
    }

    func startOrStopBackdrop() {
        isBackdropEnabled.toggle()
    }

    private func startBackdrop() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncToFrontmostWindow()
            }
        }

        syncToFrontmostWindow()
        status = activeWindow == nil
            ? "Backdrop started. Click a normal app window to attach it."
            : "Backdrop following \(activeWindow?.displayName ?? "frontmost window")."
    }

    private func stopBackdrop() {
        syncTimer?.invalidate()
        syncTimer = nil
        backdropController.close()
        status = "Backdrop stopped."
    }

    private func syncToFrontmostWindow() {
        guard let window = tracker.frontmostWindow() else {
            status = activeWindow == nil
                ? "No target window found. Click a normal app window."
                : "Waiting for the active Space to settle..."
            return
        }

        let previousWindowID = activeWindow?.id
        activeWindow = window
        syncBackdrop(to: window)

        if previousWindowID != window.id {
            status = "Backdrop following \(window.displayName)."
        }
    }

    private func syncBackdrop(to window: TrackedWindow) {
        let configuration = BackdropConfiguration(
            color: NSColor(backgroundColor),
            emptyZoneColor: NSColor(emptyZoneColor),
            imageURL: imageURL,
            imageFitMode: imageFitMode,
            opacity: opacity,
            blurRadius: blurRadius,
            coverMenuBar: coverMenuBar
        )
        backdropController.show(behind: window, configuration: configuration)
    }
}
