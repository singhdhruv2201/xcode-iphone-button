import XCTest
@testable import ProbeCore

final class CatalogTests: XCTestCase {
    let project = MacProject(id: String(repeating: "a", count: 64), name: "Sample", displayPath: "Code/Sample.xcodeproj", kind: "project")
    func testCatalogRejectsDuplicateIDsAndAbsolutePaths() throws {
        try ProjectList(projects: [project], limited: false).validate()
        XCTAssertThrowsError(try ProjectList(projects: [project, project], limited: false).validate())
        XCTAssertThrowsError(try MacProject(id: project.id, name: "Sample", displayPath: "/private/Sample.xcodeproj", kind: "project").validate())
        XCTAssertThrowsError(try ProjectSchemes(projectID: "wrong", schemes: ["Sample"]).validate(for: project.id))
    }
    func testJobCannotBeReusedForDifferentProjectOrScheme() throws {
        let selected = project.selection(scheme: "Sample")
        let job = BuildDownloader.Job(id: UUID().uuidString.lowercased(), status: "building", message: "Building", manifest: nil,
                                      selection: .init(projectID: project.id, scheme: "Sample"))
        try job.validateSelection(selected)
        XCTAssertThrowsError(try job.validateSelection(project.selection(scheme: "Other")))
        let other = MacProject(id: String(repeating: "b", count: 64), name: "Other", displayPath: "Code/Other.xcodeproj", kind: "project")
        XCTAssertThrowsError(try job.validateSelection(other.selection(scheme: "Sample")))
        XCTAssertThrowsError(try job.validateSelection(nil))
        let legacy = BuildDownloader.Job(id: job.id, status: "building", message: "Building", manifest: nil, selection: nil)
        XCTAssertThrowsError(try legacy.validateSelection(selected))
    }
    func testPersistedFlowKeepsOriginalSelection() throws {
        var flow = BuildFlowState()
        flow.selection = project.selection(scheme: "Sample")
        let data = try JSONEncoder().encode(flow)
        let restored = try JSONDecoder().decode(BuildFlowState.self, from: data)
        XCTAssertEqual(restored.selection, flow.selection)
        XCTAssertNil(restored.purpose)
    }
}
