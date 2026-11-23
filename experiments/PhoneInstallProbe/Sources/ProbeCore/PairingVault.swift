import Foundation
import CryptoKit
import Security

public enum PairingIssue: Error {
    case invalidRecord, unavailable, storage
}

/// Private credentials are never bundled with the app or included in a report.
public enum PairingVault {
    private static let service = "PhoneInstallProbe.RemotePairing"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "local-device",
         kSecAttrSynchronizable as String: false]
    }

    public static func validate(_ data: Data) throws {
        guard data.count <= 16_384,
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let secret = p["private_key"] as? Data, secret.count == 32,
              let pub = p["public_key"] as? Data, pub.count == 32,
              let id = p["identifier"] as? String, UUID(uuidString: id) != nil,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret),
              key.publicKey.rawRepresentation == pub else { throw PairingIssue.invalidRecord }
        if let irk = p["alt_irk"] { guard let bytes = irk as? Data, bytes.count == 16 else { throw PairingIssue.invalidRecord } }
    }

    public static func save(_ data: Data) throws {
        try validate(data)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw PairingIssue.storage }
        } else if update != errSecSuccess { throw PairingIssue.storage }
    }

    public static func load() throws -> Data {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw PairingIssue.unavailable }
        try validate(data)
        return data
    }

    /// USB stages this one file in the developer app container; remove after import.
    public static func importFromUSB() throws -> Bool {
        let fm = FileManager.default
        let folder = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = folder.appendingPathComponent("PairingImport.plist")
        guard fm.fileExists(atPath: url.path) else { return false }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        let data = try Data(contentsOf: url)
        do {
            try save(data)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        try fm.removeItem(at: url)
        return true
    }
}
