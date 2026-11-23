import XCTest
import CryptoKit
@testable import ProbeCore

final class ArtifactTests: XCTestCase {
    func testAcceptsExactBytesAndRejectsCorruptionAndTruncation() throws {
        let bytes = Data("synthetic test artifact".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let candidate = InstallCandidate(schema: 1, displayName: "Test", bundleID: "org.example.test", buildVersion: "2", sha256: digest, byteCount: bytes.count)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes.write(to: url)
        XCTAssertNoThrow(try candidate.verifyArtifact(at: url))
        try Data(repeating: 1, count: bytes.count).write(to: url)
        XCTAssertThrowsError(try candidate.verifyArtifact(at: url))
        try bytes.dropLast().write(to: url)
        XCTAssertThrowsError(try candidate.verifyArtifact(at: url))
    }
    func testRejectsUnsupportedManifestAndUnsafeIdentity() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try InstallCandidate(schema: 2, displayName: "Test", bundleID: "org.example.test", buildVersion: "2", sha256: digest, byteCount: 1).validate())
        XCTAssertThrowsError(try InstallCandidate(schema: 1, displayName: "Test", bundleID: "org.example.\0test", buildVersion: "2", sha256: digest, byteCount: 1).validate())
        XCTAssertThrowsError(try InstallCandidate(schema: 1, displayName: "Test", bundleID: "org.example.test", buildVersion: "2", sha256: digest, byteCount: -1).validate())
    }
}
