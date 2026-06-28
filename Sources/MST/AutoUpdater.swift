import AppKit
import Foundation
import SwiftUI

let githubOwner = "ducky8x"
let githubRepo = "Mac-Speedrunning-Tools"

// MARK: - Progress window

private struct UpdateProgressView: View {
    let fromVersion: String
    let toVersion: String
    @ObservedObject var updater: AutoUpdater

    var statusText: String {
        switch updater.updateState {
        case .downloading: return "Downloading…"
        case .installing:  return "Installing…"
        default:           return ""
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Updating MST")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                Text("v\(fromVersion)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("v\(toVersion)")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 220)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 32)
        .frame(width: 300)
        .background(Color.black)
    }
}

@MainActor
private final class UpdateProgressWindowController {
    private var window: NSPanel?

    func open(from fromVersion: String, to toVersion: String, updater: AutoUpdater) {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Updating MST"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.styleMask.remove(.resizable)

        let view = UpdateProgressView(fromVersion: fromVersion, toVersion: toVersion, updater: updater)
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - AutoUpdater

@MainActor
final class AutoUpdater: ObservableObject {
    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, asset: URL)
        case downloading(progress: Double?)
        case installing
        case failed(String)

        var isActionable: Bool {
            switch self {
            case .available, .downloading, .installing, .failed: true
            default: false
            }
        }
    }

    @Published var updateState: UpdateState = .idle

    private let session: URLSession
    let currentVersion: String
    private let progressWindow = UpdateProgressWindowController()

    init(session: URLSession = .shared, currentVersion: String? = nil) {
        self.session = session
        self.currentVersion = currentVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"
    }

    func checkOnLaunch() {
        Task { await check() }
    }

    func startUpdate() {
        guard case .available(let version, let url) = updateState else { return }
        Task { await downloadAndInstall(from: url, newVersion: version) }
    }

    func retry() {
        checkOnLaunch()
    }

    // MARK: - Check

    func check() async {
        updateState = .checking

        let apiURL = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
        var req = URLRequest(url: apiURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.timeoutInterval = 10

        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else {
            updateState = .idle
            return
        }

        // Extract X.Y.Z from tags like "MST-v2.0.0", "v2.0.0", "2.0.0"
        let remote: String
        if let range = tag.range(of: #"\d+\.\d+(?:\.\d+)*"#, options: .regularExpression) {
            remote = String(tag[range])
        } else {
            updateState = .idle
            return
        }

        guard isNewer(remote, than: currentVersion) else {
            updateState = .upToDate
            return
        }

        let asset = assets.first { a in
            guard let name = a["name"] as? String else { return false }
            let lower = name.lowercased()
            guard !lower.contains(".dmg") else { return false }
            return lower.hasSuffix(".zip") && (lower.contains("macos") || lower == "mst.zip")
        }

        guard let asset,
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString)
        else {
            updateState = .idle
            return
        }

        updateState = .available(version: remote, asset: downloadURL)
    }

    // MARK: - Download & Install

    private func downloadAndInstall(from url: URL, newVersion: String) async {
        updateState = .downloading(progress: nil)
        progressWindow.open(from: currentVersion, to: newVersion, updater: self)

        guard let (tmpFile, _) = try? await session.download(from: url) else {
            progressWindow.close()
            updateState = .failed("Download failed. Check your internet connection.")
            return
        }

        updateState = .installing

        do {
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MSTExtract-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let exitCode = try await runProcess(
                URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-q", tmpFile.path, "-d", extractDir.path]
            )
            guard exitCode == 0 else {
                throw NSError(domain: "AutoUpdater", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to unzip the downloaded update."])
            }

            let newApp = try findApp(in: extractDir)
            let currentApp = Bundle.main.bundleURL

            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("MST_staged_\(UUID().uuidString).app")
            try FileManager.default.copyItem(at: newApp, to: staged)

            let scriptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mst_swap_\(UUID().uuidString).sh")
            try swapScript(staged: staged.path, target: currentApp.path)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let bash = Process()
            bash.executableURL = URL(fileURLWithPath: "/bin/bash")
            bash.arguments = [scriptURL.path]
            try bash.run()

            NSApp.terminate(nil)
        } catch {
            progressWindow.close()
            updateState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    func findApp(in dir: URL) throws -> URL {
        func search(in url: URL, depth: Int) -> URL? {
            guard depth >= 0,
                  let items = try? FileManager.default.contentsOfDirectory(
                      at: url,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: .skipsHiddenFiles
                  )
            else { return nil }
            for item in items {
                if item.pathExtension == "app" { return item }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir, let found = search(in: item, depth: depth - 1) { return found }
            }
            return nil
        }
        guard let app = search(in: dir, depth: 3) else {
            throw NSError(
                domain: "AutoUpdater", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "MST.app not found inside the downloaded zip."]
            )
        }
        return app
    }

    private func swapScript(staged: String, target: String) -> String {
        // If target is an .app bundle, open it directly.
        // If not (e.g. swift run binary), open the staged app from its temp location as a fallback.
        let launchTarget = target.hasSuffix(".app") ? target : staged
        return """
        #!/bin/bash
        set -e
        while pgrep -xq "MST" 2>/dev/null; do sleep 0.2; done
        sleep 0.3
        rm -rf '\(target)'
        cp -R '\(staged)' '\(target)'
        xattr -cr '\(target)' 2>/dev/null || true
        open '\(launchTarget)'
        rm -rf '\(staged)'
        rm -- "$0"
        """
    }

    func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        let n = max(r.count, c.count)
        for i in 0..<n {
            let ri = i < r.count ? r[i] : 0
            let ci = i < c.count ? c[i] : 0
            if ri > ci { return true }
            if ri < ci { return false }
        }
        return false
    }
}

// Runs a process off the main thread and returns its exit code.
private func runProcess(_ url: URL, arguments: [String]) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = url
            proc.arguments = arguments
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                continuation.resume(returning: proc.terminationStatus)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
