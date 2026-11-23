import XCTest
@testable import ProbeCore

final class DownloadTests: XCTestCase {
    func testOnlyAcceptsCanonicalTailnetIPv4() {
        XCTAssertTrue(DownloadSettings.isTailnetIPv4("100.64.0.1"))
        XCTAssertTrue(DownloadSettings.isTailnetIPv4("100.127.255.254"))
        for address in ["100.128.0.1", "100.63.255.255", "8.8.8.8", "localhost", "100.064.0.1", "100.64.0.1.example.com"] {
            XCTAssertFalse(DownloadSettings.isTailnetIPv4(address))
        }
    }

    /// Optional real HTTPS integration check, using private settings outside the checkout.
    func testPrivateHTTPSIntegrationWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHONE_PROBE_DOWNLOAD_TEST_CONFIG"] else {
            throw XCTSkip("Private local server is not configured")
        }
        let settings = try JSONDecoder().decode(DownloadSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await BuildDownloader.download(settings: settings, destinationFolder: folder, progress: { _ in })
        try result.verifyArtifact(at: folder.appendingPathComponent("application.ipa"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        let denied = DownloadSettings(endpoint: settings.endpoint, token: String(repeating: "x", count: 43), certificateDER: settings.certificateDER, targetBundleID: settings.targetBundleID)
        do {
            _ = try await PinnedDownload(settings: denied, limit: 16_384).fetch(path: "/manifest.json")
            XCTFail("Incorrect token must be rejected")
        } catch DownloadIssue.http(let code) {
            XCTAssertEqual(code, 401)
        }
        var wrongCertificate = try XCTUnwrap(Data(base64Encoded: settings.certificateDER))
        wrongCertificate[wrongCertificate.count - 1] ^= 1
        let untrusted = DownloadSettings(endpoint: settings.endpoint, token: settings.token, certificateDER: wrongCertificate.base64EncodedString(), targetBundleID: settings.targetBundleID)
        do {
            _ = try await PinnedDownload(settings: untrusted, limit: 16_384).fetch(path: "/manifest.json")
            XCTFail("A different certificate must never be accepted")
        } catch let failure as DownloadConnectionFailure {
            // The certificate challenge was rejected before any authenticated HTTP request.
            XCTAssertTrue(failure.diagnostic.contains("certificate pin: rejected"))
        }
    }
}
