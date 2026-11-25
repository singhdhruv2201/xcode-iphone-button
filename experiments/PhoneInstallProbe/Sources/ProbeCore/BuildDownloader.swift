import Foundation
import Security

public enum DownloadIssue: Error {
    case invalidResponse, wrongApp, tooLarge, untrustedServer
    case http(Int)
}

public struct DownloadConnectionFailure: Error, Sendable {
    public let diagnostic: String
}

/// Each request gets an ephemeral session, a fixed endpoint and certificate, and no redirects.
final class PinnedDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let settings: DownloadSettings
    let limit: Int64
    private let diagnosticLock = NSLock()
    private var trustStatus = "TLS certificate challenge: not received"
    init(settings: DownloadSettings, limit: Int64) { self.settings = settings; self.limit = limit }

    private func recordTrust(_ status: String) {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        trustStatus = status
    }

    private func connectionFailure(_ error: Error) -> DownloadConnectionFailure {
        diagnosticLock.lock()
        let status = trustStatus
        diagnosticLock.unlock()
        var details = ["Network code: \((error as NSError).code)", status]
        var current = error as NSError
        let knownDomains = [NSURLErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork", "kCFErrorDomainSSL", NSPOSIXErrorDomain]
        for _ in 0..<3 {
            if let ssl = current.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber {
                details.append("Stream error code: \(ssl.intValue)")
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            let domain = knownDomains.contains(underlying.domain) ? underlying.domain : "underlying"
            details.append("\(domain) code: \(underlying.code)")
            current = underlying
        }
        return DownloadConnectionFailure(diagnostic: details.joined(separator: "\n"))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        recordTrust("TLS certificate challenge: received")
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == URL(string: settings.endpoint)?.host,
              let trust = challenge.protectionSpace.serverTrust,
              let der = Data(base64Encoded: settings.certificateDER),
              let pinned = SecCertificateCreateWithData(nil, der as CFData),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first, SecCertificateCopyData(leaf) as Data == der else {
            recordTrust("TLS endpoint or exact certificate pin: rejected")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let policy = SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [pinned] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            recordTrust("TLS private trust policy: setup failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var evaluationError: CFError?
        guard SecTrustEvaluateWithError(trust, &evaluationError) else {
            let code = evaluationError.map { CFErrorGetCode($0) } ?? 0
            recordTrust("TLS pinned certificate validity/IP evaluation: rejected (code \(code))")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        recordTrust("TLS certificate pin, validity and IP identity: accepted")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func fetch(path: String, body: Data? = nil, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 300) async throws -> URL {
        try settings.validate()
        guard let url = URL(string: settings.endpoint + path) else { throw DownloadIssue.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: request, delegate: self)
        } catch {
            throw connectionFailure(error)
        }
        let (temporary, response) = result
        guard let http = response as? HTTPURLResponse else { throw DownloadIssue.invalidResponse }
        guard http.statusCode == 200 else { throw DownloadIssue.http(http.statusCode) }
        guard http.url == url else { throw DownloadIssue.invalidResponse }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size > 0, Int64(size) <= limit, response.expectedContentLength == Int64(size) else { throw DownloadIssue.invalidResponse }
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: retained)
        return retained
    }
}

public enum BuildDownloader {
    public struct ConnectionCheck: Sendable {
        public let reachable: Bool
        public let diagnostic: String
    }

    /// A read-only, authenticated check; diagnostics omit addresses and credentials.
    public static func checkMacConnection() async -> ConnectionCheck {
        guard let settings = try? DownloadSettingsVault.load() else {
            return ConnectionCheck(reachable: false, diagnostic: "Private Mac connection settings are unavailable.")
        }
        return await checkMacConnection(settings: settings)
    }

    public static func macIsReachable() async -> Bool {
        await checkMacConnection().reachable
    }

    static func macIsReachable(settings: DownloadSettings) async -> Bool {
        await checkMacConnection(settings: settings).reachable
    }

    static func checkMacConnection(settings: DownloadSettings) async -> ConnectionCheck {
        let started = Date()
        var reachable = false
        let message: String
        do {
            let file = try await PinnedDownload(settings: settings, limit: 16_384)
                .fetch(path: "/manifest.json", requestTimeout: 8, resourceTimeout: 8)
            defer { try? FileManager.default.removeItem(at: file) }
            let candidate = try JSONDecoder().decode(InstallCandidate.self, from: Data(contentsOf: file))
            try candidate.validate()
            guard candidate.bundleID == settings.targetBundleID else { throw DownloadIssue.wrongApp }
            reachable = true
            message = "Pinned HTTPS, authentication and Mac identity: accepted."
        } catch let failure as DownloadConnectionFailure {
            message = failure.diagnostic
        } catch DownloadIssue.http(let status) {
            message = "Mac returned HTTP status \(status)."
        } catch DownloadIssue.wrongApp {
            message = "Mac manifest does not match the private connection settings."
        } catch {
            message = "Private connection settings or Mac response failed validation."
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        return ConnectionCheck(reachable: reachable, diagnostic: "Mac connection check (\(elapsed)s)\n" + message)
    }

    public struct Job: Codable, Sendable {
        public let id: String
        public let status: String
        public let message: String
        public let manifest: InstallCandidate?
        public let selection: Selection?
        public struct Selection: Codable, Sendable {
            public let projectID: String
            public let scheme: String
        }
        public func validateSelection(_ expected: ProjectSelection?) throws {
            if let expected {
                try expected.validate()
                guard selection?.projectID == expected.projectID, selection?.scheme == expected.scheme else {
                    throw DownloadIssue.wrongApp
                }
            } else if selection != nil { throw DownloadIssue.wrongApp }
        }
    }

    public static func job(id: UUID, submit: Bool, selection: ProjectSelection? = nil, timeout: TimeInterval = 30) async throws -> Job {
        let settings = try DownloadSettingsVault.load()
        let identifier = id.uuidString.lowercased()
        var request = ["id": identifier]
        if let selection {
            try selection.validate()
            request["projectID"] = selection.projectID
            request["scheme"] = selection.scheme
        }
        let body = submit ? try JSONEncoder().encode(request) : nil
        let file = try await PinnedDownload(settings: settings, limit: 16_384)
            .fetch(path: submit ? "/jobs" : "/jobs/" + identifier, body: body, requestTimeout: timeout, resourceTimeout: timeout)
        defer { try? FileManager.default.removeItem(at: file) }
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: file))
        guard job.id == identifier, ["building", "ready", "failed"].contains(job.status) else {
            throw DownloadIssue.invalidResponse
        }
        try job.validateSelection(selection)
        return job
    }

    public static func download(job: Job, selection: ProjectSelection, progress: @escaping @Sendable (String) -> Void) async throws -> InstallCandidate {
        try job.validateSelection(selection)
        guard job.status == "ready", let candidate = job.manifest else { throw DownloadIssue.invalidResponse }
        try candidate.validate()
        return try await download(settings: DownloadSettingsVault.load(), destinationFolder: nil,
                                  selected: candidate, approvedBundleID: candidate.bundleID, progress: progress)
    }

    public static func download(candidate: InstallCandidate, progress: @escaping @Sendable (String) -> Void) async throws -> InstallCandidate {
        try await download(settings: DownloadSettingsVault.load(), destinationFolder: nil, selected: candidate, progress: progress)
    }

    public static func download(progress: @escaping @Sendable (String) -> Void) async throws -> InstallCandidate {
        let settings = try DownloadSettingsVault.load()
        return try await download(settings: settings, destinationFolder: nil, progress: progress)
    }

    static func download(settings: DownloadSettings, destinationFolder: URL?, selected: InstallCandidate? = nil, approvedBundleID: String? = nil, progress: @escaping @Sendable (String) -> Void) async throws -> InstallCandidate {
        progress("Private download settings: loaded")
        let candidate: InstallCandidate
        if let selected { candidate = selected }
        else {
            let manifestFile = try await PinnedDownload(settings: settings, limit: 16_384).fetch(path: "/manifest.json")
            defer { try? FileManager.default.removeItem(at: manifestFile) }
            candidate = try JSONDecoder().decode(InstallCandidate.self, from: Data(contentsOf: manifestFile))
        }
        try candidate.validate()
        guard candidate.bundleID == (approvedBundleID ?? settings.targetBundleID) else { throw DownloadIssue.wrongApp }
        progress("Pinned HTTPS connection and authenticated manifest: accepted")
        let artifact = try await PinnedDownload(settings: settings, limit: Int64(candidate.byteCount))
            .fetch(path: "/artifacts/\(candidate.sha256).ipa")
        defer { try? FileManager.default.removeItem(at: artifact) }
        try candidate.verifyArtifact(at: artifact)
        progress("Downloaded artifact: size and SHA-256 verified")
        let folder = try destinationFolder ?? InstallCandidate.folder()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("manifest.json")
        let destination = folder.appendingPathComponent("application.ipa")
        // A crash during replacement must leave no valid manifest for a partial artifact.
        if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: artifact, to: destination)
        try Data("private-download".utf8).write(to: folder.appendingPathComponent("source.txt"), options: .atomic)
        try JSONEncoder().encode(candidate).write(to: manifest, options: .atomic)
        progress("Downloaded build: saved and ready for offline installation")
        return candidate
    }
}
