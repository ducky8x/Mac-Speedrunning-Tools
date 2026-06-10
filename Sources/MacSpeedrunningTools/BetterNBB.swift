import AppKit
import Foundation

// MARK: - NBB Data Model

struct NBBState {
    struct Prediction {
        let chunkX, chunkZ: Int
        let certainty: Double       // 0.0 – 1.0
        let overworldDist: Double
        let angle: Double?
        let angleOffset: Double?

        var location : String { "(\(chunkX * 16 + 4), \(chunkZ * 16 + 4))" }
        var certPct  : String { String(format: "%.1f%%", certainty * 100) }
        var dist     : String { String(format: "%.0f", overworldDist) }
        var netherDist: String { String(format: "%.0f", overworldDist / 8.0) }
        var nether   : String { "(\(chunkX * 2), \(chunkZ * 2))" }
        var angleStr : String {
            guard let angle else { return "--" }
            guard let angleOffset else { return String(format: "%.2f", angle) }
            return String(format: "%.2f ← %.1f", angle, angleOffset)
        }
    }

    struct EyeThrow {
        let x, z, angle, error: Double
        let correctionIncrements: Int?
        let marker: Marker
        var xStr    : String { String(format: "%.2f", x) }
        var zStr    : String { String(format: "%.2f", z) }
        var angleStr: String { String(format: "%.2f", angle) }
        var errorStr: String { String(format: "%.4f", error) }
        var correctionStr: String {
            guard let correctionIncrements else { return "--" }
            return "\(correctionIncrements)"
        }

        enum Marker {
            case none
            case grayBoat
            case blueBoat
            case redBoat
            case greenBoat
            case alternate

            var dot: String {
                switch self {
                case .none: return ""
                case .grayBoat, .blueBoat, .redBoat, .greenBoat, .alternate: return "●"
                }
            }

            var color: NSColor {
                switch self {
                case .none: return NSColor(white: 0.3, alpha: 1)
                case .grayBoat: return .systemGray
                case .blueBoat: return .systemBlue
                case .redBoat: return .systemRed
                case .greenBoat: return .systemGreen
                case .alternate: return .systemCyan
                }
            }
        }
    }

    struct InformationMessage {
        let message: String
        let level: String

        var displayText: String {
            message.replacingOccurrences(of: "<[^>]+>",
                                         with: "",
                                         options: .regularExpression)
        }

        var isWarning: Bool {
            level.uppercased().contains("WARN") || level.uppercased().contains("ERROR")
        }
    }

    struct PlayerPosition {
        let x, z, horizontalAngle: Double
        let isInOverworld, isInNether: Bool
    }

    var predictions: [Prediction] = []
    var eyeThrows  : [EyeThrow]   = []
    var resultType : String        = "NONE"
    var messages   : [InformationMessage] = []
    var playerPosition: PlayerPosition?
}

// MARK: - Config  (single source of truth, fully Codable)

struct OverlayConfig: Codable {
    // Overlay placement
    var overlayX      : Double = 0
    var overlayY      : Double = 0
    var overlayWidth  : Double = 520
    var overlayHeight : Double = 200
    var overlaySet    : Bool   = false

    // Row visibility
    var maxPredRows: Int = 5   // 1-5
    var maxEyeRows : Int = 2   // 1-2

    // Prediction columns
    var showLoc    : Bool = true
    var showPct    : Bool = true
    var showDist   : Bool = true
    var showNether : Bool = true
    var showNetherDist: Bool = true
    var showAngle  : Bool = true

    // Eye throw columns
    var showEyeX    : Bool = true
    var showEyeZ    : Bool = true
    var showEyeAngle: Bool = true
    var showEyeOffset: Bool = true
    var showEyeError: Bool = true
    var showEyeMarker: Bool = true

    // Options
    var hideZeroPct: Bool = true
    var showInfoMessages: Bool = true
    var showMoveHint: Bool = true

    // Window appearance
    var windowBgRed: Double = 0.06
    var windowBgGreen: Double = 0.07
    var windowBgBlue: Double = 0.10
    var windowBgOpacity: Double = 0.72
    var windowBorderRed: Double = 0.36
    var windowBorderGreen: Double = 0.42
    var windowBorderBlue: Double = 0.58
    var windowShowBorder: Bool = true
    var windowBorderOpacity: Double = 0.55
    var windowBorderWidth: Double = 1.2
    var windowCornerRadius: Double = 10
    var windowShadowStrength: Double = 0.45

    // Computed
    var overlayRect: CGRect {
        CGRect(x: overlayX, y: overlayY, width: overlayWidth, height: overlayHeight)
    }

    var windowBackgroundColor: NSColor {
        NSColor(calibratedRed: windowBgRed, green: windowBgGreen, blue: windowBgBlue, alpha: windowBgOpacity)
    }

    var windowBorderColor: NSColor {
        NSColor(calibratedRed: windowBorderRed, green: windowBorderGreen, blue: windowBorderBlue, alpha: windowBorderOpacity)
    }

    // Persistence
    static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterNBB")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> OverlayConfig {
        guard let data = try? Data(contentsOf: saveURL),
              let cfg  = try? JSONDecoder().decode(OverlayConfig.self, from: data)
        else { return OverlayConfig() }
        return cfg
    }

    func save() { try? JSONEncoder().encode(self).write(to: OverlayConfig.saveURL) }
}

private func boolValue(_ value: Any?) -> Bool {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    if let s = value as? String {
        return ["true", "yes", "1", "boat", "green"].contains(s.lowercased())
    }
    return false
}

private func intValue(_ value: Any?) -> Int? {
    (value as? Int) ?? (value as? NSNumber)?.intValue
}

private func doubleValue(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

private func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
    keys.compactMap { doubleValue(dict[$0]) }.first
}

private func eyeMarker(from dict: [String: Any]) -> NBBState.EyeThrow.Marker {
    let markerKeys = ["marker", "type", "measurementType", "throwType", "stdType",
                      "standardDeviationType", "boatColor", "boatColour", "boatState",
                      "boatStatus", "boatMode", "defaultBoatMode",
                      "colorOfBoat", "colourOfBoat"]
    let markerText = markerKeys
        .compactMap { dict[$0] as? String }
        .joined(separator: " ")
        .lowercased()
    let combinedText = markerText + " " + dict.values
        .compactMap { $0 as? String }
        .joined(separator: " ")
        .lowercased()

    if combinedText.contains("gray boat") || combinedText.contains("grey boat") { return .grayBoat }
    if combinedText.contains("blue boat") { return .blueBoat }
    if combinedText.contains("green boat") { return .greenBoat }
    if combinedText.contains("boat angle of 0") { return .greenBoat }

    if markerText.contains("gray") || markerText.contains("grey") { return .grayBoat }
    if markerText.contains("blue") { return .blueBoat }
    if markerText.contains("red") { return .redBoat }
    if markerText.contains("green") { return .greenBoat }

    let zeroAngleKeys = ["boatAngle", "boat_angle", "angle", "eyeAngle", "measurementAngle"]
    if let angle = firstDouble(dict, keys: zeroAngleKeys), abs(angle) < 0.0001 {
        return .greenBoat
    }

    if boolValue(dict["boat"]) ||
        boolValue(dict["isBoat"]) ||
        boolValue(dict["boatEye"]) ||
        boolValue(dict["isBoatEye"]) ||
        boolValue(dict["isBoatThrow"]) ||
        boolValue(dict["isBoatMeasurement"]) ||
        boolValue(dict["boatThrow"]) ||
        boolValue(dict["boatMeasurement"]) ||
        boolValue(dict["usesBoat"]) ||
        markerText.contains("boat") {
        return .greenBoat
    }

    if boolValue(dict["alternate"]) ||
        boolValue(dict["isAlternate"]) ||
        boolValue(dict["altStd"]) ||
        boolValue(dict["usesAltStd"]) ||
        markerText.contains("alternate") ||
        markerText.contains("alt") {
        return .alternate
    }

    return .none
}

