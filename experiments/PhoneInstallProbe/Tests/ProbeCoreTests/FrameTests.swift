import XCTest
@testable import ProbeCore

final class FrameTests: XCTestCase {
    func testBigEndianFramingRoundTrip() throws {
        let frame = try FrameCodec.encode(["Request": "QueryType"])
        XCTAssertEqual(FrameCodec.length(Data(frame.prefix(4))), frame.count - 4)
        let value = try PropertyListSerialization.propertyList(from: Data(frame.dropFirst(4)), format: nil)
        XCTAssertEqual((value as? [String: String])?["Request"], "QueryType")
    }

    func testRejectsInvalidOrExcessiveLengths() {
        for bytes: [UInt8] in [[], [0, 0, 0], [0, 0, 0, 0], [0, 1, 0, 1], [255, 255, 255, 255]] {
            XCTAssertNil(FrameCodec.length(Data(bytes)))
        }
        XCTAssertEqual(FrameCodec.length(Data([0, 1, 0, 0])), 65536)
    }

    func testErrorReplyIsNotSuccess() throws {
        let error = try PropertyListSerialization.data(fromPropertyList: ["Error": "InvalidHostID"], format: .xml, options: 0)
        XCTAssertFalse(FrameCodec.isLockdownReply(error))
        XCTAssertFalse(FrameCodec.isLockdownReply(Data("not a plist".utf8)))
        let reply = try PropertyListSerialization.data(fromPropertyList: ["Type": "com.apple.mobile.lockdown"], format: .binary, options: 0)
        XCTAssertTrue(FrameCodec.isLockdownReply(reply))
    }

    func testRejectsPublicAndMalformedEndpoints() {
        for host in ["example.com", "1.1.1.1", "10.7.0.1/32", "10.999.0.1", "", "::1"] {
            XCTAssertFalse(DeviceProbe.isLocalAddress(host))
        }
        XCTAssertTrue(DeviceProbe.isLocalAddress("10.7.0.1"))
        XCTAssertTrue(DeviceProbe.isLocalAddress("127.0.0.1"))
    }
}
