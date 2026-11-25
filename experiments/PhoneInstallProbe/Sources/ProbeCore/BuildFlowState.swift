import Foundation

/// Persist only coordination data, never credentials or pairing records.
public struct BuildFlowState: Codable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case checking, connect, building, prepare, installing, restore, done, interrupted
        case master, downloadReady, downloading, installReady
    }
    public var job = UUID()
    public var phase: Phase = .connect
    public var nonce = UUID()
    public var started = Date()
    public var selection: ProjectSelection?
    public var purpose: String?
    public var masterSubmitted: Bool?
    public var masterFailures: Int?
    public var masterManifest: InstallCandidate?
    public var artifactHash: String?
    public var result = ""
    public init() {}

    public mutating func handoff(_ phase: Phase) {
        self.phase = phase
        nonce = UUID()
    }
    public var masterToken: String { job.uuidString + ":" + nonce.uuidString }
    public func acceptsMasterRun(_ token: String, phases: [Phase], now: Date = Date()) -> Bool {
        purpose == "master" && token == masterToken && phases.contains(phase)
            && now.timeIntervalSince(started) >= 0 && now.timeIntervalSince(started) < 3600
            && selection != nil
    }
    public func acceptsMasterCallback(_ url: URL) -> Bool {
        purpose == "master" && phase != .done && callbackMatches(url, phase: "master")
    }
    public func accepts(_ url: URL) -> Bool {
        [.connect, .prepare, .restore].contains(phase) && callbackMatches(url, phase: phase.rawValue)
    }
    private func callbackMatches(_ url: URL, phase expectedPhase: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "phoneinstallprobe", parts.host == "resume" else { return false }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        return value("job") == job.uuidString && value("nonce") == nonce.uuidString && value("phase") == expectedPhase
            && Date().timeIntervalSince(started) < 3600
    }
    public func shortcutURL(name: String, input: String? = nil) -> URL {
        func callback(_ outcome: String) -> String {
            var url = URLComponents()
            url.scheme = "phoneinstallprobe"; url.host = "resume"
            url.queryItems = [URLQueryItem(name: "job", value: job.uuidString),
                             URLQueryItem(name: "nonce", value: nonce.uuidString),
                             URLQueryItem(name: "phase", value: phase.rawValue),
                             URLQueryItem(name: "outcome", value: outcome)]
            return url.url!.absoluteString
        }
        var url = URLComponents()
        url.scheme = "shortcuts"; url.host = "x-callback-url"; url.path = "/run-shortcut"
        url.queryItems = [URLQueryItem(name: "name", value: name),
                         URLQueryItem(name: "x-success", value: callback("success")),
                         URLQueryItem(name: "x-error", value: callback("error")),
                         URLQueryItem(name: "x-cancel", value: callback("cancel"))]
        if let input {
            url.queryItems! += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)]
        }
        return url.url!
    }
}