private func parseInformationMessages(from root: Any) -> [NBBState.InformationMessage] {
    let arrays = ["informationMessages", "infoMessages", "messages", "warnings", "errors", "information"]
    let singles = ["informationMessage", "infoMessage", "message", "warning", "error", "errorMessage", "warningMessage", "information"]

    if let text = root as? String, !text.isEmpty {
        return [NBBState.InformationMessage(message: text, level: levelForKey(text))]
    }

    if let arr = root as? [[String: Any]] {
        return arr.compactMap(messageFromDictionary)
    }

    if let arr = root as? [String] {
        return arr.map { NBBState.InformationMessage(message: $0, level: "INFO") }
    }

    if let arr = root as? [Any] {
        return arr.flatMap(parseInformationMessages)
    }

    guard let dict = root as? [String: Any] else { return [] }

    var result: [NBBState.InformationMessage] = []
    for key in arrays {
        if let arr = dict[key] as? [[String: Any]] {
            result += arr.compactMap(messageFromDictionary)
        } else if let arr = dict[key] as? [String] {
            result += arr.map { NBBState.InformationMessage(message: $0, level: levelForKey(key)) }
        }
    }

    for key in singles {
        if let text = dict[key] as? String, !text.isEmpty {
            result.append(NBBState.InformationMessage(message: text, level: levelForKey(key)))
        } else if let nested = dict[key] as? [String: Any],
                  let msg = messageFromDictionary(nested) {
            result.append(msg)
        }
    }

    if result.isEmpty, let msg = messageFromDictionary(dict) {
        result.append(msg)
    }

    var seen = Set<String>()
    return result.filter { msg in
        let key = "\(msg.level)|\(msg.message)"
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}

private func messageFromDictionary(_ dict: [String: Any]) -> NBBState.InformationMessage? {
    let textKeys = ["message", "text", "content", "contents", "description", "title", "html", "formattedMessage", "value"]
    let text = textKeys.compactMap { dict[$0] as? String }.first { !$0.isEmpty }
    let fallback = dict
        .filter { key, value in
            value is String &&
            ["message", "text", "warning", "error", "description"].contains { key.lowercased().contains($0) }
        }
        .compactMap { $0.value as? String }
        .first { !$0.isEmpty }

    guard let message = text ?? fallback else { return nil }
    let level = (dict["level"] ?? dict["type"] ?? dict["severity"] ?? dict["kind"]) as? String
        ?? levelForKey(message)
    return NBBState.InformationMessage(message: message, level: level)
}

private func levelForKey(_ key: String) -> String {
    let lower = key.lowercased()
    if lower.contains("error") { return "ERROR" }
    if lower.contains("warn") { return "WARNING" }
    return "INFO"
}

// MARK: - SSE Client

protocol SSEClientDelegate: AnyObject {
    func sseClient(_ client: SSEClient, didReceive state: NBBState)
    func sseClientConnectionChanged(_ client: SSEClient, connected: Bool)
}

final class SSEClient: NSObject, URLSessionDataDelegate {
    weak var delegate: SSEClientDelegate?
    private var task  : URLSessionDataTask?
    private var buffer: String = ""
    private lazy var session = URLSession(configuration: .ephemeral,
                                          delegate: self,
                                          delegateQueue: nil)
    private let snapshotSession = URLSession(configuration: .ephemeral)
    private var reconnectTimer: Timer?
    private var shouldReconnect = false
    private(set) var isConnected = false

    func connect() {
        disconnect()
        shouldReconnect = true
        guard let url = URL(string: "http://localhost:52533/api/v1/stronghold/events") else { return }
        var req = URLRequest(url: url, timeoutInterval: Double.infinity)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: req)
        task?.resume()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTimer?.invalidate()
        task?.cancel(); task = nil
        isConnected = false
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        markConnected()
        if let chunk = String(data: data, encoding: .utf8) {
            buffer += chunk
            flush()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        DispatchQueue.main.async {
            self.isConnected = false
            self.delegate?.sseClientConnectionChanged(self, connected: false)
            if self.shouldReconnect {
                self.scheduleReconnect()
            }
        }
    }

    private func markConnected() {
        DispatchQueue.main.async {
            guard !self.isConnected else { return }
            self.isConnected = true
            self.delegate?.sseClientConnectionChanged(self, connected: true)
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.async {
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                self?.connect()
            }
        }
    }

    private func flush() {
        // SSE format: lines of "data: <json>", events separated by blank lines
        var lines = buffer.components(separatedBy: "\n")
        // Keep the last incomplete line in the buffer
        if !buffer.hasSuffix("\n") {
            buffer = lines.removeLast()
        } else {
            buffer = ""
        }
        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let state = parseState(json) {
                DispatchQueue.main.async { self.delegate?.sseClient(self, didReceive: state) }
            }
        }
    }

    private func parseState(_ json: String) -> NBBState? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var state = NBBState()
        state.resultType = root["resultType"] as? String ?? "NONE"
        state.messages = parseInformationMessages(from: root)

        if let player = root["playerPosition"] as? [String: Any],
           let x = doubleValue(player["xInOverworld"]),
           let z = doubleValue(player["zInOverworld"]),
           let angle = doubleValue(player["horizontalAngle"]) {
            state.playerPosition = NBBState.PlayerPosition(
                x: x,
                z: z,
                horizontalAngle: angle,
                isInOverworld: boolValue(player["isInOverworld"]),
                isInNether: boolValue(player["isInNether"])
            )
        }

        if let preds = root["predictions"] as? [[String: Any]] {
            state.predictions = preds.compactMap { p -> NBBState.Prediction? in
                guard let cx  = p["chunkX"]            as? Int,
                      let cz  = p["chunkZ"]            as? Int,
                      let cer = p["certainty"]         as? Double,
                      let od  = p["overworldDistance"] as? Double
                else { return nil }
                let angle = firstDouble(p, keys: [
                    "angle", "eyeAngle", "strongholdAngle", "angleToStronghold",
                    "direction", "directionToStronghold", "overworldAngle",
                    "angleInOverworld", "angleInOverworldToStronghold",
                    "travelAngle", "recommendedAngle", "recommendedTravelAngle"
                ])
                let angleOffset = firstDouble(p, keys: [
                    "angleOffset", "angleCorrection", "directionOffset",
                    "angleDifference", "turnAngle", "angleChange",
                    "angleAdjustment", "recommendedAngleOffset",
                    "recommendedAngleCorrection"
                ])
                return NBBState.Prediction(chunkX: cx, chunkZ: cz,
                                           certainty: cer, overworldDist: od,
                                           angle: angle, angleOffset: angleOffset)
            }
        }
        if let throws_ = root["eyeThrows"] as? [[String: Any]] {
            state.eyeThrows = throws_.compactMap { t -> NBBState.EyeThrow? in
                guard let x = t["xInOverworld"] as? Double,
                      let z = t["zInOverworld"] as? Double,
                      let a = t["angle"]        as? Double,
                      let e = t["error"]        as? Double
                else { return nil }
                let corr = intValue(t["correctionIncrements"] ?? t["angleCorrectionIncrements"] ?? t["correction"])
                return NBBState.EyeThrow(x: x, z: z, angle: a, error: e,
                                         correctionIncrements: corr,
                                         marker: eyeMarker(from: t))
            }
        }
        return state
    }

    func fetchSnapshot() {
        guard let url = URL(string: "http://localhost:52533/api/v1/stronghold") else { return }
        let req = URLRequest(url: url, timeoutInterval: 0.5)
        snapshotSession.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = String(data: data, encoding: .utf8),
                  let state = self.parseState(json)
            else { return }
            DispatchQueue.main.async {
                self.delegate?.sseClient(self, didReceive: state)
            }
        }.resume()
    }
}

protocol InformationMessageClientDelegate: AnyObject {
    func informationMessageClient(_ client: InformationMessageClient,
                                  didReceive messages: [NBBState.InformationMessage])
}

final class InformationMessageClient: NSObject, URLSessionDataDelegate {
    weak var delegate: InformationMessageClientDelegate?
    private var task: URLSessionDataTask?
    private var buffer: String = ""
    private lazy var session = URLSession(configuration: .ephemeral,
                                          delegate: self,
                                          delegateQueue: nil)
    private var reconnectTimer: Timer?
    private var shouldReconnect = false

    func connect() {
        disconnect()
        shouldReconnect = true
        guard let url = URL(string: "http://localhost:52533/api/v1/information-messages/events") else { return }
        var req = URLRequest(url: url, timeoutInterval: Double.infinity)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: req)
        task?.resume()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTimer?.invalidate()
        task?.cancel(); task = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        if let chunk = String(data: data, encoding: .utf8) {
            buffer += chunk
            flush()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        DispatchQueue.main.async {
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                self?.connect()
            }
        }
    }

    private func flush() {
        var lines = buffer.components(separatedBy: "\n")
        if !buffer.hasSuffix("\n") {
            buffer = lines.removeLast()
        } else {
            buffer = ""
        }
        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let messages = parseMessages(json) {
                DispatchQueue.main.async {
                    self.delegate?.informationMessageClient(self, didReceive: messages)
                }
            }
        }
    }

    private func parseMessages(_ json: String) -> [NBBState.InformationMessage]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        return parseInformationMessages(from: root)
    }
}

// MARK: - Drag Picker

protocol DragPickerDelegate: AnyObject {
    func dragPickerDidSelect(_ rect: CGRect)
}

struct OverlayPreviewState {
    var predRows: Int
    var eyeRows: Int
    var showMessages: Bool
    var showMoveHint: Bool

    static func fromConfig(_ cfg: OverlayConfig) -> OverlayPreviewState {
        OverlayPreviewState(
            predRows: max(1, cfg.maxPredRows),
            eyeRows: max(1, cfg.maxEyeRows),
            showMessages: cfg.showInfoMessages,
            showMoveHint: cfg.showMoveHint
        )
    }
}

