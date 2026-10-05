// Package catalog knows where each vendor keeps its VM images and how
// they are checked. One implementation of Vendor per distribution:
// adding a distro is adding a file here.
package catalog

import "vmimage/source"

public enum CatalogError: Error, CustomStringConvertible {
    case unknownDistro(string)
    case unknownRelease(distro: string, release: string, known: [string])
    case unknownVariant(distro: string, variant: string, known: [string])
    case noArch(distro: string, arch: string)
    case notListed(file: string, checksums: string)

    public var description: string {
        switch self {
        case .unknownDistro(let d): return "no vendor called \(d) (known: \(All.map { $0.Name }.joined(separator: ", ")))"
        case .unknownRelease(let d, let r, let k): return "\(d) has no release \(r)" + (k.isEmpty ? "" : " (known: \(k.joined(separator: ", ")))")
        case .unknownVariant(let d, let v, let k): return "\(d) has no variant \(v) (known: \(k.joined(separator: ", ")))"
        case .noArch(let d, let a): return "\(d) doesn't publish an image for \(a)"
        case .notListed(let f, let c): return "\(f) isn't in the vendor's checksum list \(c)"
        }
    }
}

/// Where one image is and how to check it.
public struct Located {
    /// The release the name resolved to ("latest" becomes "13").
    public var Release: string
    public var Variant: string
    /// The file to download, and its name in the checksum list.
    public var URL: string
    public var FileName: string
    /// The vendor's checksum list that has FileName's digest.
    public var ChecksumURL: string
    /// The digest itself ("sha1:…"), where the vendor's index carries it
    /// beside the URL instead of in a checksum list; then ChecksumURL is
    /// that index.
    public var Digest: string = ""
    /// The file's size in bytes, where the vendor says.
    public var Size: int64 = 0
    /// What the download is: "disk" (one disk image, perhaps compressed)
    /// or "android-emulator" (a zip of a kernel, a ramdisk and partition
    /// disks; see Android).
    public var Kind: string = "disk"
    /// What vm needs to know to boot it.
    public var Guest: string = "linux"
    public var Boot: string = "efi"
    public var SecureBoot: bool = true
    public var Seed: bool = true
}

public protocol Vendor {
    var Name: string { get }
    /// The releases it publishes, newest last, where it can say.
    var Releases: [string] { get }
    /// The image for `release` ("latest" for the newest), `variant` ("" for
    /// the usual one), and `arch` ("arm64" or "amd64").
    func Locate(release: string, variant: string, arch: string) async throws -> Located
}

public var All: [any Vendor] {
    [Debian(), Ubuntu(), AlmaLinux(), Android()]
}

public func Lookup(_ distro: string) -> (any Vendor)? {
    for v in All where v.Name == distro { return v }
    return nil
}

/// The digest of `file` in the vendor's checksum list at `checksumURL`.
public func Checksum(of file: string, in checksumURL: string) async throws -> (source.Algorithm, string) {
    let list = source.ParseChecksums(try await source.Text(checksumURL))
    guard let entry = list[file] else { throw CatalogError.notListed(file: file, checksums: checksumURL) }
    return entry
}

/// "arm64" as the vendor spells it, from a table of alternatives.
func spell(_ arch: string, _ table: [string: string], distro: string) throws -> string {
    guard let s = table[arch] else { throw CatalogError.noArch(distro: distro, arch: arch) }
    return s
}

/// The names of the links in an HTML directory listing.
func links(_ html: string) -> [string] {
    let b = [uint8](html.utf8)
    let key = [uint8]("href=\"".utf8)
    var out: [string] = []
    var i = 0
    while i + key.count < b.count {
        var match = true
        for k in 0..<key.count where b[i + k] != key[k] {
            match = false
            break
        }
        if !match {
            i += 1
            continue
        }
        i += key.count
        let start = i
        while i < b.count && b[i] != 0x22 { i += 1 }
        out.append(string(decoding: Array(b[start..<i]), as: UTF8.self))
    }
    return out
}
