// Package ref parses the names vmimage pulls by, as Docker spells
// image:tag:
//
//     debian               debian:latest
//     debian:12            release 12
//     debian:12-generic    release 12, the "generic" variant
//     ubuntu:24.04-minimal
//     debian:12@sha512:…   exactly the file with that digest
package ref

public enum ReferenceError: Error, CustomStringConvertible {
    case invalid(string)

    public var description: string {
        switch self {
        case .invalid(let s): return "not an image name: \(s) (expected distro[:release[-variant]][@algorithm:digest])"
        }
    }
}

public struct Reference: Equatable, Hashable, CustomStringConvertible {
    /// Lower case: "debian", "ubuntu".
    public let Distro: string
    /// "12", "24.04", or "latest".
    public let Release: string
    /// "" for the distro's usual image.
    public let Variant: string
    /// "sha512:…", or "".
    public let Digest: string

    public init(distro: string, release: string = "latest", variant: string = "", digest: string = "") {
        Distro = distro
        Release = release
        Variant = variant
        Digest = digest
    }

    /// "debian:12", "ubuntu:24.04-minimal": the name without a digest.
    public var Name: string {
        Distro + ":" + Release + (Variant.isEmpty ? "" : "-" + Variant)
    }

    public var description: string {
        Name + (Digest.isEmpty ? "" : "@" + Digest)
    }

    public static func Parse(_ text: string) throws -> Reference {
        if text.isEmpty || text.contains(" ") || text.contains("/") { throw ReferenceError.invalid(text) }
        var rest = text
        var digest = ""
        if let at = rest.firstIndex(of: "@") {
            digest = string(rest[rest.index(after: at)...])
            rest = string(rest[..<at])
            let parts = digest.split(separator: ":").map { string($0) }
            guard parts.count == 2, parts[0] == "sha1" || parts[0] == "sha256" || parts[0] == "sha512", !parts[1].isEmpty else {
                throw ReferenceError.invalid(text)
            }
            for c in parts[1] where !c.isHexDigit { throw ReferenceError.invalid(text) }
        }
        var distro = rest
        var tag = "latest"
        if let colon = rest.firstIndex(of: ":") {
            distro = string(rest[..<colon])
            tag = string(rest[rest.index(after: colon)...])
        }
        if distro.isEmpty || tag.isEmpty || tag.hasPrefix("-") || tag.hasSuffix("-") { throw ReferenceError.invalid(text) }
        for c in distro where !(c.isLetter || c.isNumber || c == "-") || c.isUppercase { throw ReferenceError.invalid(text) }
        // The variant follows the release's first "-".
        var release = tag
        var variant = ""
        if let dash = tag.firstIndex(of: "-") {
            release = string(tag[..<dash])
            variant = string(tag[tag.index(after: dash)...])
        }
        return Reference(distro: distro, release: release, variant: variant, digest: digest)
    }
}
