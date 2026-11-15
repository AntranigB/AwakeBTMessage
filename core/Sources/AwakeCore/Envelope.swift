import Foundation
import CryptoKit

/// Body encryption over an opaque BLE link.
///
/// This is a shared-key envelope: ChaChaPoly with a key derived from a
/// passphrase. It is real AEAD, not a placeholder. It is *not* forward-secret
/// and it does not hide routing metadata — the production design is X3DH +
/// Double Ratchet per pair, and this layer is what that replaces.
/// Demo pre-shared key. Both ends derive the same ChaChaPoly key from this.
/// Production replaces this with X3DH + Double Ratchet per pair.
public let kDemoPSK = "awake-demo-channel"

public enum Envelope {

    public static func key(from passphrase: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(passphrase.utf8))
        return SymmetricKey(data: Data(digest))
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    public static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: key)
    }

    public static func sealString(_ s: String, key: SymmetricKey) throws -> String {
        try seal(Data(s.utf8), key: key).base64EncodedString()
    }

    public static func openString(_ b64: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: b64) else {
            throw SealedBoxError.notBase64
        }
        guard let plain = String(data: try open(data, key: key), encoding: .utf8) else {
            throw SealedBoxError.notUTF8
        }
        return plain
    }

    public enum SealedBoxError: Error {
        case notBase64
        case notUTF8
    }
}
