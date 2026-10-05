package source

import (
    "crypto/sha1"
    "crypto/sha256"
    "crypto/sha512"
)

/// A hash vendors publish: SHA-256 or SHA-512, or SHA-1 where that is all
/// the vendor gives (Google's Android SDK repository).
public enum Algorithm: Equatable {
    case sha1
    case sha256
    case sha512

    public var Name: string {
        switch self {
        case .sha1: return "sha1"
        case .sha256: return "sha256"
        case .sha512: return "sha512"
        }
    }

    /// The algorithm for a name ("sha256"), or for a hex digest's length.
    public static func Named(_ n: string) -> Algorithm? {
        switch n.lowercased() {
        case "sha1": return .sha1
        case "sha256": return .sha256
        case "sha512": return .sha512
        default: return nil
        }
    }

    public static func OfHex(_ hex: string) -> Algorithm? {
        switch hex.count {
        case 40: return .sha1
        case 64: return .sha256
        case 128: return .sha512
        default: return nil
        }
    }
}

/// A running hash of either kind.
public struct Digester {
    public let Algorithm: Algorithm
    var s1 = sha1.New()
    var s256 = sha256.New()
    var s512 = sha512.New()

    public init(_ a: Algorithm) {
        Algorithm = a
    }

    public mutating func Write(_ bytes: [uint8]) {
        switch Algorithm {
        case .sha1: s1.Write(bytes)
        case .sha256: s256.Write(bytes)
        case .sha512: s512.Write(bytes)
        }
    }

    /// The digest of what has been written, as lower-case hex.
    public func Hex() -> string {
        switch Algorithm {
        case .sha1: return sha1.ToHex(s1.Checksum())
        case .sha256: return sha256.ToHex(s256.Checksum())
        case .sha512: return sha512.ToHex(s512.Checksum())
        }
    }

    /// "sha256:<hex>".
    public func Digest() -> string { Algorithm.Name + ":" + Hex() }
}
