// Package vmimage pulls bootable VM disk images from the vendors that
// publish them, by a short name, and keeps each as one checked, sparse,
// raw disk file:
//
//     let st = try library.Store()
//     let img = try await vmimage.Pull("debian:12", into: st)
//     try vmimage.Clone(img, in: st, to: "web.raw", size: 20 << 30)
package vmimage

import (
    "fs"
    "fs/ext4"
    "os/host"
    "vmimage/catalog"
    "vmimage/convert"
    "vmimage/ref"
    "vmimage/source"
    "vmimage/library"
)

public enum PullError: Error, CustomStringConvertible {
    case pinned(name: string, pinned: string, now: string)
    case alreadyThere(string)
    case unknownKind(name: string, kind: string)

    public var description: string {
        switch self {
        case .pinned(let n, let p, let now):
            return "\(n) is \(now) at the vendor now, not \(p); the vendor no longer offers the pinned file (pull it by name to take the new one)"
        case .alreadyThere(let p): return "\(p) already exists"
        case .unknownKind(let n, let k): return "\(n) is a \(k), which this vmimage can't keep"
        }
    }
}

/// "arm64" or "amd64": what this machine runs.
public func HostArch() -> string {
    host.Arch == .aarch64 ? "arm64" : "amd64"
}

/// The image `name` as the store has it, or nil.
public func Resolve(_ name: string, in st: library.Store, arch: string? = nil) throws -> library.Record? {
    let parsed = try ref.Reference.Parse(name)
    if !parsed.Digest.isEmpty, let r = st.Find(digest: parsed.Digest) { return r }
    return st.Find(parsed.Name, arch: arch ?? HostArch())
}

/// Fetches `name` for `arch` (the host's by default) and keeps it: the
/// vendor's checksum list says which file it is and what it hashes to,
/// the download is checked against that, and the file is written once as
/// sparse raw. An image the store already has is not fetched again.
/// `limit` stops the download after that many bytes (the partial file is
/// kept, and the next pull resumes): to watch a big image start.
@discardableResult
public func Pull(_ name: string, into st: library.Store, arch: string? = nil, limit: int64? = nil,
                 log: (string) -> Void = { _ in }) async throws -> library.Record {
    let parsed = try ref.Reference.Parse(name)
    guard let vendor = catalog.Lookup(parsed.Distro) else { throw catalog.CatalogError.unknownDistro(parsed.Distro) }
    let a = arch ?? HostArch()
    let loc = try await vendor.Locate(release: parsed.Release, variant: parsed.Variant, arch: a)
    log("\(parsed.Name) for \(a): \(loc.URL)")
    if loc.Kind != "disk" && loc.Kind != "android-emulator" { throw PullError.unknownKind(name: parsed.Name, kind: loc.Kind) }
    var (algo, hex) = (source.Algorithm.sha256, "")
    if let colon = loc.Digest.firstIndex(of: ":"), let a = source.Algorithm.Named(string(loc.Digest[..<colon])) {
        (algo, hex) = (a, string(loc.Digest[loc.Digest.index(after: colon)...]))
    } else {
        (algo, hex) = try await catalog.Checksum(of: loc.FileName, in: loc.ChecksumURL)
    }
    let digest = algo.Name + ":" + hex
    log("the vendor publishes \(digest.prefix(19))… for it")
    if !parsed.Digest.isEmpty && parsed.Digest != digest {
        if let have = st.Find(digest: parsed.Digest) { return have }
        throw PullError.pinned(name: parsed.Name, pinned: parsed.Digest, now: digest)
    }
    let image = st.ImagePath(digest)
    var rec = library.Record(name: parsed.Name, arch: a, digest: digest, url: loc.URL, format: "",
                           virtualSize: 0, guest: loc.Guest, boot: loc.Boot, secureBoot: loc.SecureBoot,
                           seed: loc.Seed, pulled: fs.Timestamp.Now().UnixSeconds, kind: loc.Kind)
    if st.Has(digest) {
        log("already pulled")
        if let old = st.Records.first(where: { $0.Digest == digest }) {
            rec.Format = old.Format
            rec.VirtualSize = old.VirtualSize
        }
        try st.Add(rec)
        return rec
    }

    let download = st.DownloadPath(digest)
    var shown = 0
    // A complete download an earlier pull left (it stopped in conversion).
    var haveDownload = false
    if fs.Exists(download) {
        if try source.HashFile(download, algorithm: algo) == hex {
            log("  the vendor file is already downloaded and checked")
            haveDownload = true
        } else {
            try? fs.Remove(download)
        }
    }
    if !haveDownload { _ = try await source.Download(loc.URL, to: download, algorithm: algo, expected: hex, limit: limit) { done, total in
        let step = total > 0 ? int(done * 10 / total) : int(done >> 26)
        if step != shown || done == total {
            shown = step
            log("  downloading \(mb(done)) of \(mb(total))" + (total > 0 ? " (\(done * 100 / total)%)" : ""))
        }
    }
    log("  verified \(digest.prefix(19))…") }

    if loc.Kind == "android-emulator" {
        let dir = st.BundlePath(digest)
        let tmp = fs.Path(dir.Value + ".unpacking")
        try? fs.RemoveAll(tmp)
        var lastPct: uint64 = 101
        let b = try convert.UnpackAndroid(download, to: tmp) { done, total in
            let pct = total > 0 ? done * 10 / total : 0
            if pct != lastPct {
                lastPct = pct
                log("  unpacking: \(pct * 10)%")
            }
        }
        try fs.Rename(tmp, dir)
        try? fs.Remove(download)
        rec.Format = "zip"
        rec.VirtualSize = int64(b.DiskSize)
        try st.Add(rec)
        log("  \(b.Files.count) files (\(b.ABI)): \(mb(int64(b.DiskSize))) of disks, \(mb(int64(b.Written))) written")
        return rec
    }

    let tmp = fs.Path(image.Value + ".converting")
    var lastPct: uint64 = 101
    let converted = try convert.ToRaw(download, to: tmp) { done, total in
        let pct = total > 0 ? done * 10 / total : 0
        if pct != lastPct {
            lastPct = pct
            log("  converting to raw: \(pct * 10)%")
        }
    }
    try fs.Rename(tmp, image)
    try? fs.Remove(download)
    rec.Format = converted.Source.description
    rec.VirtualSize = int64(converted.VirtualSize)
    try st.Add(rec)
    log("  \(mb(int64(converted.VirtualSize))) disk, \(mb(int64(converted.Written))) written")
    return rec
}

