import Foundation
import Security

public struct DownloadSettings: Codable, Sendable {
    public let endpoint: String
    public let token: String
    public let certificateDER: String
    public let targetBundleID: String

    public func validate() throws {
        guard let url = URLComponents(string: endpoint), url.scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty, let host = url.host,
              let port = url.port, (1...65535).contains(port),
              Self.isTailnetIPv4(host), token.count >= 40, token.count <= 128,
              token.allSatisfy({ "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".contains($0) }),
              !targetBundleID.isEmpty, !targetBundleID.contains("\0"),
              let der = Data(base64Encoded: certificateDER), der.count < 16_384,
              SecCertificateCreateWithData(nil, der as CFData) != nil else { throw PairingIssue.invalidRecord }
    }

    public static func isTailnetIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { UInt8($0) }
        guard numbers.count == 4, zip(parts, numbers).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return numbers[0] == 100 && (64...127).contains(numbers[1])
    }
}

public enum DownloadSettingsVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "PhoneInstallProbe.Download",
         kSecAttrAccount as String: "private-mac",
         kSecAttrSynchronizable as String: false]
    }
    public static func load() throws -> DownloadSettings {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw PairingIssue.unavailable }
        let settings = try JSONDecoder().decode(DownloadSettings.self, from: data)
        try settings.validate()
        return settings
    }
    public static func importFromUSB() throws {
        let fm = FileManager.default
        let folder = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = folder.appendingPathComponent("DownloadImport.json")
        guard fm.fileExists(atPath: url.path) else { return }
        defer { try? fm.removeItem(at: url) }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        let data = try Data(contentsOf: url)
        guard data.count < 32_768 else { throw PairingIssue.invalidRecord }
        let settings = try JSONDecoder().decode(DownloadSettings.self, from: data)
        try settings.validate()
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw PairingIssue.storage }
        } else if result != errSecSuccess { throw PairingIssue.storage }
    }
}