final class DragPicker: NSWindowController {
    weak var delegate: DragPickerDelegate?
    private var start = NSPoint.zero
    private var box: NSView?

    init(instruction: String) {
        let screen = NSScreen.main?.frame ?? .zero
        let win = NSWindow(contentRect: screen, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        win.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        win.isOpaque = false
        super.init(window: win)

        let lbl = NSTextField(labelWithString: "\(instruction)   •   ESC to cancel")
        lbl.font = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = .white; lbl.backgroundColor = .clear; lbl.sizeToFit()
        lbl.setFrameOrigin(NSPoint(x: (screen.width - lbl.frame.width) / 2, y: screen.height - 60))
        win.contentView?.addSubview(lbl)
        win.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent) {
        start = e.locationInWindow
        let v = NSView(frame: NSRect(origin: start, size: .zero))
        v.wantsLayer = true
        v.layer?.borderColor     = NSColor.systemBlue.cgColor
        v.layer?.borderWidth     = 2
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        window?.contentView?.addSubview(v); box = v
    }

    override func mouseDragged(with e: NSEvent) {
        let c = e.locationInWindow
        box?.frame = NSRect(x: min(start.x, c.x), y: min(start.y, c.y),
                            width: abs(c.x - start.x), height: abs(c.y - start.y))
    }

    override func mouseUp(with e: NSEvent) {
        guard let box, let screen = NSScreen.main else { close(); return }
        let r = CGRect(x: box.frame.minX,
                       y: screen.frame.height - box.frame.maxY,
                       width: box.frame.width, height: box.frame.height)
        NSCursor.arrow.set(); close()
        if r.width > 10 && r.height > 10 { delegate?.dragPickerDidSelect(r) }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { NSCursor.arrow.set(); close() }
    }
}

final class TemplatePlacementWindow: NSWindowController, NSWindowDelegate {
    weak var delegate: DragPickerDelegate?
    var onClose: (() -> Void)?
    private let minSize = NSSize(width: 320, height: 180)
    private var previewImage: NSImage?
    private var didNotifyClose = false
    private var shouldApplyOnClose = true
    private let imageView = NSImageView()

