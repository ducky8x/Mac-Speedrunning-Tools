import XCTest
@testable import MST

final class AutoUpdaterTests: XCTestCase {
    func testUsesCustomFeedURLWhenProvided() {
        let defaults = UserDefaults(suiteName: "AutoUpdaterTests")!
        defaults.removePersistentDomain(forName: "AutoUpdaterTests")

        defaults.set("https://example.com/custom-appcast.xml", forKey: "macSpeedrunningTools.updateFeedURL")

        let resolved = AppMetadata.updateFeedURL(from: ["SUFeedURL": "https://example.com/ignored.xml"], defaults: defaults)

        XCTAssertEqual(resolved, "https://example.com/custom-appcast.xml")
    }

    func testFallsBackToBundleFeedURLWhenNoOverrideExists() {
        let defaults = UserDefaults(suiteName: "AutoUpdaterTests")!
        defaults.removePersistentDomain(forName: "AutoUpdaterTests")

        let resolved = AppMetadata.updateFeedURL(from: ["SUFeedURL": "https://example.com/appcast.xml"], defaults: defaults)

        XCTAssertEqual(resolved, "https://example.com/appcast.xml")
    }
}
