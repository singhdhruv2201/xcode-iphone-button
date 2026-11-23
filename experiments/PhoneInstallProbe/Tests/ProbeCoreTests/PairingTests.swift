import XCTest
import CryptoKit
@testable import ProbeCore

final class PairingTests: XCTestCase {
    private func fixture() -> [String: Any] {
        let key = Curve25519.Signing.PrivateKey()
        return ["private_key": key.rawRepresentation,
                "public_key": key.publicKey.rawRepresentation,
                "identifier": UUID().uuidString,
                "alt_irk": Data(repeating: 0, count: 16)]
    }
    private func encode(_ p: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
    }
    func testAcceptsMatchingSyntheticKeys() throws {
        XCTAssertNoThrow(try PairingVault.validate(encode(fixture())))
    }
    func testRejectsMismatchedKeys() throws {
        var p = fixture()
        p["public_key"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try PairingVault.validate(encode(p)))
    }
    func testRejectsMissingHostIdentityAndWrongIRKLength() throws {
        var p = fixture()
        p.removeValue(forKey: "identifier")
        XCTAssertThrowsError(try PairingVault.validate(encode(p)))
        p = fixture()
        p["alt_irk"] = Data(repeating: 0, count: 15)
        XCTAssertThrowsError(try PairingVault.validate(encode(p)))
    }
    func testRejectsMalformedAndOversizedRecords() {
        XCTAssertThrowsError(try PairingVault.validate(Data("not a plist".utf8)))
        XCTAssertThrowsError(try PairingVault.validate(Data(repeating: 0, count: 16_385)))
    }
}
