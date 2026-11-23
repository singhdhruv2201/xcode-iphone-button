import Foundation
import Darwin

public enum InstallOutcome: String, Codable, Sendable {
    case notRequested, verified, alreadyInstalled, unverified
}
public struct AuthenticationResult: Sendable {
    public let lines: [String]
    public let outcome: InstallOutcome
}
#if os(iOS)
import IDevice

/// All C handles stay on one worker. Never free an in-flight native call from a timer.
public enum AuthenticatedProbe {
    private static let worker = DispatchQueue(label: "PhoneInstallProbe.authentication")

    public static func run(host: String, bundleID: String, installStaged: Bool = false, progress: @escaping @Sendable (String) -> Void) async -> [String] {
        await runResult(host: host, bundleID: bundleID, installStaged: installStaged, progress: progress).lines
    }

    public static func runResult(host: String, bundleID: String, installStaged: Bool = false, progress: @escaping @Sendable (String) -> Void) async -> AuthenticationResult {
        await withCheckedContinuation { continuation in
            worker.async {
                continuation.resume(returning: perform(host: host, bundleID: bundleID, installStaged: installStaged, progress: progress))
            }
        }
    }

    private struct Failure: Error { let message: String }

    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, stage: String) throws {
        guard let error else { return }
        defer { idevice_error_free(error) }
        // Export numeric categories only. Library strings can contain device identifiers.
        throw Failure(message: "\(stage): FAILED (code \(error.pointee.code), subcode \(error.pointee.sub_code))")
    }

    private static func perform(host: String, bundleID: String, installStaged: Bool, progress: @escaping @Sendable (String) -> Void) -> AuthenticationResult {
        var lines: [String] = []
        let start = Date()
        func report(_ line: String) {
            let value = "\(line) (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)"
            lines.append(value)
            progress(value)
        }
        guard DeviceProbe.isLocalAddress(host), !bundleID.isEmpty, !bundleID.contains("\0") else {
            return AuthenticationResult(lines: ["Invalid local endpoint or app identity; no connection attempted."], outcome: .notRequested)
        }
        #if targetEnvironment(simulator)
        return AuthenticationResult(lines: ["Authenticated test requires the physical iPhone."], outcome: .notRequested)
        #else
        var candidate: InstallCandidate?
        if installStaged {
            do {
                let staged = try InstallCandidate.load()
                guard staged.bundleID != bundleID else { throw PairingIssue.invalidRecord }
                try staged.verifyArtifact(at: InstallCandidate.artifactURL())
                candidate = staged
                report("Staged artifact: size and SHA-256 verified")
            } catch {
                report("Staged artifact: invalid, missing, or targets this probe; no install request sent")
                return AuthenticationResult(lines: lines, outcome: .notRequested)
            }
        }
        var installRequested = false
        var installVerified = false
        var pairing: OpaquePointer?
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        var client: OpaquePointer?
        defer {
            if let client { installation_proxy_client_free(client) }
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter {
                if let error = adapter_close(adapter) { idevice_error_free(error) }
                adapter_free(adapter)
            }
            if let pairing { rp_pairing_file_free(pairing) }
        }
        do {
            let bytes = try PairingVault.load()
            try bytes.withUnsafeBytes { buffer in
                try check(rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), &pairing), stage: "Pairing record parsing")
            }
            report("Private pairing record: loaded")
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(49152).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw Failure(message: "Invalid IPv4 address") }
            // This limits library operations that use its global timeout. It is not an overall deadline.
            idevice_set_global_timeout(8)
            report("RemotePairing + tunnel + RSD: starting")
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    try check(tunnel_create_rppairing(socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size), "Phone Install Probe", pairing, nil, nil, &adapter, &handshake), stage: "RemotePairing / tunnel / RSD")
                }
            }
            guard adapter != nil, handshake != nil else { throw Failure(message: "Tunnel returned no usable handles") }
            report("Authenticated tunnel and RSD: connected")
            // The library can repair pairing if verification fails. Preserve updated credentials locally.
            var updated: UnsafeMutablePointer<UInt8>?
            var updatedLength = 0
            try check(rp_pairing_file_to_bytes(pairing, &updated, &updatedLength), stage: "Pairing persistence")
            if let updated {
                defer { idevice_data_free(updated, UInt(updatedLength)) }
                try PairingVault.save(Data(bytes: updated, count: updatedLength))
            }
            report("Installation service: connecting")
            try check(installation_proxy_connect_rsd(adapter, handshake, &client), stage: "Installation service connection")
            guard client != nil else { throw Failure(message: "Installation service returned no client") }
            report("Installation service: connected")
            var apps: UnsafeMutableRawPointer?
            var count = 0
            defer {
                if let apps { idevice_plist_array_free(apps.assumingMemoryBound(to: plist_t?.self), UInt(count)) }
            }
            try bundleID.withCString { id in
                var filter: UnsafePointer<CChar>? = id
                try withUnsafePointer(to: &filter) { ids in
                    try check(installation_proxy_get_apps(client, nil, ids, 1, &apps, &count), stage: "Probe-only app lookup")
                }
            }
            report(count == 1 ? "Probe-only app lookup: FOUND" : "Probe-only app lookup: returned \(count) entries (expected 1)")
            if let candidate {
                let before = try lookupVersion(client: client, bundleID: candidate.bundleID)
                guard before != candidate.buildVersion else {
                    report("Selected build already installed: installation SKIPPED; no new installation proven")
                    return AuthenticationResult(lines: lines, outcome: .alreadyInstalled)
                }
                report(before == nil ? "Target before install: absent" : "Target before install: different build")
                try uploadAndInstall(candidate, adapter: adapter, handshake: handshake, client: client,
                                     requested: &installRequested, report: report)
                let after = try lookupVersion(client: client, bundleID: candidate.bundleID)
                guard after == candidate.buildVersion else { throw Failure(message: "Post-install verification: build number did not match") }
                installVerified = true
                report("Post-install verification: exact bundle and build MATCH")
            }
        } catch let failure as Failure {
            report(failure.message)
        } catch {
            report("Private pairing storage: unavailable or invalid; reconnect USB for preparation")
        }
        if installVerified {
            report("App installation: SUCCESS; manual launch still needs verification")
        } else if installRequested {
            report("App installation: NOT VERIFIED; inspect installed version before retrying")
        } else {
            report("App installation: NOT TESTED; no install request sent")
        }
        return AuthenticationResult(lines: lines, outcome: installVerified ? .verified : (installRequested ? .unverified : .notRequested))
        #endif
    }

    private static func lookupVersion(client: OpaquePointer?, bundleID: String) throws -> String? {
        var apps: UnsafeMutableRawPointer?
        var count = 0
        defer {
            if let apps { idevice_plist_array_free(apps.assumingMemoryBound(to: plist_t?.self), UInt(count)) }
        }
        try bundleID.withCString { id in
            var filter: UnsafePointer<CChar>? = id
            try withUnsafePointer(to: &filter) { ids in
                try check(installation_proxy_get_apps(client, nil, ids, 1, &apps, &count), stage: "Target version lookup")
            }
        }
        if count == 0 { return nil }
        guard count == 1, let apps, let app = apps.assumingMemoryBound(to: plist_t?.self).pointee else {
            throw Failure(message: "Target lookup: unexpected result count")
        }
        func string(_ key: String) -> String? {
            guard let item = plist_dict_get_item(app, key) else { return nil }
            var value: UnsafeMutablePointer<CChar>?
            plist_get_string_val(item, &value)
            guard let value else { return nil }
            defer { plist_mem_free(value) }
            return String(cString: value)
        }
        guard string("CFBundleIdentifier") == bundleID, let version = string("CFBundleVersion") else {
            throw Failure(message: "Target lookup: missing or mismatched app identity")
        }
        return version
    }

    private static func uploadAndInstall(_ candidate: InstallCandidate, adapter: OpaquePointer?,
                                         handshake: OpaquePointer?, client: OpaquePointer?,
                                         requested: inout Bool, report: (String) -> Void) throws {
        var afc: OpaquePointer?
        var remoteFile: OpaquePointer?
        let staging = "/PublicStaging/PhoneInstallProbe-\(UUID().uuidString)"
        var createdDirectory = false
        defer {
            if let remoteFile, let error = afc_file_close(remoteFile) { idevice_error_free(error) }
            if let afc {
                if createdDirectory, let error = afc_remove_path_and_contents(afc, staging) { idevice_error_free(error) }
                afc_client_free(afc)
            }
        }
        report("AFC upload service: connecting")
        try check(afc_client_connect_rsd(adapter, handshake, &afc), stage: "AFC service connection")
        // PublicStaging may already exist. Creation of our unique child must succeed.
        if let error = afc_make_directory(afc, "/PublicStaging") { idevice_error_free(error) }
        try check(afc_make_directory(afc, staging), stage: "AFC staging directory")
        createdDirectory = true
        let remotePath = staging + "/application.ipa"
        try check(afc_file_open(afc, remotePath, AfcWrOnly, &remoteFile), stage: "AFC artifact open")
        let source = try FileHandle(forReadingFrom: InstallCandidate.artifactURL())
        defer { try? source.close() }
        var uploaded = 0
        while let chunk = try source.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try chunk.withUnsafeBytes { bytes in
                try check(afc_file_write(remoteFile, bytes.bindMemory(to: UInt8.self).baseAddress, chunk.count), stage: "AFC upload")
            }
            uploaded += chunk.count
        }
        guard uploaded == candidate.byteCount else { throw Failure(message: "AFC upload: unexpected byte count") }
        let closeResult = afc_file_close(remoteFile)
        remoteFile = nil // close consumes the native handle even on error
        try check(closeResult, stage: "AFC upload close")
        report("AFC upload: complete")
        guard let options = plist_new_dict(), let kind = plist_new_string("Developer") else {
            throw Failure(message: "Installation options: allocation failed")
        }
        defer { plist_free(options) }
        plist_dict_set_item(options, "PackageType", kind)
        report("Installation request: sending signed build")
        requested = true
        try check(installation_proxy_install(client, remotePath, options), stage: "App installation")
        report("Installation service: reported success")
    }
}
#else
public enum AuthenticatedProbe {
    public static func run(host: String, bundleID: String, installStaged: Bool = false, progress: @escaping @Sendable (String) -> Void) async -> [String] {
        await runResult(host: host, bundleID: bundleID, installStaged: installStaged, progress: progress).lines
    }

    public static func runResult(host: String, bundleID: String, installStaged: Bool = false, progress: @escaping @Sendable (String) -> Void) async -> AuthenticationResult {
        AuthenticationResult(lines: ["Authenticated test requires the physical iPhone."], outcome: .notRequested)
    }
}
#endif
