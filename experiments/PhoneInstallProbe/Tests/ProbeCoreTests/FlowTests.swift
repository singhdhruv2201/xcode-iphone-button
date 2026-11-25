import XCTest
@testable import ProbeCore

final class FlowTests: XCTestCase {
    func testCallbackMustMatchJobPhaseAndNonceAndIsConsumed() throws {
        var flow = BuildFlowState()
        let helper = URLComponents(url: flow.shortcutURL(name: "Connect"), resolvingAgainstBaseURL: false)!
        let callback = URL(string: helper.queryItems!.first { $0.name == "x-success" }!.value!)!
        XCTAssertTrue(flow.accepts(callback))
        XCTAssertFalse(BuildFlowState().accepts(callback))
        flow.handoff(.prepare)
        XCTAssertFalse(flow.accepts(callback))
        flow.phase = .installing
        XCTAssertFalse(flow.accepts(callback))
    }
    func testExpiredAndDuplicateCallbacksAreRejected() throws {
        var flow = BuildFlowState()
        let helper = URLComponents(url: flow.shortcutURL(name: "Connect"), resolvingAgainstBaseURL: false)!
        let callback = URL(string: helper.queryItems!.first { $0.name == "x-success" }!.value!)!
        XCTAssertFalse(flow.accepts(URL(string: callback.absoluteString + "&phase=connect")!))
        flow.started = .distantPast
        XCTAssertFalse(flow.accepts(callback))
    }
    func testMasterRunBindsTokenPhaseSelectionAndExpiry() throws {
        var flow = BuildFlowState()
        flow.purpose = "master"
        flow.phase = .master
        let project = MacProject(id: String(repeating: "a", count: 64), name: "Sample", displayPath: "Code/Sample.xcodeproj", kind: "project")
        flow.selection = project.selection(scheme: "Sample")
        let token = flow.masterToken
        XCTAssertTrue(flow.acceptsMasterRun(token, phases: [.master]))
        XCTAssertFalse(flow.acceptsMasterRun("wrong", phases: [.master]))
        XCTAssertFalse(flow.acceptsMasterRun(token, phases: [.installReady]))
        XCTAssertFalse(flow.acceptsMasterRun(token, phases: [.master], now: flow.started.addingTimeInterval(3601)))
        let shortcut = URLComponents(url: flow.shortcutURL(name: "Master", input: token), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(shortcut.queryItems?.first(where: { $0.name == "text" })?.value, token)
        let callback = URL(string: shortcut.queryItems!.first(where: { $0.name == "x-success" })!.value!)!
        flow.phase = .installing
        XCTAssertTrue(flow.acceptsMasterCallback(callback))
        XCTAssertFalse(flow.acceptsMasterRun(token, phases: [.installReady]))
        flow.nonce = UUID()
        XCTAssertFalse(flow.acceptsMasterCallback(callback))
        XCTAssertFalse(flow.acceptsMasterRun(token, phases: [.installing]))
    }

}
