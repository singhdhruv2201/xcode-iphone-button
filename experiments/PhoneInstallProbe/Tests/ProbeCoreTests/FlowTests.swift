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
}
