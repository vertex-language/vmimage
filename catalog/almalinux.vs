package catalog

/// repo.almalinux.org: `AlmaLinux-<N>-GenericCloud-latest.<arch>.qcow2`
/// in almalinux/<N>/cloud/<arch>/images/, with CHECKSUM beside it.
public struct AlmaLinux: Vendor {
    public init() {}

    public var Name: string { "almalinux" }
    public var Releases: [string] { ["8", "9", "10"] }

    public func Locate(release: string, variant: string, arch: string) async throws -> Located {
        let n = release == "latest" ? Releases.last! : release
        guard Releases.contains(n) else {
            throw CatalogError.unknownRelease(distro: "almalinux", release: release, known: Releases)
        }
        guard ["", "ext4"].contains(variant) else {
            throw CatalogError.unknownVariant(distro: "almalinux", variant: variant, known: ["ext4"])
        }
        let a = try spell(arch, ["arm64": "aarch64", "amd64": "x86_64"], distro: "almalinux")
        let base = "https://repo.almalinux.org/almalinux/\(n)/cloud/\(a)/images/"
        let file = "AlmaLinux-\(n)-GenericCloud\(variant.isEmpty ? "" : "-" + variant)-latest.\(a).qcow2"
        return Located(Release: n, Variant: variant, URL: base + file, FileName: file, ChecksumURL: base + "CHECKSUM")
    }
}
