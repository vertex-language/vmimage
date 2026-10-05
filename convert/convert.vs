// Package convert turns what a vendor ships into the one thing vmimage
// keeps: a sparse raw disk image. A qcow2 or VHDX is read through vm/disk
// and written without its zero runs; a .gz or .zst is unpacked first.
// (.xz needs a decoder compress doesn't have yet.)
package convert

import (
    "compress/gzip"
    "compress/zstd"
    "fs"
    "vm/disk/qcow2"
)

public enum ConvertError: Error, CustomStringConvertible {
    case unsupported(string)
    case corrupt(string)

    public var description: string {
        switch self {
        case .unsupported(let s): return "can't convert: \(s)"
        case .corrupt(let s): return "image is corrupt: \(s)"
        }
    }
}

/// What a file is, by its first bytes.
public enum Format: Equatable, CustomStringConvertible {
    case raw
    case qcow2
    case vhdx
    case vmdk
    case gzip
    case zstd
    case xz

    public var description: string {
        switch self {
        case .raw: return "raw"
        case .qcow2: return "qcow2"
        case .vhdx: return "vhdx"
        case .vmdk: return "vmdk"
        case .gzip: return "gzip"
        case .zstd: return "zstd"
        case .xz: return "xz"
        }
    }
}

/// Sniffs the format of the file at `path`. Anything with no magic number
/// is raw.
public func Detect(_ path: fs.Path) throws -> Format {
    let f = try fs.Open(path)
    defer { try? f.Close() }
    var b = [uint8](repeating: 0, count: 8)
    let n = try f.Read(into: &b, at: 0)
    if n >= 4 && b[0] == 0x51 && b[1] == 0x46 && b[2] == 0x49 && b[3] == 0xFB { return .qcow2 }
    if n >= 8 && string(decoding: Array(b[0..<8]), as: UTF8.self) == "vhdxfile" { return .vhdx }
    if n >= 4 && b[0] == 0x4B && b[1] == 0x44 && b[2] == 0x4D && b[3] == 0x56 { return .vmdk }
    if n >= 2 && b[0] == 0x1F && b[1] == 0x8B { return .gzip }
    if n >= 4 && b[0] == 0x28 && b[1] == 0xB5 && b[2] == 0x2F && b[3] == 0xFD { return .zstd }
    if n >= 6 && b[0] == 0xFD && b[1] == 0x37 && b[2] == 0x7A && b[3] == 0x58 && b[4] == 0x5A { return .xz }
    return .raw
}

/// What a conversion did.
public struct Converted {
    /// What the source was (after unpacking).
    public var Source: Format
    /// The disk's size in bytes: what a guest sees.
    public var VirtualSize: uint64
    /// Bytes actually written (the rest are holes).
    public var Written: uint64
}

let chunk = 1 << 20

/// Writes the disk at `source` to `dest` as a sparse raw image, unpacking
/// a compressed file first. `progress` gets bytes done and the total.
public func ToRaw(_ source: fs.Path, to dest: fs.Path,
                  progress: (uint64, uint64) -> Void = { _, _ in }) throws -> Converted {
    var path = source
    var format = try Detect(path)
    var unpacked: fs.Path? = nil
    defer { if let u = unpacked { try? fs.Remove(u) } }
    // A compressed file is unpacked first; what is inside may be a qcow2.
    while format == .gzip || format == .zstd {
        let next = fs.Path(dest.Value + ".unpacked")
        try unpack(path, to: next, format)
        if let u = unpacked, u != next { try? fs.Remove(u) }
        unpacked = next
        path = next
        format = try Detect(path)
    }
    switch format {
    case .xz:
        throw ConvertError.unsupported("xz-compressed images (compress has no xz decoder yet)")
    case .vmdk:
        throw ConvertError.unsupported("vmdk images")
    case .vhdx:
        throw ConvertError.unsupported("vhdx images (vm/disk/vhdx reads asynchronously; not wired here yet)")
    default:
        break
    }
    let file = try fs.Open(path)
    var q: qcow2.Image? = nil
    var size: uint64
    if format == .qcow2 {
        let opened = try qcow2.Open(file, readOnly: true)
        q = opened
        size = opened.Size
    } else {
        size = uint64(try file.Metadata().Size)
    }
    defer {
        if let opened = q { opened.Close() } else { try? file.Close() }
    }
    let out = try fs.Create(dest)
    var written: uint64 = 0
    do {
        try out.SetLength(int64(size))
        var buf = [uint8](repeating: 0, count: chunk)
        var at: uint64 = 0
        while at < size {
            let n = int(min(uint64(chunk), size - at))
            // A qcow2 can say a whole range holds nothing: skip the read.
            if let opened = q, try !holdsData(opened, at, uint64(n)) {
                at += uint64(n)
                progress(at, size)
                continue
            }
            if n != buf.count { buf = [uint8](repeating: 0, count: n) }
            if let opened = q {
                try opened.ReadSync(at, into: &buf)
            } else {
                let got = try file.Read(into: &buf, at: int64(at))
                if got < n {
                    for i in got..<n { buf[i] = 0 }
                }
            }
            if !allZero(buf) {
                try out.Write(buf, at: int64(at))
                written += uint64(n)
            }
            at += uint64(n)
            progress(at, size)
        }
        try out.Close()
    } catch {
        try? out.Close()
        try? fs.Remove(dest)
        throw error
    }
    return Converted(Source: format, VirtualSize: size, Written: written)
}

/// Whether any cluster of `[at, at + n)` is stored in the qcow2.
func holdsData(_ q: qcow2.Image, _ at: uint64, _ n: uint64) throws -> bool {
    let cs = q.Header.ClusterSize
    var o = at - at % cs
    while o < at + n {
        if try q.IsAllocated(o) { return true }
        o += cs
    }
    return false
}

func allZero(_ b: [uint8]) -> bool {
    for x in b where x != 0 { return false }
    return true
}

/// Streams a .gz or .zst file into `dest`.
func unpack(_ source: fs.Path, to dest: fs.Path, _ format: Format) throws {
    let input = try fs.Open(source)
    defer { try? input.Close() }
    let out = try fs.Create(dest)
    var buf = [uint8](repeating: 0, count: chunk)
    do {
        if format == .gzip {
            var r = gzip.Reader(input)
            while true {
                let n = try r.Read(into: &buf)
                if n == 0 { break }
                try out.Write(n == buf.count ? buf : Array(buf[0..<n]))
            }
        } else {
            var r = zstd.Reader(input)
            while true {
                let n = try r.Read(into: &buf)
                if n == 0 { break }
                try out.Write(n == buf.count ? buf : Array(buf[0..<n]))
            }
        }
        try out.Close()
    } catch {
        try? out.Close()
        try? fs.Remove(dest)
        throw error
    }
}
