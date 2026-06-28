import XCTest
@testable import MST

// MARK: - Mock URLProtocol

/// Intercepts all URLSession requests in the test session.
/// Each test sets `handler` before calling the code under test.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // nonisolated(unsafe) lets Swift 6 know we manage access ourselves
    // (tests run serially on the main actor so there is no actual data race).
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Shared helpers

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func githubPayload(tag: String, assets: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["tag_name": tag, "assets": assets])
}

private func singleAsset(name: String, url: String) -> [String: Any] {
    ["name": name, "browser_download_url": url]
}

private func http200(for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

private func http(_ code: Int, for url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
}

private let apiURL = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!

// MARK: - Version comparison

@MainActor
final class AutoUpdaterVersionTests: XCTestCase {

    var updater: AutoUpdater!

    override func setUp() async throws {
        updater = AutoUpdater(session: mockSession(), currentVersion: "1.0.0")
    }

    func testPatchBump_isNewer() {
        XCTAssertTrue(updater.isNewer("1.0.1", than: "1.0.0"))
    }

    func testMinorBump_isNewer() {
        XCTAssertTrue(updater.isNewer("1.1.0", than: "1.0.0"))
    }

    func testMajorBump_isNewer() {
        XCTAssertTrue(updater.isNewer("2.0.0", than: "1.0.0"))
    }

    func testSameVersion_notNewer() {
        XCTAssertFalse(updater.isNewer("1.0.0", than: "1.0.0"))
    }

    func testOlderRemote_notNewer() {
        XCTAssertFalse(updater.isNewer("0.9.9", than: "1.0.0"))
    }

    func testShortRemoteVersion_treatedAsZeroPadded() {
        // "2" is effectively "2.0.0"
        XCTAssertTrue(updater.isNewer("2", than: "1.5.0"))
    }

    func testMultiDigitComponents() {
        XCTAssertTrue(updater.isNewer("10.0.0", than: "9.99.99"))
    }

    func testPatchRollover_notNewer() {
        XCTAssertFalse(updater.isNewer("1.0.9", than: "1.1.0"))
    }

    func testZeroVersions() {
        XCTAssertFalse(updater.isNewer("0.0.0", than: "0.0.0"))
        XCTAssertTrue(updater.isNewer("0.0.1", than: "0.0.0"))
    }
}

// MARK: - App bundle discovery

@MainActor
final class AutoUpdaterFindAppTests: XCTestCase {

    var updater: AutoUpdater!
    var tempDir: URL!

    override func setUp() async throws {
        updater = AutoUpdater(session: mockSession(), currentVersion: "1.0.0")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSTTestExtract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFindsApp_atRoot() throws {
        let appDir = tempDir.appendingPathComponent("MST.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let found = try updater.findApp(in: tempDir)
        XCTAssertEqual(found.lastPathComponent, "MST.app")
    }

    func testFindsApp_oneLevelDeep() throws {
        let folder = tempDir.appendingPathComponent("MST-2.0.0-macOS")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("MST.app"),
            withIntermediateDirectories: true
        )

        let found = try updater.findApp(in: tempDir)
        XCTAssertEqual(found.lastPathComponent, "MST.app")
    }

    func testFindsApp_twoLevelsDeep() throws {
        let deep = tempDir.appendingPathComponent("a/b/MST.app")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let found = try updater.findApp(in: tempDir)
        XCTAssertEqual(found.lastPathComponent, "MST.app")
    }

    func testMissingApp_throws() {
        XCTAssertThrowsError(try updater.findApp(in: tempDir)) { error in
            let nsErr = error as NSError
            XCTAssertEqual(nsErr.domain, "AutoUpdater")
            XCTAssertEqual(nsErr.code, 3)
        }
    }

    func testIgnoresNonAppBundles() throws {
        // .framework should not be treated as the update target
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("MST.framework"),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try updater.findApp(in: tempDir))
    }
}

// MARK: - check() state machine

@MainActor
final class AutoUpdaterCheckTests: XCTestCase {

    var updater: AutoUpdater!

    override func setUp() async throws {
        MockURLProtocol.handler = nil
        updater = AutoUpdater(session: mockSession(), currentVersion: "1.0.0")
    }

    // MARK: Up to date

    func testCheck_sameVersion_yieldsUpToDate() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v1.0.0", assets: [
                singleAsset(name: "MST-1.0.0-macOS.zip", url: "https://example.com/MST-1.0.0-macOS.zip")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .upToDate)
    }

    func testCheck_olderRemote_yieldsUpToDate() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v0.9.0", assets: [
                singleAsset(name: "MST-0.9.0-macOS.zip", url: "https://example.com/MST-0.9.0-macOS.zip")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .upToDate)
    }

    // MARK: Update available

    func testCheck_newerVersion_macOSZip_yieldsAvailable() async throws {
        let assetURL = URL(string: "https://example.com/MST-2.0.0-macOS.zip")!

        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v2.0.0", assets: [
                singleAsset(name: "MST-2.0.0-macOS.zip", url: assetURL.absoluteString)
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .available(version: "2.0.0", asset: assetURL))
    }

    func testCheck_vTagStripped_fromVersion() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v3.1.4", assets: [
                singleAsset(name: "MST-3.1.4-macOS.zip", url: "https://example.com/MST-3.1.4-macOS.zip")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()

        guard case .available(let version, _) = updater.updateState else {
            return XCTFail("Expected .available, got \(updater.updateState)")
        }
        XCTAssertEqual(version, "3.1.4")
    }

    func testCheck_fallbackMstZipName_yieldsAvailable() async throws {
        let assetURL = URL(string: "https://example.com/MST.zip")!

        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "2.0.0", assets: [
                singleAsset(name: "MST.zip", url: assetURL.absoluteString)
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .available(version: "2.0.0", asset: assetURL))
    }

    func testCheck_caseInsensitiveAssetMatch() async throws {
        let assetURL = URL(string: "https://example.com/MST-2.0.0-MacOS.zip")!

        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "2.0.0", assets: [
                singleAsset(name: "MST-2.0.0-MacOS.zip", url: assetURL.absoluteString)
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .available(version: "2.0.0", asset: assetURL))
    }

    // MARK: No usable asset → idle

    func testCheck_onlySourceInstallerZip_yieldsIdle() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v2.0.0", assets: [
                singleAsset(name: "MST-2.0.0-source-installer.zip", url: "https://example.com/source.zip")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    func testCheck_emptyAssets_yieldsIdle() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v2.0.0", assets: [])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    func testCheck_dmgOnlyRelease_yieldsIdle() async throws {
        MockURLProtocol.handler = { _ in
            let data = try githubPayload(tag: "v2.0.0", assets: [
                singleAsset(name: "MST-2.0.0-macOS.dmg", url: "https://example.com/MST.dmg")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    // MARK: Network / server errors → idle

    func testCheck_networkError_yieldsIdle() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    func testCheck_non200Response_yieldsIdle() async {
        MockURLProtocol.handler = { _ in (http(404, for: apiURL), Data()) }
        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    func testCheck_malformedJSON_yieldsIdle() async {
        MockURLProtocol.handler = { _ in (http200(for: apiURL), Data("not json".utf8)) }
        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    func testCheck_missingTagName_yieldsIdle() async throws {
        MockURLProtocol.handler = { _ in
            let data = try JSONSerialization.data(withJSONObject: [
                "assets": [singleAsset(name: "MST-2.0.0-macOS.zip", url: "https://example.com/x.zip")]
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()
        XCTAssertEqual(updater.updateState, .idle)
    }

    // MARK: State sequencing

    func testCheck_setsCheckingBeforeRequest() async throws {
        var seenChecking = false

        MockURLProtocol.handler = { [self] _ in
            // By the time URLSession calls back, check() has already set .checking
            seenChecking = self.updater.updateState == .checking
            let data = try githubPayload(tag: "v1.0.0", assets: [
                singleAsset(name: "MST-1.0.0-macOS.zip", url: "https://example.com/MST.zip")
            ])
            return (http200(for: apiURL), data)
        }

        await updater.check()

        XCTAssertTrue(seenChecking, "updateState must be .checking while the request is in-flight")
    }
}
