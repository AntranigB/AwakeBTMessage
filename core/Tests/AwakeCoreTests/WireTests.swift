import XCTest
@testable import AwakeCore

final class WireTests: XCTestCase {

    private func sample(_ body: String = "where are you") -> MeshMessage {
        MeshMessage(from: "ANCH", to: "IPH1", body: body)
    }

    func testFramePrefixIsBigEndianLength() throws {
        let payload = Data("hello".utf8)
        let framed = Wire.frame(payload)
        XCTAssertEqual(framed.count, payload.count + 2)
        XCTAssertEqual(framed[0], 0)
        XCTAssertEqual(Int(framed[1]), payload.count)
        XCTAssertEqual(framed.dropFirst(2), payload)
    }

    func testChunksReassembleToOriginalFrame() {
        let framed = Wire.frame(Data(repeating: 0x41, count: 701))
        var buf: [UInt8] = []
        for chunk in Wire.chunks(framed, size: 150) {
            XCTAssertLessThanOrEqual(chunk.count, 150)
            buf.append(contentsOf: chunk)
        }
        XCTAssertEqual(Data(buf), framed)
    }

    func testDrainHandlesFrameSplitAcrossChunks() throws {
        // 400 bytes of body forces a frame well past one 150-byte BLE write.
        let m = sample(String(repeating: "x", count: 400))
        let parts = try Wire.encode(m)
        XCTAssertGreaterThan(parts.count, 1, "this sample must span multiple chunks")

        var buf: [UInt8] = []
        var recovered: [Data] = []
        for part in parts {
            buf.append(contentsOf: part)
            recovered.append(contentsOf: Wire.drain(&buf))
        }
        XCTAssertEqual(recovered.count, 1)
        let decoded = Wire.decode(recovered[0])
        XCTAssertEqual(decoded, m)
        XCTAssertTrue(buf.isEmpty)
    }

    func testDrainHandlesMultipleFramesInOneChunk() throws {
        let a = sample("one")
        let b = sample("two")
        var buf: [UInt8] = []
        buf.append(contentsOf: Wire.frame(try JSONEncoder().encode(a)))
        buf.append(contentsOf: Wire.frame(try JSONEncoder().encode(b)))

        let frames = Wire.drain(&buf)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(Wire.decode(frames[0])?.body, "one")
        XCTAssertEqual(Wire.decode(frames[1])?.body, "two")
        XCTAssertTrue(buf.isEmpty)
    }

    func testPartialFrameIsRetained() throws {
        let framed = Wire.frame(try JSONEncoder().encode(sample()))
        var buf = Array(framed.prefix(framed.count - 3))

        let none = Wire.drain(&buf)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(buf.count, framed.count - 3, "incomplete frame must stay buffered")

        buf.append(contentsOf: framed.suffix(3))
        XCTAssertEqual(Wire.drain(&buf).count, 1)
    }

    func testOversizedLengthClearsBufferInsteadOfDesyncing() {
        var buf: [UInt8] = [0xFF, 0xFF] + Array(repeating: 0, count: 64)
        let frames = Wire.drain(&buf)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(buf.isEmpty)

        // and the buffer still works afterwards
        buf.append(contentsOf: Wire.frame(Data("ok".utf8)))
        XCTAssertEqual(Wire.drain(&buf).count, 1)
    }

    func testZeroLengthClearsBuffer() {
        var buf: [UInt8] = [0x00, 0x00, 0x41]
        XCTAssertTrue(Wire.drain(&buf).isEmpty)
        XCTAssertTrue(buf.isEmpty)
    }

    func testEncodeDecodeRoundTripPreservesAllFields() throws {
        let m = MeshMessage(from: "IPH1", to: "ANCH", type: "loc",
                            body: "pin", hops: ["IPH1"], lat: 40.7128, lon: -74.0060,
                            batt: 84, rssi: -61)
        var buf: [UInt8] = []
        for part in try Wire.encode(m) { buf.append(contentsOf: part) }
        let decoded = Wire.decode(Wire.drain(&buf)[0])
        XCTAssertEqual(decoded, m)
    }

    func testWireJSONUsesShortIdKey() throws {
        let data = try JSONEncoder().encode(sample())
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["id"], "wire key must be `id`, not `mid`")
        XCTAssertNil(obj?["mid"])
    }

    func testCorruptPayloadDecodesToNil() {
        XCTAssertNil(Wire.decode(Data("not json".utf8)))
    }

    /// 300 randomly-sized chunkings of randomly-sized messages. Reassembly must
    /// be exact every time, whatever the BLE stack decides to do with MTU.
    func testRandomChunkingsAlwaysReassemble() throws {
        for _ in 0..<300 {
            let m = sample(String(repeating: "a", count: Int.random(in: 0...600)))
            let framed = Wire.frame(try JSONEncoder().encode(m))

            var buf: [UInt8] = []
            var frames: [Data] = []
            var i = 0
            while i < framed.count {
                let n = min(Int.random(in: 1...40), framed.count - i)
                buf.append(contentsOf: framed[i..<(i + n)])
                frames.append(contentsOf: Wire.drain(&buf))
                i += n
            }

            XCTAssertEqual(frames.count, 1, "one frame in, one frame out")
            XCTAssertEqual(Wire.decode(frames[0]), m)
            XCTAssertTrue(buf.isEmpty)
        }
    }

    /// The real send path: seal the body, frame it, chunk it, reassemble, open.
    func testSealedEnvelopeSurvivesTheFullWirePath() throws {
        let key = Envelope.key(from: kDemoPSK)
        var m = sample("meet me at the north gate")
        m.body = "e1:" + (try Envelope.sealString(m.body, key: key))

        var buf: [UInt8] = []
        for part in try Wire.encode(m) { buf.append(contentsOf: part) }
        let back = try XCTUnwrap(Wire.decode(Wire.drain(&buf)[0]))

        XCTAssertTrue(back.body.hasPrefix("e1:"))
        XCTAssertEqual(try Envelope.openString(String(back.body.dropFirst(3)), key: key),
                       "meet me at the north gate")
    }
}
