import CoreGraphics
import Foundation

struct TrackedWindow: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double
    let memoryUsage: Int

    var displayName: String {
        if title.isEmpty {
            return ownerName
        }
        return "\(ownerName) - \(title)"
    }

    var sizeDescription: String {
        "\(Int(frame.width)) x \(Int(frame.height))"
    }
}