/// What an Android clone's userdata.img is unless a size is given.
public let AndroidUserdataSize: uint64 = 6 << 30

/// A disk of its own over a pulled image, for a VM to boot and change:
/// the image copied (cloned on APFS, so it costs nothing until it is
/// written; sparse elsewhere), and grown to `size` bytes if that is more
/// than the image has. An Android bundle clones to a directory: its files,
/// plus a freshly formatted ext4 `userdata.img` of `size` (6 GiB by
/// default) where the image doesn't bring an ext4 one,
/// and a `cache.img` for releases that mount /cache from a disk.
public func Clone(_ r: library.Record, in st: library.Store, to path: string, size: uint64? = nil) throws {
    let dest = fs.Path(path)
    if fs.Exists(dest) { throw PullError.alreadyThere(path) }
    if r.Kind == "android-emulator" {
        let src = st.BundlePath(r.Digest)
        try fs.Copy(src, dest, fs.CopyOptions(overwrite: false, recursive: true))
        // Android mounts /data as it finds it: the emulator formats it
        // first where the image ships no file system (Android 9's is zeros).
        if !fs.Exists(dest / "userdata.img") || !ext4.IsExt(dest / "userdata.img") {
            try ext4.Format(dest / "userdata.img", size: int64(size ?? AndroidUserdataSize))
        }
        // Android 8.1 and older mount /cache from its own disk and don't
        // format one; a copy of the shipped userdata.img (an ext4) serves.
        if !fs.Exists(dest / "cache.img") && fs.Exists(src / "userdata.img") {
            try fs.Copy(src / "userdata.img", dest / "cache.img")
        }
        return
    }
    try fs.Copy(st.ImagePath(r.Digest), dest)
    if let s = size, s > uint64(r.VirtualSize) {
        let f = try fs.Open(dest, { var o = fs.OpenOptions(); o.Read = true; o.Write = true; return o }())
        try f.SetLength(int64(s))
        try f.Close()
    }
}

func mb(_ n: int64) -> string {
    "\(n / 1_000_000) MB"
}
