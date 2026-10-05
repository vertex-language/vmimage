package catalog

/// cloud.debian.org: `debian-<N>-<variant>-<arch>.qcow2`, with
/// SHA512SUMS beside it. The variants are `genericcloud` (a small kernel
/// for VMs, the default), `generic` (with hardware drivers) and `nocloud`
/// (no cloud-init: it logs in as root without a password).
public struct Debian: Vendor {
    public init() {}

    public var Name: string { "debian" }
    public var Releases: [string] { ["11", "12", "13"] }

    static let codenames = ["11": "bullseye", "12": "bookworm", "13": "trixie"]

    public func Locate(release: string, variant: string, arch: string) async throws -> Located {
        let n = release == "latest" ? Releases.last! : release
        guard let code = Debian.codenames[n] else {
            throw CatalogError.unknownRelease(distro: "debian", release: release, known: Releases)
        }
        let v = variant.isEmpty ? "genericcloud" : variant
        guard ["genericcloud", "generic", "nocloud"].contains(v) else {
            throw CatalogError.unknownVariant(distro: "debian", variant: variant, known: ["genericcloud", "generic", "nocloud"])
        }
        let a = try spell(arch, ["arm64": "arm64", "amd64": "amd64"], distro: "debian")
        let base = "https://cloud.debian.org/images/cloud/\(code)/latest/"
        let file = "debian-\(n)-\(v)-\(a).qcow2"
        var l = Located(Release: n, Variant: v == "genericcloud" ? "" : v, URL: base + file, FileName: file,
                        ChecksumURL: base + "SHA512SUMS")
        l.Seed = v != "nocloud"
        return l
    }
}
