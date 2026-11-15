import Foundation
import CoreBluetooth

// Shared wire format. Compiled into the iOS app, the macOS anchor,
// and exercised directly by the unit tests.

public let kServiceUUID = CBUUID(string: "D3ADBEEF-0001-4A5B-9C8D-0123456789AB")
public let kRXUUID      = CBUUID(string: "D3ADBEEF-0002-4A5B-9C8D-0123456789AB")
public let kTXUUID      = CBUUID(string: "D3ADBEEF-0003-4A5B-9C8D-0123456789AB")

public struct MeshMessage: Codable, Identifiable, Equatable {
    public var mid: String
    public var from: String
    public var to: String
    public var type: String
    public var ts: Double
    public var body: String
    public var hops: [String]?
    public var lat: Double?
    public var lon: Double?
    public var batt: Int?
    public var rssi: Int?

    public var id: String { mid + from }

    enum CodingKeys: String, CodingKey {
        case mid = "id", from, to, type, ts, body, hops, lat, lon, batt, rssi
    }

    public init(from: String,
                to: String = "*",
                type: String = "msg",
                body: String = "",
                hops: [String]? = nil,
                lat: Double? = nil,
                lon: Double? = nil,
                batt: Int? = nil,
                rssi: Int? = nil,
                mid: String? = nil) {
        if let mid {
            self.mid = mid
        } else {
            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            self.mid = String(raw.prefix(4)).uppercased()
        }
        self.from = from
        self.to = to
        self.type = type
        self.ts = Date().timeIntervalSince1970
        self.body = body
        self.hops = hops
        self.lat = lat
        self.lon = lon
        self.batt = batt
        self.rssi = rssi
    }
}

/// Length-prefixed framing: [uint16 big-endian length][payload].
/// Chunk boundaries are meaningless; the receiver reassembles by length.
public enum Wire {

    public static let maxPayload = 4096
    public static let chunkSize = 150

    public static func frame(_ payload: Data) -> Data {
        var out = Data()
        let n = UInt16(payload.count)
        out.append(UInt8((n >> 8) & 0xFF))
        out.append(UInt8(n & 0xFF))
        out.append(payload)
        return out
    }

    public static func chunks(_ frame: Data, size: Int = chunkSize) -> [Data] {
        precondition(size > 0, "chunk size must be positive")
        var parts: [Data] = []
        var i = 0
        while i < frame.count {
            let end = min(i + size, frame.count)
            parts.append(frame.subdata(in: i..<end))
            i = end
        }
        return parts
    }

    /// Drain every complete frame from the head of `buf`.
    /// A corrupt length prefix clears the buffer rather than desyncing forever.
    public static func drain(_ buf: inout [UInt8]) -> [Data] {
        var out: [Data] = []
        while buf.count >= 2 {
            let len = Int(buf[0]) << 8 | Int(buf[1])
            guard len > 0, len <= maxPayload else {
                buf.removeAll()
                return out
            }
            guard buf.count >= len + 2 else { return out }
            out.append(Data(buf[2..<(2 + len)]))
            buf.removeFirst(2 + len)
        }
        return out
    }

    public static func encode(_ m: MeshMessage) throws -> [Data] {
        let payload = try JSONEncoder().encode(m)
        return chunks(frame(payload))
    }

    public static func decode(_ payload: Data) -> MeshMessage? {
        try? JSONDecoder().decode(MeshMessage.self, from: payload)
    }
}