    init(initialFrame: NSRect, previewImage: NSImage?) {
        self.previewImage = previewImage
        let win = NSWindow(contentRect: initialFrame,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered,
                           defer: false)
        win.title = "Overlay Placement"
        win.minSize = minSize
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            win.maxSize = NSSize(width: max(minSize.width, vf.width * 0.98),
                                 height: max(minSize.height, vf.height * 0.90))
        }
        if let previewImage, previewImage.size.width > 0, previewImage.size.height > 0 {
            win.contentAspectRatio = previewImage.size
        }
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = NSColor(white: 0.08, alpha: 1)
        win.titlebarAppearsTransparent = false
        win.isMovableByWindowBackground = false
        super.init(window: win)
        win.delegate = self
        buildTemplate(in: win.contentView!)
        win.makeKeyAndOrderFront(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildTemplate(in root: NSView) {
        root.subviews.forEach { $0.removeFromSuperview() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = previewImage
        // Keep normal proportional scaling (no stretch distortion).
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        root.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: root.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func currentOverlayRect() -> CGRect? {
        guard let win = window, let screen = NSScreen.main else { return nil }
        let local = win.contentView?.bounds ?? imageView.frame
        let screenRect = win.convertToScreen(local)
        return CGRect(x: screenRect.minX,
                      y: screen.frame.height - screenRect.maxY,
                      width: screenRect.width,
                      height: screenRect.height)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        if shouldApplyOnClose, let rect = currentOverlayRect() {
            delegate?.dragPickerDidSelect(rect)
        }
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            shouldApplyOnClose = false
            close()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Overlay Window

final class OverlayWindow: NSWindowController {
    private let minOverlayWidth: CGFloat = 220
    private let minOverlayHeight: CGFloat = 120
    private let edgeHitInset: CGFloat = 18
    private let cornerHitInset: CGFloat = 28
    private var cfg   : OverlayConfig
    private var labels: [String: NSTextField] = [:]
    private var lastState = NBBState()
    private var lastMessages: [NBBState.InformationMessage] = []
    private var layout = LayoutState()
    private var placementMode = false
    private var dragStartScreen = NSPoint.zero
    private var dragStartFrame = NSRect.zero
    private var activeDrag: DragMode = .none
    var onPlacementRectChanged: ((CGRect) -> Void)?

    private enum DragMode {
        case none, move
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private final class OverlayNSWindow: NSWindow {
        weak var owner: OverlayWindow?
        override func mouseDown(with event: NSEvent) { owner?.handleMouseDown(event) }
        override func mouseDragged(with event: NSEvent) { owner?.handleMouseDragged(event) }
        override func mouseUp(with event: NSEvent) { owner?.handleMouseUp(event) }
        override func mouseMoved(with event: NSEvent) { owner?.handleMouseMoved(event) }
    }

    struct Col {
        let header: String
        let key: String
        let weight: CGFloat
    }

    private struct LayoutState: Equatable {
        var predRows = 0
        var eyeRows = 0
        var showMessages = false
        var showMoveHint = false

        var isEmpty: Bool {
            predRows == 0 && eyeRows == 0 && !showMessages && !showMoveHint
        }
    }

    init(cfg: OverlayConfig) {
        self.cfg = cfg
        let win = OverlayNSWindow(contentRect: .zero, styleMask: .borderless,
                                  backing: .buffered, defer: false)
        win.level              = .floating
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.hasShadow          = false
        win.acceptsMouseMovedEvents = true
        super.init(window: win)
        win.owner = self
    }

    required init?(coder: NSCoder) { fatalError() }

    // Call whenever config changes
    func reconfigure(_ newCfg: OverlayConfig) {
        cfg = newCfg
        rebuildLayout()
        render(lastState)
    }

    func apply(_ state: NBBState) {
        lastState = state
        if !state.messages.isEmpty {
            lastMessages = state.messages
        }
        render(state)
    }

    func applyMessages(_ messages: [NBBState.InformationMessage]) {
        lastMessages = messages
        render(lastState)
    }

    func show() {
        guard placementMode || !layout.isEmpty else { return }
        window?.makeKeyAndOrderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
    func setPlacementMode(_ enabled: Bool) {
        placementMode = enabled
        window?.ignoresMouseEvents = !enabled
        if enabled {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSCursor.arrow.set()
            persistCurrentRect(commit: true, notify: true)
        }
    }
    func currentDisplayedOverlayRect() -> CGRect? {
        guard let win = window, let screen = NSScreen.main else { return nil }
        let f = win.frame
        return CGRect(x: f.minX,
                      y: screen.frame.height - f.maxY,
                      width: f.width,
                      height: f.height)
    }
    func placementPreviewImage() -> NSImage? {
        guard let view = window?.contentView, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) ?? NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap = rep else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
    func placementPreviewState() -> OverlayPreviewState {
        let preds = filteredPredictions(from: lastState)
        let current = desiredLayout(preds: preds, state: lastState)
        return OverlayPreviewState(
            predRows: max(1, current.predRows),
            eyeRows: max(1, current.eyeRows),
            showMessages: current.showMessages,
            showMoveHint: current.showMoveHint
        )
    }

    // MARK: Layout rebuild

    func rebuildLayout() {
        guard let screen = NSScreen.main, let win = window else { return }
        win.contentView?.subviews.forEach { $0.removeFromSuperview() }
        labels.removeAll()

        let r = cfg.overlayRect
        let safeWidth = max(minOverlayWidth, CGFloat(r.width))
        let safeFullHeight = max(minOverlayHeight, CGFloat(r.height))
        let currentPreds = filteredPredictions(from: lastState)
        layout = desiredLayout(preds: currentPreds, state: lastState)
        if layout.isEmpty && !placementMode {
            win.orderOut(nil)
            return
        }

        let safeLayoutHeight = layoutHeight(for: layout, fullHeight: safeFullHeight)
        let winFrame = NSRect(x: r.minX,
                              y: screen.frame.height - r.minY - safeLayoutHeight,
                              width: safeWidth,
                              height: safeLayoutHeight)
        win.setFrame(winFrame, display: false)

        let insetLeftRight: CGFloat = 10
        let insetBottom: CGFloat = 8
        let insetTop: CGFloat = 24
        let xOff = insetLeftRight
        let yOff = insetBottom
        let W  = max(1, winFrame.width - insetLeftRight * 2)
        let fullH = max(1, safeFullHeight - insetTop - insetBottom)
        let cv = win.contentView!

        let panel = NSView(frame: NSRect(x: 0, y: 0, width: W, height: winFrame.height))
        panel.wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        if let layer = panel.layer {
            layer.backgroundColor = cfg.windowBackgroundColor.cgColor
            layer.cornerRadius = CGFloat(cfg.windowCornerRadius)
            if cfg.windowShowBorder {
                layer.borderColor = cfg.windowBorderColor.cgColor
                layer.borderWidth = CGFloat(cfg.windowBorderWidth)
            } else {
                layer.borderColor = NSColor.clear.cgColor
                layer.borderWidth = 0
            }
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Float(min(1, max(0, cfg.windowShadowStrength)))
            layer.shadowRadius = CGFloat(2 + cfg.windowShadowStrength * 18)
            layer.shadowOffset = .zero
            layer.masksToBounds = false
        }
        panel.frame = NSRect(x: 0, y: 0, width: winFrame.width, height: winFrame.height)
        cv.addSubview(panel)

        if placementMode {
            let hint = NSTextField(labelWithString: "Overlay will show here")
            hint.font = NSFont.systemFont(ofSize: max(13, min(winFrame.height * 0.085, 26)), weight: .semibold)
            hint.textColor = NSColor(white: 0.82, alpha: 0.95)
            hint.alignment = .center
            hint.frame = NSRect(x: 0, y: (winFrame.height - 34) * 0.5, width: winFrame.width, height: 34)
            hint.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            cv.addSubview(hint)
            return
        }

        let pCols = predCols(); let eCols = eyeCols()
        let pRows = layout.predRows; let eRows = layout.eyeRows

        let fullMsgH  : CGFloat = min(max(fullH * 0.20, 34), 58)
        let fullMoveH : CGFloat = min(max(fullH * 0.10, 18), 30)
        let fullTableH: CGFloat = max(0, fullH - (cfg.showInfoMessages ? fullMsgH : 0) - (cfg.showMoveHint ? fullMoveH : 0))

        // Vertical split: predictions above eye throws, with optional messages at bottom.
        let fullPredH: CGFloat = fullTableH * 0.59
        let fullEyeH : CGFloat = fullTableH * 0.34
        let fullGap  : CGFloat = max(0, fullTableH - fullPredH - fullEyeH)

        let pHdrH  : CGFloat = max(0, fullPredH * 0.17)
        let pRowH  : CGFloat = max(0, (fullPredH - pHdrH) / CGFloat(max(1, cfg.maxPredRows)))
        let eHdrH  : CGFloat = max(0, fullEyeH * 0.27)
        let eRowH  : CGFloat = max(0, (fullEyeH - eHdrH) / CGFloat(max(1, cfg.maxEyeRows)))
        let predH  : CGFloat = pRows > 0 && !pCols.isEmpty ? pHdrH + CGFloat(pRows) * pRowH : 0
        let eyeH   : CGFloat = eRows > 0 && !eCols.isEmpty ? eHdrH + CGFloat(eRows) * eRowH : 0
        let gap    : CGFloat = predH > 0 && eyeH > 0 ? max(4, fullGap) : 0
        let msgH   : CGFloat = layout.showMessages ? fullMsgH : 0
        let moveH  : CGFloat = layout.showMoveHint ? fullMoveH : 0

        let pWidths = colWidths(pCols, totalWidth: W)
        let eWidths = colWidths(eCols, totalWidth: W)

        let fs     : CGFloat = max(9, min(pRowH * 0.54, 20))
        let hdrFS  : CGFloat = max(7, fs * 0.68)

        let msgBaseY  : CGFloat = 0
        let moveBaseY : CGFloat = msgH
        let eyeBaseY  : CGFloat = msgH + moveH
        let predY     : CGFloat = eyeBaseY + eyeH + gap

        // ── Prediction table ──
        var x: CGFloat = 0
        if pRows > 0 {
            for (ci, col) in pCols.enumerated() {
                let w = pWidths[ci]
                put(col.header, NSRect(x: xOff + x,
                                       y: yOff + predY + CGFloat(pRows)*pRowH,
                                       width: w, height: pHdrH),
                    size: hdrFS, weight: .semibold, color: NSColor(white: 0.65, alpha: 1), in: cv)
                x += w
            }
            for ri in 0..<pRows {
                let y = predY + CGFloat(pRows - 1 - ri) * pRowH
                x = 0
                for (ci, col) in pCols.enumerated() {
                    let w = pWidths[ci]
                    let key = "p_\(ri)_\(col.key)"
                    labels[key] = put("", NSRect(x: xOff + x, y: yOff + y,
                                                 width: w, height: pRowH),
                                      size: fs, weight: .regular, color: .white, in: cv)
                    x += w
                }
            }

            if cfg.showEyeMarker,
               let angleIndex = pCols.firstIndex(where: { $0.key == "angle" }) {
                let angleX = pWidths.prefix(angleIndex).reduce(CGFloat(0), +)
                let angleW = pWidths[angleIndex]
                let markerW = max(10, min(16, pHdrH * 0.72))
                let markerX = angleX + angleW - markerW - 2
                let headerY = predY + CGFloat(pRows) * pRowH
                labels["boatTop"] = put("",
                                        NSRect(x: xOff + markerX, y: yOff + headerY,
                                               width: markerW, height: pHdrH),
                                        size: hdrFS,
                                        weight: .regular,
                                        color: NSColor(white: 0.3, alpha: 1),
                                        in: cv)
            }
        }

        // ── Divider ──
        if predH > 0 && eyeH > 0 {
            let div = NSBox(); div.boxType = .separator
            div.frame = NSRect(x: xOff, y: yOff + eyeBaseY + eyeH + gap*0.5 - 0.5, width: W, height: 1)
            cv.addSubview(div)
        }

        // ── Eye throw table ──
        x = 0
        if eRows > 0 {
            for (ci, col) in eCols.enumerated() {
                let w = eWidths[ci]
                put(col.header, NSRect(x: xOff + x,
                                       y: yOff + eyeBaseY + CGFloat(eRows)*eRowH,
                                       width: w, height: eHdrH),
                    size: hdrFS, weight: .semibold, color: NSColor(white: 0.65, alpha: 1), in: cv)
                x += w
            }
            for ri in 0..<eRows {
                let y = eyeBaseY + CGFloat(eRows - 1 - ri) * eRowH
                x = 0
                for (ci, col) in eCols.enumerated() {
                    let w = eWidths[ci]
                    let key = "e_\(ri)_\(col.key)"
                    labels[key] = put("", NSRect(x: xOff + x, y: yOff + y,
                                                 width: w, height: eRowH),
                                      size: fs*0.92, weight: .regular, color: .white, in: cv)
                    x += w
                }

            }
        }

        if layout.showMoveHint {
            let hint = put("", NSRect(x: xOff + 12, y: yOff + moveBaseY, width: W - 24, height: moveH),
                           size: max(8, min(moveH * 0.48, 13)),
                           weight: .medium,
                           color: NSColor(white: 0.75, alpha: 1),
                           in: cv)
            hint.alignment = .center
            hint.lineBreakMode = .byTruncatingTail
            labels["moveHint"] = hint
        }

        if layout.showMessages {
            let msg = put("", NSRect(x: xOff + 12, y: yOff + msgBaseY + 2, width: W - 24, height: msgH - 4),
                          size: max(8, min(msgH * 0.25, 12)),
                          weight: .medium,
                          color: NSColor(white: 0.7, alpha: 1),
                          in: cv)
            msg.alignment = .left
            msg.lineBreakMode = .byWordWrapping
            msg.usesSingleLineMode = false
            msg.maximumNumberOfLines = 3
            labels["message"] = msg
        }

        win.makeKeyAndOrderFront(nil)
    }

    private func handleMouseDown(_ e: NSEvent) {
        guard placementMode, let win = window else { return }
        dragStartScreen = NSEvent.mouseLocation
        dragStartFrame = win.frame
        activeDrag = dragMode(at: e.locationInWindow, in: win)
        if activeDrag == .none { activeDrag = .move }
    }

    private func handleMouseDragged(_ e: NSEvent) {
        guard placementMode, let win = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartScreen.x
        let dy = current.y - dragStartScreen.y
        var f = dragStartFrame

        switch activeDrag {
        case .move:
            f.origin.x = dragStartFrame.origin.x + dx
            f.origin.y = dragStartFrame.origin.y + dy
        case .left, .topLeft, .bottomLeft:
            f.origin.x = dragStartFrame.origin.x + dx
            f.size.width = dragStartFrame.width - dx
        default: break
        }
        switch activeDrag {
        case .right, .topRight, .bottomRight:
            f.size.width = dragStartFrame.width + dx
        default: break
        }
        switch activeDrag {
        case .bottom, .bottomLeft, .bottomRight:
            f.origin.y = dragStartFrame.origin.y + dy
            f.size.height = dragStartFrame.height - dy
        default: break
        }
        switch activeDrag {
        case .top, .topLeft, .topRight:
            f.size.height = dragStartFrame.height + dy
        default: break
        }

        if f.size.width < minOverlayWidth {
            if activeDrag == .left || activeDrag == .topLeft || activeDrag == .bottomLeft {
                f.origin.x -= (minOverlayWidth - f.size.width)
            }
            f.size.width = minOverlayWidth
        }
        if f.size.height < minOverlayHeight {
            if activeDrag == .bottom || activeDrag == .bottomLeft || activeDrag == .bottomRight {
                f.origin.y -= (minOverlayHeight - f.size.height)
            }
            f.size.height = minOverlayHeight
        }

        win.setFrame(f, display: true)
        persistCurrentRect(commit: false, notify: false)
    }

    private func handleMouseUp(_ e: NSEvent) {
        guard placementMode else { return }
        activeDrag = .none
        persistCurrentRect(commit: true, notify: true)
    }

    private func handleMouseMoved(_ e: NSEvent) {
        guard placementMode, let win = window else { return }
        let mode = dragMode(at: e.locationInWindow, in: win)
        switch mode {
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight: NSCursor.closedHand.set()
        case .topRight, .bottomLeft: NSCursor.closedHand.set()
        case .move: NSCursor.openHand.set()
        case .none: NSCursor.arrow.set()
        }
    }

    private func dragMode(at point: NSPoint, in win: NSWindow) -> DragMode {
        let w = win.frame.width
        let h = win.frame.height
        let left = point.x <= edgeHitInset
        let right = point.x >= w - edgeHitInset
        let bottom = point.y <= edgeHitInset
        let top = point.y >= h - edgeHitInset
        let cornerLeft = point.x <= cornerHitInset
        let cornerRight = point.x >= w - cornerHitInset
        let cornerBottom = point.y <= cornerHitInset
        let cornerTop = point.y >= h - cornerHitInset
        if cornerLeft && cornerTop { return .topLeft }
        if cornerRight && cornerTop { return .topRight }
        if cornerLeft && cornerBottom { return .bottomLeft }
        if cornerRight && cornerBottom { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return .move
    }

    private func persistCurrentRect(commit: Bool, notify: Bool) {
        guard let rect = currentDisplayedOverlayRect() else { return }
        cfg.overlayX = rect.minX
        cfg.overlayY = rect.minY
        cfg.overlayWidth = rect.width
        cfg.overlayHeight = fullHeight(forDisplayedHeight: rect.height, layout: layout)
        cfg.overlaySet = true
        if commit { cfg.save() }
        if notify {
            let savedRect = CGRect(x: cfg.overlayX, y: cfg.overlayY,
                                   width: cfg.overlayWidth, height: cfg.overlayHeight)
            onPlacementRectChanged?(savedRect)
        }
    }

    private func fullHeight(forDisplayedHeight targetHeight: CGFloat, layout: LayoutState) -> CGFloat {
        let minH = minOverlayHeight
        let maxH = max(minOverlayHeight, 3000)
        if layoutHeight(for: layout, fullHeight: minH) >= targetHeight { return minH }

        var low = minH
        var high = maxH
        for _ in 0..<22 {
            let mid = (low + high) * 0.5
            let shown = layoutHeight(for: layout, fullHeight: mid)
            if shown < targetHeight {
                low = mid
            } else {
                high = mid
            }
        }
        return max(minH, high)
    }

    @discardableResult
    private func put(_ text: String, _ frame: NSRect, size: CGFloat,
                     weight: NSFont.Weight, color: NSColor, in view: NSView) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        l.textColor = color; l.alignment = .center
        l.drawsBackground = false; l.isBezeled = false; l.frame = frame
        view.addSubview(l); return l
    }

    private func colWidths(_ cols: [Col], totalWidth: CGFloat) -> [CGFloat] {
        let totalWeight = max(0.1, cols.reduce(CGFloat(0)) { $0 + $1.weight })
        return cols.map { totalWidth * ($0.weight / totalWeight) }
    }

    private func filteredPredictions(from state: NBBState) -> [NBBState.Prediction] {
        if cfg.hideZeroPct {
            return state.predictions.filter { $0.certainty > 0.0005 }
        }
        return state.predictions
    }

    private func desiredLayout(preds: [NBBState.Prediction], state: NBBState) -> LayoutState {
        let hasPredCols = !predCols().isEmpty
        let hasEyeCols = !eyeCols().isEmpty
        return LayoutState(
            predRows: hasPredCols ? min(cfg.maxPredRows, preds.count) : 0,
            eyeRows: hasEyeCols ? min(cfg.maxEyeRows, state.eyeThrows.count) : 0,
            showMessages: cfg.showInfoMessages && lastMessages.contains { !$0.displayText.isEmpty },
            showMoveHint: cfg.showMoveHint && !preds.isEmpty && state.playerPosition != nil
        )
    }

    private func rebuildLayoutIfNeeded(preds: [NBBState.Prediction], state: NBBState) {
        let next = desiredLayout(preds: preds, state: state)
        guard next != layout else { return }
        rebuildLayout()
    }

    private func layoutHeight(for layout: LayoutState, fullHeight: CGFloat) -> CGFloat {
        let safeFullHeight = max(minOverlayHeight, fullHeight)
        let msgH: CGFloat = cfg.showInfoMessages ? min(max(safeFullHeight * 0.20, 34), 58) : 0
        let moveH: CGFloat = cfg.showMoveHint ? min(max(safeFullHeight * 0.10, 18), 30) : 0
        let tableH: CGFloat = max(0, safeFullHeight - msgH - moveH)
        let predH: CGFloat = tableH * 0.59
        let eyeH: CGFloat = tableH * 0.34
        let gap: CGFloat = max(0, tableH - predH - eyeH)
        let predHdrH: CGFloat = max(0, predH * 0.17)
        let predRowH: CGFloat = max(0, (predH - predHdrH) / CGFloat(max(1, cfg.maxPredRows)))
        let eyeHdrH: CGFloat = max(0, eyeH * 0.27)
        let eyeRowH: CGFloat = max(0, (eyeH - eyeHdrH) / CGFloat(max(1, cfg.maxEyeRows)))

        var height: CGFloat = 0
        if layout.showMessages { height += msgH }
        if layout.showMoveHint { height += moveH }
        if layout.eyeRows > 0 { height += eyeHdrH + CGFloat(layout.eyeRows) * eyeRowH }
        if layout.predRows > 0 && layout.eyeRows > 0 { height += max(4, gap) }
        if layout.predRows > 0 { height += predHdrH + CGFloat(layout.predRows) * predRowH }
        return max(1, min(safeFullHeight, height))
    }

    // MARK: Render

    private func render(_ state: NBBState) {
        DispatchQueue.main.async { self._render(state) }
    }

    private func _render(_ state: NBBState) {
        let pCols = predCols(); let eCols = eyeCols()

        // Filter & pad predictions
        let preds = filteredPredictions(from: state)
        rebuildLayoutIfNeeded(preds: preds, state: state)
        applyBestBodyFont(preds: preds, pCols: pCols, eCols: eCols)

        for ri in 0..<layout.predRows {
            let p = preds[ri]
            for col in pCols {
                guard let lbl = labels["p_\(ri)_\(col.key)"] else { continue }
                switch col.key {
                case "loc":
                    lbl.stringValue = p.location; lbl.textColor = .white
                case "pct":
                    lbl.stringValue = p.certPct
                    let v = p.certainty * 100
                    lbl.textColor = v > 50 ? .systemGreen : v > 10 ? .systemOrange : .systemRed
                case "dist":
                    lbl.stringValue = p.dist; lbl.textColor = .white
                case "netherDist":
                    lbl.stringValue = p.netherDist; lbl.textColor = .white
                case "nether":
                    lbl.stringValue = p.nether; lbl.textColor = .white
                case "angle":
                    setPredictionAngle(p, state: state, label: lbl)
                default: break
                }
            }
        }

        for ri in 0..<layout.eyeRows {
            let e = state.eyeThrows[ri]
            for col in eCols {
                guard let lbl = labels["e_\(ri)_\(col.key)"] else { continue }
                switch col.key {
                case "x":     lbl.stringValue = e.xStr
                case "z":     lbl.stringValue = e.zStr
                case "angle": lbl.stringValue = e.angleStr
                case "offset": lbl.stringValue = e.correctionStr
                case "error": lbl.stringValue = e.errorStr
                default: break
                }
                lbl.textColor = col.key == "offset" && e.correctionIncrements != nil ? .systemRed : .white
            }
        }
        if let marker = labels["boatTop"] {
            if let latest = state.eyeThrows.first {
                marker.stringValue = latest.marker.dot
                marker.textColor = latest.marker.color
            } else {
                marker.stringValue = ""
                marker.textColor = NSColor(white: 0.3, alpha: 1)
            }
        }

        renderMoveHint(preds)
        renderMessage()
    }

    private func setPredictionAngle(_ pred: NBBState.Prediction, state: NBBState, label: NSTextField) {
        let angle = pred.angle ?? computedPredictionAngle(pred, state: state)
        guard let angle else {
            label.stringValue = "--"
            label.textColor = NSColor(white: 0.3, alpha: 1)
            return
        }

        let offset = pred.angleOffset ?? computedAngleOffset(targetAngle: angle, state: state)
        guard let offset else {
            label.stringValue = String(format: "%.2f", angle)
            label.textColor = .white
            return
        }

        let arrow = offset < 0 ? "<-" : "->"
        let diff = String(format: "%@ %.1f", arrow, abs(offset))
        let full = String(format: "%.2f (%@)", angle, diff)
        let attr = NSMutableAttributedString(string: full, attributes: [
            .font: label.font as Any,
            .foregroundColor: NSColor.white
        ])
        if let range = full.range(of: diff) {
            attr.addAttribute(.foregroundColor,
                              value: angleDiffColor(offset),
                              range: NSRange(range, in: full))
        }
        label.attributedStringValue = attr
    }

    private func renderMessage() {
        guard let lbl = labels["message"] else { return }
        guard cfg.showInfoMessages,
              let msg = lastMessages.last(where: { !$0.displayText.isEmpty })
        else {
            lbl.stringValue = ""
            return
        }

        let bodyColor = NSColor(white: 0.72, alpha: 1)
        let text = msg.displayText
        if msg.isWarning {
            let full = "●  \(text)"
            let attr = NSMutableAttributedString(string: full, attributes: [
                .font: lbl.font as Any,
                .foregroundColor: bodyColor
            ])
            attr.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: NSRange(location: 0, length: 1))
            lbl.attributedStringValue = attr
        } else {
            lbl.stringValue = text
            lbl.textColor = bodyColor
        }
    }

    private func renderMoveHint(_ preds: [NBBState.Prediction]) {
        guard let lbl = labels["moveHint"] else { return }
        guard cfg.showMoveHint,
              let pred = preds.first,
              let player = lastState.playerPosition
        else {
            lbl.stringValue = ""
            return
        }

        let targetX = Double(pred.chunkX * 16 + 4)
        let targetZ = Double(pred.chunkZ * 16 + 4)
        let dx = targetX - player.x
        let dz = targetZ - player.z
        let theta = player.horizontalAngle * .pi / 180
        let forward = dx * -sin(theta) + dz * cos(theta)
        let left = dx * cos(theta) + dz * sin(theta)

        let forwardWord = forward >= 0 ? "Forward" : "Back"
        let sideWord = left >= 0 ? "Left" : "Right"
        let parts = [
            movementHintPart(label: forwardWord, overworldBlocks: abs(forward), player: player),
            movementHintPart(label: sideWord, overworldBlocks: abs(left), player: player)
        ].compactMap { $0 }
        lbl.stringValue = parts.isEmpty ? "At target" : parts.joined(separator: "   ")
        lbl.textColor = NSColor(white: 0.74, alpha: 1)
    }

    private func movementHintPart(label: String,
                                  overworldBlocks: Double,
                                  player: NBBState.PlayerPosition) -> String? {
        let ow = abs(overworldBlocks)
        let nether = ow / 8.0
        let primary = player.isInNether ? nether : ow
        guard primary.rounded() != 0 else { return nil }

        if player.isInNether {
            return String(format: "%@ %.0f (OW %.0f)", label, nether, ow)
        }
        return String(format: "%@ %.0f (N %.0f)", label, ow, nether)
    }

    private func applyBestBodyFont(preds: [NBBState.Prediction], pCols: [Col], eCols: [Col]) {
        var candidates: [(String, CGFloat)] = []

        for ri in 0..<layout.predRows {
            let pred = preds[ri]
            for col in pCols {
                guard let lbl = labels["p_\(ri)_\(col.key)"] else { continue }
                candidates.append((predictionText(pred, col: col, state: lastState), max(1, lbl.frame.width - 10)))
            }
        }

        for ri in 0..<layout.eyeRows {
            let eye = lastState.eyeThrows[ri]
            for col in eCols {
                guard let lbl = labels["e_\(ri)_\(col.key)"] else { continue }
                candidates.append((eyeText(eye, col: col), max(1, lbl.frame.width - 8)))
            }
        }

        let maxHeight = labels
            .filter { key, label in
                (key.hasPrefix("p_") || key.hasPrefix("e_")) && label.frame.height > 0
            }
            .map { _, label in label.frame.height * 0.72 }
            .min() ?? 18
        let maxSize = min(maxHeight, 20)
        let size = fittingBodyFontSize(candidates: candidates, maxSize: maxSize)

        for (key, lbl) in labels where key.hasPrefix("p_") || key.hasPrefix("e_") {
            let isMarker = key.hasSuffix("_marker")
            lbl.font = NSFont.monospacedDigitSystemFont(ofSize: isMarker ? size * 0.82 : size,
                                                        weight: .regular)
        }
    }

    private func fittingBodyFontSize(candidates: [(String, CGFloat)], maxSize: CGFloat) -> CGFloat {
        var low: CGFloat = 8
        var high: CGFloat = max(8, maxSize)

        for _ in 0..<12 {
            let mid = (low + high) / 2
            let font = NSFont.monospacedDigitSystemFont(ofSize: mid, weight: .regular)
            let fits = candidates.allSatisfy { text, width in
                textWidth(text, font: font) <= width
            }
            if fits {
                low = mid
            } else {
                high = mid
            }
        }

        return low
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func predictionText(_ pred: NBBState.Prediction?, col: Col, state: NBBState) -> String {
        guard let pred else { return "--" }
        switch col.key {
        case "loc": return pred.location
        case "pct": return pred.certPct
        case "dist": return pred.dist
        case "netherDist": return pred.netherDist
        case "nether": return pred.nether
        case "angle": return predictionAngleText(pred, state: state)
        default: return ""
        }
    }

    private func predictionAngleText(_ pred: NBBState.Prediction, state: NBBState) -> String {
        let angle = pred.angle ?? computedPredictionAngle(pred, state: state)
        guard let angle else { return "--" }
        let offset = pred.angleOffset ?? computedAngleOffset(targetAngle: angle, state: state)
        guard let offset else { return String(format: "%.2f", angle) }
        let arrow = offset < 0 ? "<-" : "->"
        return String(format: "%.2f (%@ %.1f)", angle, arrow, abs(offset))
    }

    private func computedPredictionAngle(_ pred: NBBState.Prediction, state: NBBState) -> Double? {
        let origin = angleOrigin(state)
        guard let origin else { return nil }
        let targetX = Double(pred.chunkX * 16 + 4)
        let targetZ = Double(pred.chunkZ * 16 + 4)
        let dx = targetX - origin.x
        let dz = targetZ - origin.z
        guard dx != 0 || dz != 0 else { return nil }
        return atan2(-dx, dz) * 180 / .pi
    }

    private func computedAngleOffset(targetAngle: Double, state: NBBState) -> Double? {
        guard let origin = angleOrigin(state) else { return nil }
        return normalizedDegrees(targetAngle - origin.angle)
    }

    private func angleDiffColor(_ offset: Double) -> NSColor {
        let t = min(1, abs(offset) / 20.0)
        let hue = CGFloat((1 - t) * 0.34)
        return NSColor(calibratedHue: hue, saturation: 0.85, brightness: 0.95, alpha: 1)
    }

    private func angleOrigin(_ state: NBBState) -> (x: Double, z: Double, angle: Double)? {
        if let player = state.playerPosition {
            return (player.x, player.z, player.horizontalAngle)
        }
        if let eye = state.eyeThrows.last {
            return (eye.x, eye.z, eye.angle)
        }
        return nil
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    private func eyeText(_ eye: NBBState.EyeThrow?, col: Col) -> String {
        guard let eye else { return "--" }
        switch col.key {
        case "marker": return eye.marker.dot
        case "x": return eye.xStr
        case "z": return eye.zStr
        case "angle": return eye.angleStr
        case "offset": return eye.correctionStr
        case "error": return eye.errorStr
        default: return ""
        }
    }

    // Column lists driven by config
    private func predCols() -> [Col] {
        var c = [Col]()
        if cfg.showDist       { c.append(Col(header: "Dist.",       key: "dist",       weight: 0.65)) }
        if cfg.showLoc        { c.append(Col(header: "Location",    key: "loc",        weight: 1.20)) }
        if cfg.showPct        { c.append(Col(header: "%",           key: "pct",        weight: 0.78)) }
        if cfg.showNether     { c.append(Col(header: "Nether",      key: "nether",     weight: 1.05)) }
        if cfg.showNetherDist { c.append(Col(header: "Nether Dist.", key: "netherDist", weight: 0.82)) }
        if cfg.showAngle      { c.append(Col(header: "Angle",       key: "angle",      weight: 1.20)) }
        return c
    }

    private func eyeCols() -> [Col] {
        var c = [Col]()
        if cfg.showEyeX      { c.append(Col(header: "x",      key: "x",      weight: 1.15)) }
        if cfg.showEyeZ      { c.append(Col(header: "z",      key: "z",      weight: 1.15)) }
        if cfg.showEyeAngle  { c.append(Col(header: "Angle",  key: "angle",  weight: 0.95)) }
        if cfg.showEyeOffset { c.append(Col(header: "Offset", key: "offset", weight: 0.70)) }
        if cfg.showEyeError  { c.append(Col(header: "Error",  key: "error",  weight: 0.95)) }
        return c
    }
}

// MARK: - Settings Window

final class WindowStyleWindow: NSWindowController {
    private var cfg: OverlayConfig
    var onChange: ((OverlayConfig) -> Void)?

    private let bgColorWell = NSColorWell()
    private let borderColorWell = NSColorWell()
    private let borderToggle = NSButton(checkboxWithTitle: "Enable border", target: nil, action: nil)
    private let bgOpacity = NSSlider(value: 0.72, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let borderOpacity = NSSlider(value: 0.55, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let borderWidth = NSSlider(value: 1.2, minValue: 0.0, maxValue: 6.0, target: nil, action: nil)
    private let cornerRadius = NSSlider(value: 10, minValue: 0.0, maxValue: 24.0, target: nil, action: nil)
    private let shadowStrength = NSSlider(value: 0.45, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)

    init(cfg: OverlayConfig) {
        self.cfg = cfg
        let win = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 360, height: 340),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered,
                           defer: false)
        win.title = "Customize Window"
        win.backgroundColor = NSColor(white: 0.12, alpha: 1)
        super.init(window: win)
        buildUI(in: win.contentView!)
        syncControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setConfig(_ cfg: OverlayConfig) {
        self.cfg = cfg
        syncControls()
    }

    private func buildUI(in root: NSView) {
        let outer = vstack(10, insets: .init(top: 16, left: 16, bottom: 16, right: 16))
        root.addSubview(outer); pin(outer, to: root)

        outer.addArrangedSubview(fieldRow("Background color", view: bgColorWell))
        outer.addArrangedSubview(fieldRow("Background opacity", view: bgOpacity))
        outer.addArrangedSubview(borderToggle)
        outer.addArrangedSubview(fieldRow("Border color", view: borderColorWell))
        outer.addArrangedSubview(fieldRow("Border opacity", view: borderOpacity))
        outer.addArrangedSubview(fieldRow("Border strength", view: borderWidth))
        outer.addArrangedSubview(fieldRow("Corner radius", view: cornerRadius))
        outer.addArrangedSubview(fieldRow("Shadow strength", view: shadowStrength))

        for slider in [bgOpacity, borderOpacity, borderWidth, cornerRadius, shadowStrength] {
            slider.target = self
            slider.action = #selector(anyChanged)
        }
        bgColorWell.target = self; bgColorWell.action = #selector(anyChanged)
        borderColorWell.target = self; borderColorWell.action = #selector(anyChanged)
        borderToggle.target = self; borderToggle.action = #selector(anyChanged)
        borderToggle.font = .systemFont(ofSize: 12, weight: .medium)
        borderToggle.contentTintColor = .white
    }

    private func fieldRow(_ title: String, view: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .white
        lbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        lbl.widthAnchor.constraint(equalToConstant: 140).isActive = true

        if let slider = view as? NSSlider {
            slider.controlSize = .small
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        } else {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 54).isActive = true
            view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        row.addArrangedSubview(lbl)
        row.addArrangedSubview(view)
        return row
    }

    private func syncControls() {
        bgColorWell.color = NSColor(calibratedRed: cfg.windowBgRed, green: cfg.windowBgGreen, blue: cfg.windowBgBlue, alpha: 1)
        borderColorWell.color = NSColor(calibratedRed: cfg.windowBorderRed, green: cfg.windowBorderGreen, blue: cfg.windowBorderBlue, alpha: 1)
        bgOpacity.doubleValue = cfg.windowBgOpacity
        borderToggle.state = cfg.windowShowBorder ? .on : .off
        borderOpacity.doubleValue = cfg.windowBorderOpacity
        borderWidth.doubleValue = cfg.windowBorderWidth
        cornerRadius.doubleValue = cfg.windowCornerRadius
        shadowStrength.doubleValue = cfg.windowShadowStrength
        let enabled = cfg.windowShowBorder
        borderColorWell.isEnabled = enabled
        borderOpacity.isEnabled = enabled
        borderWidth.isEnabled = enabled
    }

    @objc private func anyChanged() {
        let bg = bgColorWell.color.usingColorSpace(.deviceRGB) ?? bgColorWell.color
        let border = borderColorWell.color.usingColorSpace(.deviceRGB) ?? borderColorWell.color
        cfg.windowBgRed = Double(bg.redComponent)
        cfg.windowBgGreen = Double(bg.greenComponent)
        cfg.windowBgBlue = Double(bg.blueComponent)
        cfg.windowBorderRed = Double(border.redComponent)
        cfg.windowBorderGreen = Double(border.greenComponent)
        cfg.windowBorderBlue = Double(border.blueComponent)
        cfg.windowShowBorder = borderToggle.state == .on
        cfg.windowBgOpacity = bgOpacity.doubleValue
        cfg.windowBorderOpacity = borderOpacity.doubleValue
        cfg.windowBorderWidth = borderWidth.doubleValue
        cfg.windowCornerRadius = cornerRadius.doubleValue
        cfg.windowShadowStrength = shadowStrength.doubleValue
        let enabled = cfg.windowShowBorder
        borderColorWell.isEnabled = enabled
        borderOpacity.isEnabled = enabled
        borderWidth.isEnabled = enabled
        cfg.save()
        onChange?(cfg)
    }
}

final class SettingsWindow: NSWindowController, @preconcurrency DragPickerDelegate {
    private let minOverlayWidth: CGFloat = 220
    private let minOverlayHeight: CGFloat = 120
    private let maxOverlayWidth: CGFloat = 2600
    private let maxOverlayHeight: CGFloat = 1400
    private var cfg     = OverlayConfig.load()
    private var placementModeEnabled = false
    private var styleWindow: WindowStyleWindow?
    private var previewWin: NSWindow?
    var onChange: ((OverlayConfig) -> Void)?
    var onPlacementModeChanged: ((Bool) -> Void)?

    private let posBtn      = NSButton()
    private let customizeBtn = NSButton()
    private let posLbl      = NSTextField(labelWithString: "Not set (default position)")
    private let predStepper = NSStepper()
    private let predLbl     = NSTextField(labelWithString: "")
    private let eyeStepper  = NSStepper()
    private let eyeLbl      = NSTextField(labelWithString: "")
    private let chkLoc      = check("Location")
    private let chkPct      = check("%")
    private let chkDist     = check("Dist.")
    private let chkNether   = check("Nether")
    private let chkNetherDist = check("Nether Dist.")
    private let chkAngle    = check("Angle")
    private let chkEyeX     = check("x")
    private let chkEyeZ     = check("z")
    private let chkEyeAngle = check("Angle")
    private let chkEyeOffset = check("Offset")
    private let chkEyeError = check("Error")
    private let chkEyeMarker = check("Boat dot")
    private let chkHideZero = check("Hide 0% predictions")
    private let chkInfoMsgs = check("Show NBB messages")
    private let chkMoveHint = check("Show movement hint (Can invalidate RSG runs)")
    private let connLbl     = NSTextField(labelWithString: "⚠️  Not connected to NBB")

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 160, y: 160, width: 340, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "BetterNBB"
        win.backgroundColor = NSColor(white: 0.1, alpha: 1)
        super.init(window: win)
        buildUI(in: win.contentView!)
        syncControls()
        let style = WindowStyleWindow(cfg: cfg)
        style.onChange = { [weak self] updated in
            self?.cfg = updated
            self?.cfg.save()
            self?.onChange?(updated)
        }
        styleWindow = style
        win.makeKeyAndOrderFront(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setConnected(_ on: Bool) {
        DispatchQueue.main.async {
            self.connLbl.stringValue = on ? "✓  Connected to Ninjabrain Bot" : "⚠️  Not connected to NBB"
            self.connLbl.textColor   = on ? .systemGreen : .systemOrange
        }
    }

    private func buildUI(in root: NSView) {
        let outer = vstack(16, insets: .init(top: 20, left: 20, bottom: 20, right: 20))
        root.addSubview(outer); pin(outer, to: root)

        // Connection status
        connLbl.isEditable = false; connLbl.isBezeled = false; connLbl.backgroundColor = .clear
        connLbl.font = .systemFont(ofSize: 12, weight: .medium); connLbl.textColor = .systemOrange
        outer.addArrangedSubview(connLbl)

        // Overlay position
        outer.addArrangedSubview(sectionLbl("OVERLAY POSITION"))
        posBtn.title = "⊞  Place Overlay Template"
        posBtn.bezelStyle = .rounded; posBtn.target = self; posBtn.action = #selector(pickPos)
        customizeBtn.title = "Customize Window"
        customizeBtn.bezelStyle = .rounded
        customizeBtn.target = self
        customizeBtn.action = #selector(openWindowCustomizer)
        posLbl.isEditable = false; posLbl.isBezeled = false; posLbl.backgroundColor = .clear
        posLbl.textColor = NSColor(white: 0.5, alpha: 1); posLbl.font = .systemFont(ofSize: 10)
        outer.addArrangedSubview(posBtn)
        outer.addArrangedSubview(customizeBtn)
        outer.addArrangedSubview(posLbl)

        // Row counts
        outer.addArrangedSubview(sectionLbl("ROW COUNTS"))
        predStepper.minValue = 1; predStepper.maxValue = 5
        predStepper.target = self; predStepper.action = #selector(anyChanged)
        predLbl.isEditable = false; predLbl.isBezeled = false
        predLbl.backgroundColor = .clear; predLbl.textColor = .white; predLbl.font = .systemFont(ofSize: 12)
        outer.addArrangedSubview(hstack([predLbl, predStepper]))

        eyeStepper.minValue = 1; eyeStepper.maxValue = 2
        eyeStepper.target = self; eyeStepper.action = #selector(anyChanged)
        eyeLbl.isEditable = false; eyeLbl.isBezeled = false
        eyeLbl.backgroundColor = .clear; eyeLbl.textColor = .white; eyeLbl.font = .systemFont(ofSize: 12)
        outer.addArrangedSubview(hstack([eyeLbl, eyeStepper]))

        // Prediction columns
        outer.addArrangedSubview(sectionLbl("STRONGHOLD COLUMNS"))
        for b in [chkDist, chkLoc, chkPct, chkNether, chkNetherDist, chkAngle] {
            b.target = self; b.action = #selector(anyChanged); outer.addArrangedSubview(b)
        }

        // Eye columns
        outer.addArrangedSubview(sectionLbl("EYE THROW COLUMNS"))
        for b in [chkEyeX, chkEyeZ, chkEyeAngle, chkEyeOffset, chkEyeError] {
            b.target = self; b.action = #selector(anyChanged); outer.addArrangedSubview(b)
        }

        // Options
        outer.addArrangedSubview(sectionLbl("OPTIONS"))
        chkEyeMarker.target = self; chkEyeMarker.action = #selector(anyChanged)
        outer.addArrangedSubview(chkEyeMarker)
        chkHideZero.target = self; chkHideZero.action = #selector(anyChanged)
        outer.addArrangedSubview(chkHideZero)
        chkInfoMsgs.target = self; chkInfoMsgs.action = #selector(anyChanged)
        outer.addArrangedSubview(chkInfoMsgs)
        chkMoveHint.target = self; chkMoveHint.action = #selector(anyChanged)
        outer.addArrangedSubview(chkMoveHint)
    }

    private func syncControls() {
        predStepper.intValue = Int32(cfg.maxPredRows)
        eyeStepper.intValue  = Int32(cfg.maxEyeRows)
        predLbl.stringValue  = "Prediction rows: \(cfg.maxPredRows)"
        eyeLbl.stringValue   = "Eye throw rows: \(cfg.maxEyeRows)"
        chkLoc.state      = cfg.showLoc      ? .on : .off
        chkPct.state      = cfg.showPct      ? .on : .off
        chkDist.state     = cfg.showDist     ? .on : .off
        chkNether.state   = cfg.showNether   ? .on : .off
        chkNetherDist.state = cfg.showNetherDist ? .on : .off
        chkAngle.state    = cfg.showAngle    ? .on : .off
        chkEyeX.state     = cfg.showEyeX     ? .on : .off
        chkEyeZ.state     = cfg.showEyeZ     ? .on : .off
        chkEyeAngle.state = cfg.showEyeAngle ? .on : .off
        chkEyeOffset.state = cfg.showEyeOffset ? .on : .off
        chkEyeError.state = cfg.showEyeError ? .on : .off
        chkEyeMarker.state = cfg.showEyeMarker ? .on : .off
        chkHideZero.state = cfg.hideZeroPct  ? .on : .off
        chkInfoMsgs.state = cfg.showInfoMessages ? .on : .off
        chkMoveHint.state = cfg.showMoveHint ? .on : .off
        posLbl.stringValue = cfg.overlaySet
            ? String(format: "%.0f, %.0f  —  %.0f × %.0f",
                     cfg.overlayX, cfg.overlayY, cfg.overlayWidth, cfg.overlayHeight)
            : "Not set (default position)"
        if placementModeEnabled {
            posBtn.title = "Finish Overlay Placement"
        } else {
            posBtn.title = "⊞  Place Overlay Template"
        }
    }

    @objc private func anyChanged() {
        cfg.maxPredRows   = Int(predStepper.intValue)
        cfg.maxEyeRows    = Int(eyeStepper.intValue)
        predLbl.stringValue = "Prediction rows: \(cfg.maxPredRows)"
        eyeLbl.stringValue  = "Eye throw rows: \(cfg.maxEyeRows)"
        cfg.showLoc       = chkLoc.state      == .on
        cfg.showPct       = chkPct.state      == .on
        cfg.showDist      = chkDist.state     == .on
        cfg.showNether    = chkNether.state   == .on
        cfg.showNetherDist = chkNetherDist.state == .on
        cfg.showAngle     = chkAngle.state    == .on
        cfg.showEyeX      = chkEyeX.state     == .on
        cfg.showEyeZ      = chkEyeZ.state     == .on
        cfg.showEyeAngle  = chkEyeAngle.state == .on
        cfg.showEyeOffset = chkEyeOffset.state == .on
        cfg.showEyeError  = chkEyeError.state == .on
        cfg.showEyeMarker = chkEyeMarker.state == .on
        cfg.hideZeroPct   = chkHideZero.state == .on
        cfg.showInfoMessages = chkInfoMsgs.state == .on
        cfg.showMoveHint = chkMoveHint.state == .on
        styleWindow?.setConfig(cfg)
        cfg.save(); onChange?(cfg)
    }

    @objc private func pickPos() {
        placementModeEnabled.toggle()
        onPlacementModeChanged?(placementModeEnabled)
        syncControls()
    }

    @objc private func openWindowCustomizer() {
        styleWindow?.setConfig(cfg)
        styleWindow?.showWindow(nil)
        styleWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func dragPickerDidSelect(_ rect: CGRect) {
        let clamped = CGRect(x: rect.minX,
                             y: rect.minY,
                             width: min(maxOverlayWidth, max(minOverlayWidth, rect.width)),
                             height: min(maxOverlayHeight, max(minOverlayHeight, rect.height)))
        cfg.overlayX = clamped.minX; cfg.overlayY = clamped.minY
        cfg.overlayWidth = clamped.width; cfg.overlayHeight = clamped.height
        cfg.overlaySet = true; cfg.save()
        styleWindow?.setConfig(cfg)
        syncControls(); onChange?(cfg)
    }
}

// MARK: - Layout helpers

private func vstack(_ spacing: CGFloat, insets: NSEdgeInsets) -> NSStackView {
    let s = NSStackView()
    s.orientation = .vertical; s.alignment = .leading
    s.spacing = spacing; s.edgeInsets = insets
    s.translatesAutoresizingMaskIntoConstraints = false; return s
}
private func hstack(_ views: [NSView]) -> NSStackView {
    let s = NSStackView(views: views); s.spacing = 8; return s
}
private func sectionLbl(_ t: String) -> NSTextField {
    let l = NSTextField(labelWithString: t)
    l.font = .systemFont(ofSize: 10, weight: .bold)
    l.textColor = NSColor(white: 0.45, alpha: 1); return l
}
private func check(_ title: String) -> NSButton {
    NSButton(checkboxWithTitle: title, target: nil, action: nil)
}
private func pin(_ child: NSView, to parent: NSView) {
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

// MARK: - App Coordinator

final class AppCoordinator: SSEClientDelegate, InformationMessageClientDelegate {
    private let settings: SettingsWindow
    private let overlay : OverlayWindow
    private let sse = SSEClient()
    private let messages = InformationMessageClient()
    private var refreshTimer: Timer?

    init() {
        let cfg  = OverlayConfig.load()
        settings = SettingsWindow()
        overlay  = OverlayWindow(cfg: cfg)
        overlay.rebuildLayout()
        overlay.show()

        settings.onChange = { [weak self] newCfg in
            self?.overlay.reconfigure(newCfg)
        }
        overlay.onPlacementRectChanged = { [weak self] rect in
            self?.settings.dragPickerDidSelect(rect)
        }
        settings.onPlacementModeChanged = { [weak self] placing in
            guard let self else { return }
            self.overlay.setPlacementMode(placing)
            self.overlay.rebuildLayout()
        }

        sse.delegate = self
        sse.connect()
        messages.delegate = self
        messages.connect()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.sse.fetchSnapshot()
        }
    }

    func sseClient(_ client: SSEClient, didReceive state: NBBState) {
        overlay.apply(state)
    }

    func sseClientConnectionChanged(_ client: SSEClient, connected: Bool) {
        settings.setConnected(connected)
    }

    func informationMessageClient(_ client: InformationMessageClient,
                                  didReceive messages: [NBBState.InformationMessage]) {
        overlay.applyMessages(messages)
    }
}

// MARK: - Entry Point
