import Crypto

/// Tokens are stored as SHA-256 hex of the secret. A slow password hash isn't needed: tokens are long
/// random strings, not something a person picked.
public enum TokenHash {
    public static func of(_ secret: String) -> String {
        SHA256.hash(data: Array(secret.utf8)).hexString
    }
}

/// `wf_admin_…` or `wf_eval_…` followed by 43 random base62 characters (about 256 bits). The prefix makes
/// a leaked token easy to recognize, and lets secret scanners match it.
enum TokenSecret {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func make(for kind: Token.Kind) -> String {
        let prefix = switch kind {
        case .admin: "wf_admin_"
        case .evaluation: "wf_eval_"
        }
        // SystemRandomNumberGenerator is cryptographically secure on every platform Swift supports.
        var generator = SystemRandomNumberGenerator()
        return prefix + String((0..<43).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

extension Sequence<UInt8> {
    public var hexString: String {
        map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }
}
