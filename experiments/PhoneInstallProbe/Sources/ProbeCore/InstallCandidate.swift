import Foundation
import CryptoKit

public struct InstallCandidate: Codable, Sendable {
    public let schema: Int
    public let displayName: String
    public let bundleID: String
    public let buildVersion: String
    public let sha256: String
    public let byteCount: Int

    public static func folder() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("InstallCandidate", isDirectory: true)
    }
    public static func artifactURL() throws -> URL { try folder().appendingPathComponent("application.ipa") }

    public static func load() throws -> InstallCandidate {
        let data = try Data(contentsOf: folder().appendingPathComponent("manifest.json"))
        guard data.count < 16_384 else { throw PairingIssue.invalidRecord }
        let candidate = try JSONDecoder().decode(Self.self, from: data)
        try candidate.validate()
        return candidate
    }

    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard schema == 1, !displayName.isEmpty, displayName.count <= 128,
              !bundleID.isEmpty, bundleID.count <= 255, bundleID.contains("."),
              bundleID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !buildVersion.isEmpty, buildVersion.count <= 64, !buildVersion.contains("\0"),
              byteCount > 0, byteCount <= 512 * 1_024 * 1_024,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw PairingIssue.invalidRecord
        }
    }

    public func verifyArtifact(at url: URL) throws {
        try validate()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 512 * 1_024), !chunk.isEmpty {
            size += chunk.count
            guard size <= byteCount else { throw PairingIssue.invalidRecord }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == byteCount, digest == sha256 else { throw PairingIssue.invalidRecord }
    }
}
