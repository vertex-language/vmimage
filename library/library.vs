// Package library keeps pulled images on disk:
//
//     <root>/index.json              what each name means
//     <root>/images/<alg>-<hex>.raw  the images, as sparse raw files, by the digest the vendor published
//     <root>/images/<alg>-<hex>/     a bundle: an image that is more than one disk (Android: kernel, ramdisk, system.img, …)
//     <root>/downloads/              vendor files on their way in (and partial ones, to resume)
//
// An image is named by the digest of the file the vendor published, so a
// vendor's checksum list says whether the store already has what it
// offers, and `name@sha512:…` means exactly those bytes.
package library

import (
    "encoding/json"
    "fs"
    "os/env"
    "os/user"
)

public enum StoreError: Error, CustomStringConvertible {
    case notFound(string)
    case corrupt(string)

    public var description: string {
        switch self {
        case .notFound(let n): return "no image called \(n) (try `vmimage --pull \(n)`)"
        case .corrupt(let s): return "the image index is corrupt: \(s)"
        }
    }
}

/// What the store knows about an image.
public struct Record: Equatable {
    /// "debian:12", "ubuntu:24.04-minimal".
    public var Name: string
    /// "arm64" or "amd64".
    public var Arch: string
    /// "sha512:…": the vendor file's digest, which names the image here.
    public var Digest: string
    /// Where it came from.
    public var URL: string
    /// What the vendor shipped: "qcow2", "raw", ….
    public var Format: string
    /// What a guest sees, in bytes.
    public var VirtualSize: int64
    /// "disk" (one raw file) or "android-emulator" (a directory: see BundlePath).
    public var Kind: string
    /// "linux", "bsd", "android".
    public var Guest: string
    /// How it boots: "efi", or "ranchu" (Android's emulator board, by direct kernel boot).
    public var Boot: string
    /// Whether Secure Boot firmware boots it.
    public var SecureBoot: bool
    /// Whether it wants a cloud-init seed to log in.
    public var Seed: bool
    /// When it was pulled, Unix seconds.
    public var Pulled: int64

    public init(name: string, arch: string, digest: string, url: string, format: string, virtualSize: int64,
                guest: string = "linux", boot: string = "efi", secureBoot: bool = true, seed: bool = true,
                pulled: int64 = 0, kind: string = "disk") {
        Kind = kind
        Name = name
        Arch = arch
        Digest = digest
        URL = url
        Format = format
        VirtualSize = virtualSize
        Guest = guest
        Boot = boot
        SecureBoot = secureBoot
        Seed = seed
        Pulled = pulled
    }

    func toJson() -> json.Value {
        var o = json.Object()
        o["name"] = .string(Name)
        o["arch"] = .string(Arch)
        o["digest"] = .string(Digest)
        o["url"] = .string(URL)
        o["format"] = .string(Format)
        o["virtualSize"] = .number("\(VirtualSize)")
        o["kind"] = .string(Kind)
        o["guest"] = .string(Guest)
        o["boot"] = .string(Boot)
        o["secureBoot"] = .bool(SecureBoot)
        o["seed"] = .bool(Seed)
        o["pulled"] = .number("\(Pulled)")
        return .object(o)
    }

    static func fromJson(_ v: json.Value) throws -> Record {
        guard let name = v["name"]?.String, let arch = v["arch"]?.String, let d = v["digest"]?.String else {
            throw StoreError.corrupt("a record needs a name, arch and digest")
        }
        return Record(name: name, arch: arch, digest: d, url: v["url"]?.String ?? "",
                      format: v["format"]?.String ?? "", virtualSize: v["virtualSize"]?.Int ?? 0,
                      guest: v["guest"]?.String ?? "linux", boot: v["boot"]?.String ?? "efi",
                      secureBoot: v["secureBoot"]?.Bool ?? true, seed: v["seed"]?.Bool ?? true,
                      pulled: v["pulled"]?.Int ?? 0, kind: v["kind"]?.String ?? "disk")
    }
}

