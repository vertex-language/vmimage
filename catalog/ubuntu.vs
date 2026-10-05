package catalog

import "vmimage/source"

/// cloud-images.ubuntu.com: `ubuntu-<ver>-server-cloudimg-<arch>.img`
/// under releases/<ver>/release/ with SHA256SUMS beside it; `minimal`
/// is the smaller image under minimal/releases/<codename>/release/.
public struct Ubuntu: Vendor {
    public init() {}

    public var Name: string { "ubuntu" }
    public var Releases: [string] { [] }

    public func Locate(release: string, variant: string, arch: string) async throws -> Located {
        guard ["", "minimal"].contains(variant) else {
            throw CatalogError.unknownVariant(distro: "ubuntu", variant: variant, known: ["minimal"])
        }
        let a = try spell(arch, ["arm64": "arm64", "amd64": "amd64"], distro: "ubuntu")
        var n = release
        if release == "latest" {
            // The newest numbered directory of releases/.
            let listing = links(try await source.Text("https://cloud-images.ubuntu.com/releases/"))
            let versions = listing.map { string($0.trimmingSuffix("/")) }.filter { isVersion($0) }
            guard let newest = versions.sorted().last else {
                throw CatalogError.unknownRelease(distro: "ubuntu", release: release, known: [])
            }
            n = newest
        }
        guard isVersion(n) else {
            throw CatalogError.unknownRelease(distro: "ubuntu", release: release, known: ["22.04", "24.04", "latest"])
        }
        var base = "https://cloud-images.ubuntu.com/releases/\(n)/release/"
        var file = "ubuntu-\(n)-server-cloudimg-\(a).img"
        if variant == "minimal" {
            // releases/24.04/ redirects to releases/noble/: the code name
            // the minimal images are filed under.
            let final = try await source.Final(base + "SHA256SUMS")
            let parts = final.split(separator: "/").map { string($0) }
            guard let at = parts.firstIndex(of: "releases"), at + 1 < parts.count else {
                throw CatalogError.unknownRelease(distro: "ubuntu", release: release, known: [])
            }
            base = "https://cloud-images.ubuntu.com/minimal/releases/\(parts[at + 1])/release/"
            file = "ubuntu-\(n)-minimal-cloudimg-\(a).img"
        }
        return Located(Release: n, Variant: variant, URL: base + file, FileName: file, ChecksumURL: base + "SHA256SUMS")
    }
}

/// "24.04": two digits, a dot, two digits.
func isVersion(_ s: string) -> bool {
    let p = s.split(separator: ".").map { string($0) }
    guard p.count == 2, p[0].count == 2, p[1].count == 2 else { return false }
    for part in p { for c in part where !c.isNumber { return false } }
    return true
}

extension String {
    func trimmingSuffix(_ s: string) -> string {
        hasSuffix(s) ? string(self.dropLast(s.count)) : self
    }
}
