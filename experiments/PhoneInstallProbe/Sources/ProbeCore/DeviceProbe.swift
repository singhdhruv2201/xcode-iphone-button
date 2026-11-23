import Foundation
import Network
import Darwin

public enum ProbeProtocol: String, CaseIterable, Sendable {
    case remotePairing = "RemotePairing TCP"
    case lockdown = "Lockdown QueryType"

    var port: UInt16 { self == .remotePairing ? 49152 : 62078 }
}

public struct ProbeResult: Sendable {
    public let outcome: String
    public let seconds: Double
    public var tcpAccepted: Bool = false
}

public enum FrameCodec {
    public static func encode(_ dictionary: [String: String]) throws -> Data {
        let payload = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        var size = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &size) { Data($0) }
        framed.append(payload)
        return framed
    }

    public static func length(_ bytes: Data) -> Int? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0, value <= 65_536 else { return nil }
        return Int(value)
    }

    public static func isLockdownReply(_ data: Data) -> Bool {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { return false }
        return dictionary["Type"] as? String == "com.apple.mobile.lockdown"
    }
}

/// One read-only connection. All callbacks, deadline and completion run on one serial queue.
/// No pair record, install request, discovery, port scan, or automatic network changes.
public final class DeviceProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhoneInstallProbe.connection")
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var started = Date()

    public init() {}

    public static func isLocalAddress(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    public func run(host: String, kind: ProbeProtocol) async -> ProbeResult {
        guard Self.isLocalAddress(host) else {
            return ProbeResult(outcome: "Enter the private Device IP from LocalDevVPN settings.", seconds: 0)
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.started = Date()
                let connection = NWConnection(host: NWEndpoint.Host(host),
                    port: NWEndpoint.Port(rawValue: kind.port)!, using: .tcp)
                self.connection = connection
                let deadline = DispatchWorkItem { self.finish("Timed out (6 seconds)") }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + 6, execute: deadline)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if kind == .remotePairing {
                            self.finish("TCP accepted; authentication not tested", tcpAccepted: true)
                        } else {
                            self.queryType()
                        }
                    case .failed(let error): self.finish(Self.describe(error))
                    case .cancelled: self.finish("Connection cancelled")
                    default: break // A waiting path is allowed until the fixed deadline.
                    }
                }
                connection.start(queue: self.queue)
            }
        }
    }

    private func queryType() {
        guard let request = try? FrameCodec.encode(["Request": "QueryType", "Label": "PhoneInstallProbe"]) else {
            finish("Could not encode request")
            return
        }
        connection?.send(content: request, completion: .contentProcessed { error in
            if let error { self.finish(Self.describe(error)); return }
            self.readExactly(4) { header in
                guard let count = FrameCodec.length(header) else { self.finish("Invalid reply length"); return }
                self.readExactly(count) { payload in
                    self.finish(FrameCodec.isLockdownReply(payload)
                        ? "Lockdown replied; authentication not tested"
                        : "Reply received; not a valid Lockdown QueryType reply")
                }
            }
        })
    }

    private func readExactly(_ count: Int, accumulated: Data = Data(), then: @escaping (Data) -> Void) {
        guard continuation != nil else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { data, _, complete, error in
            guard self.continuation != nil else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count == count { then(buffer); return }
            if let error { self.finish(Self.describe(error)); return }
            if complete { self.finish("Connection closed before a complete reply"); return }
            self.readExactly(count, accumulated: buffer, then: then)
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED: return "Connection refused"
            case .ECONNRESET: return "Connection reset"
            case .EPERM, .EACCES: return "Connection denied by system"
            case .ENETUNREACH, .EHOSTUNREACH: return "No route to service"
            default: return "Socket error \(code.rawValue)"
            }
        }
        return "Network error" // Do not export addresses or raw framework descriptions.
    }

    private func finish(_ outcome: String, tcpAccepted: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation.resume(returning: ProbeResult(outcome: outcome, seconds: Date().timeIntervalSince(started), tcpAccepted: tcpAccepted))
    }
}