/// Where images are kept unless a root is given: $VERTEX_VMIMAGE_ROOT,
/// else "vertex/vmimage" under the user's data directory.
public func DefaultRoot() -> string {
    if let r = env.Get("VERTEX_VMIMAGE_ROOT"), !r.isEmpty {
        return r
    }
    let base = user.DataDir() ?? (user.Home() ?? ".")
    return base + "/vertex/vmimage"
}

public final class Store {
    public let Root: fs.Path
    var records: [Record] = []

    public init(root: string? = nil) throws {
        Root = fs.Path(root ?? DefaultRoot())
        try fs.CreateDir(Root / "images", all: true)
        try fs.CreateDir(Root / "downloads", all: true)
        let index = Root / "index.json"
        if fs.Exists(index) {
            let v = try json.Parse(bytes: try fs.ReadFile(index))
            for r in v["images"]?.Array ?? [] {
                records.append(try Record.fromJson(r))
            }
        }
    }

    func save() throws {
        var o = json.Object()
        o["images"] = .array(records.map { $0.toJson() })
        try fs.WriteFile(Root / "index.json", [uint8](json.Encode(.object(o), indent: "  ").utf8), atomic: true)
    }

    /// "sha512:ab12…" as a file name in images/.
    public func ImagePath(_ digest: string) -> fs.Path {
        Root / "images" / (digest.replacingColon() + ".raw")
    }

    /// A bundle's directory: "sha1:ab12…" as images/sha1-ab12…/.
    public func BundlePath(_ digest: string) -> fs.Path {
        Root / "images" / digest.replacingColon()
    }

    /// What a record names on disk: its raw file, or its bundle's directory.
    public func PathOf(_ r: Record) -> fs.Path {
        r.Kind == "disk" ? ImagePath(r.Digest) : BundlePath(r.Digest)
    }

    /// Where a vendor file is kept while it downloads and converts.
    public func DownloadPath(_ digest: string) -> fs.Path {
        Root / "downloads" / digest.replacingColon()
    }

    public func Has(_ digest: string) -> bool {
        fs.Exists(ImagePath(digest)) || fs.Exists(BundlePath(digest))
    }

    public var Records: [Record] { records }

    /// The image `name` for `arch`.
    public func Find(_ name: string, arch: string) -> Record? {
        for r in records where r.Name == name && r.Arch == arch { return r }
        return nil
    }

    /// An image by the digest the vendor published (a prefix of at least
    /// 8 hex digits after the algorithm works too).
    public func Find(digest: string) -> Record? {
        for r in records where r.Digest == digest || (digest.count >= 8 && r.Digest.hasPrefix(digest)) { return r }
        return nil
    }

    /// Names an image, replacing what the name meant for its arch before.
    public func Add(_ r: Record) throws {
        records = records.filter { !($0.Name == r.Name && $0.Arch == r.Arch) }
        records.append(r)
        try save()
    }

    /// Forgets a name; the file stays until Prune.
    public func Remove(_ name: string, arch: string) throws {
        let before = records.count
        records = records.filter { !($0.Name == name && $0.Arch == arch) }
        if records.count == before { throw StoreError.notFound(name) }
        try save()
    }

    /// Deletes every image no name reaches, and leftovers in downloads.
    /// Returns the bytes freed.
    @discardableResult
    public func Prune() throws -> int64 {
        var keep = Set<string>()
        for r in records { keep.insert(PathOf(r).Value) }
        var freed: int64 = 0
        for e in try fs.ReadDir(Root / "images") where !keep.contains(e.Path.Value) {
            freed += size(e.Path)
            try fs.RemoveAll(e.Path)
        }
        for e in try fs.ReadDir(Root / "downloads") {
            freed += size(e.Path)
            try fs.RemoveAll(e.Path)
        }
        return freed
    }
}

/// A file's size, or everything in a directory.
func size(_ p: fs.Path) -> int64 {
    guard let m = try? fs.Stat(p) else { return 0 }
    if !m.IsDir() { return m.Size }
    var n: int64 = 0
    for e in (try? fs.ReadDir(p)) ?? [] { n += size(e.Path) }
    return n
}

extension String {
    func replacingColon() -> string {
        string(self.map { $0 == ":" ? Character("-") : $0 })
    }
}
