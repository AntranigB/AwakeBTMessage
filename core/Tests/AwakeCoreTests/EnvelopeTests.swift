import XCTest
import CryptoKit
@testable import AwakeCore

final class EnvelopeTests: XCTestCase {

    func testRoundTripString() throws {
        let k = Envelope.key(from: "awake-demo-channel")
        let sealed = try Envelope.sealString("meet me at the north gate", key: k)
        XCTAssertNotEqual(sealed, "meet me at the north gate")
        XCTAssertEqual(try Envelope.openString(sealed, key: k),
                       "meet me at the north gate")
    }

    func testCiphertextDiffersEachTime() throws {
        let k = Envelope.key(from: "awake-demo-channel")
        let a = try Envelope.sealString("same text", key: k)
        let b = try Envelope.sealString("same text", key: k)
        XCTAssertNotEqual(a, b, "nonce must be fresh per seal")
    }

    func testWrongKeyFails() throws {
        let sealed = try Envelope.sealString("secret", key: Envelope.key(from: "one"))
        XCTAssertThrowsError(try Envelope.openString(sealed, key: Envelope.key(from: "two")))
    }

    func testTamperedCiphertextFails() throws {
        let k = Envelope.key(from: "awake-demo-channel")
        var raw = try Envelope.seal(Data("payload".utf8), key: k)
        raw[raw.count - 1] ^= 0xFF
        XCTAssertThrowsError(try Envelope.open(raw, key: k))
    }

    func testNotBase64Throws() {
        let k = Envelope.key(from: "x")
        XCTAssertThrowsError(try Envelope.openString("!!!not base64!!!", key: k))
    }

    func testKeyIsStableForSamePassphrase() {
        let a = Envelope.key(from: "abc").withUnsafeBytes { Data($0) }
        let b = Envelope.key(from: "abc").withUnsafeBytes { Data($0) }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }
}
