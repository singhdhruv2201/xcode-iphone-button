import Foundation

public struct MacProject: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let displayPath: String
    public let kind: String

    public static func validID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    public func validate() throws {
        guard Self.validID(id), !name.isEmpty, name.count <= 200,
              !displayPath.isEmpty, displayPath.count <= 1500, !displayPath.hasPrefix("/"),
              !displayPath.split(separator: "/").contains(".."),
              !name.contains("\0"), !displayPath.contains("\0"),
              ["project", "workspace"].contains(kind) else { throw DownloadIssue.invalidResponse }
    }
    public func selection(scheme: String) -> ProjectSelection {
        ProjectSelection(projectID: id, projectName: name, displayPath: displayPath, scheme: scheme)
    }
}

public struct ProjectSelection: Codable, Equatable, Sendable {
    public let projectID: String
    public let projectName: String
    public let displayPath: String
    public let scheme: String

    public func validate() throws {
        guard MacProject.validID(projectID), !scheme.isEmpty, scheme.count <= 200,
              !scheme.contains("\0") else { throw DownloadIssue.invalidResponse }
    }
}

public struct ProjectList: Codable, Sendable {
    public let projects: [MacProject]
    public let limited: Bool
    public func validate() throws {
        guard projects.count <= 256, Set(projects.map(\.id)).count == projects.count else { throw DownloadIssue.invalidResponse }
        try projects.forEach { try $0.validate() }
    }
}

public struct ProjectSchemes: Codable, Sendable {
    public let projectID: String
    public let schemes: [String]
    public func validate(for id: String) throws {
        guard projectID == id, schemes.count <= 64, Set(schemes).count == schemes.count,
              schemes.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains("\0") }) else {
            throw DownloadIssue.invalidResponse
        }
    }
}

public enum ProjectCatalogClient {
    public static func projects() async throws -> ProjectList {
        let file = try await PinnedDownload(settings: DownloadSettingsVault.load(), limit: 512 * 1024).fetch(path: "/projects")
        defer { try? FileManager.default.removeItem(at: file) }
        let list = try JSONDecoder().decode(ProjectList.self, from: Data(contentsOf: file))
        try list.validate()
        return list
    }
    public static func schemes(for projectID: String) async throws -> ProjectSchemes {
        guard MacProject.validID(projectID) else { throw DownloadIssue.invalidResponse }
        let file = try await PinnedDownload(settings: DownloadSettingsVault.load(), limit: 64 * 1024)
            .fetch(path: "/projects/\(projectID)/schemes", requestTimeout: 75)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try JSONDecoder().decode(ProjectSchemes.self, from: Data(contentsOf: file))
        try result.validate(for: projectID)
        return result
    }
}

/// Display paths are private UI metadata. Cache locally, protected and excluded from backup.
public struct ProjectCache: Codable, Sendable {
    public var projects: [MacProject] = []
    public var selection: ProjectSelection?
    public var refreshed: Date?
    public init() {}
    private static func location() throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return folder.appendingPathComponent("project-selection.json")
    }
    public static func load() -> ProjectCache {
        guard let url = try? location(), let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let cache = try? JSONDecoder().decode(Self.self, from: data),
              (try? ProjectList(projects: cache.projects, limited: false).validate()) != nil else { return Self() }
        if let selection = cache.selection {
            guard (try? selection.validate()) != nil,
                  cache.projects.contains(where: { $0.id == selection.projectID }) else { return Self() }
        }
        return cache
    }
    public func save() {
        do {
            var url = try Self.location()
            let data = try JSONEncoder().encode(self)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch { /* A cache failure never authorizes a different build. */ }
    }
}
