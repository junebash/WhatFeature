import Crypto

/// Tokens are stored as SHA-256 hex of the secret. A slow password hash isn't needed: tokens are long
/// random strings, not something a person picked.
public enum TokenHash {
    public static func of(_ secret: String) -> String {
        SHA256.hash(data: Array(secret.utf8)).hexString
    }
}

extension Sequence<UInt8> {
    var hexString: String {
        map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }
}
