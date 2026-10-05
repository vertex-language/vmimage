package convert

import (
    "archive/zip"
    "fs"
)

/// What an Android emulator image unpacked to.
public struct Bundle {
    /// The files, by their names in the bundle ("kernel-ranchu", "system.img", "data/local.prop").
    public var Files: [string]
    /// The ABI directory the zip had them under ("arm64-v8a").
    public var ABI: string
    /// system.img, vendor.img and userdata.img together: what the guest sees as disks.
    public var DiskSize: uint64
    /// Bytes actually written (the rest are holes).
    public var Written: uint64
}

/// The files an emulator image must have to boot. vendor.img comes with
/// Android 8 and later; before that system.img is a bare ext4 and the zip
/// brings an empty userdata.img.
public let AndroidRequired = ["kernel-ranchu", "ramdisk.img", "system.img"]

/// Unpacks the Android emulator system image zip at `source` (Google's
/// `<abi>-<api>_rNN.zip`: everything under one `<abi>/` directory) into
/// the directory `dest`, without the `<abi>/` prefix or the license
/// NOTICE. Every file is written sparsely, so system.img and vendor.img,
/// raw GPT disks, cost only what they hold. The zip is streamed, and each
/// entry's CRC-32 checked. `progress` gets uncompressed bytes done and the total.
public func UnpackAndroid(_ source: fs.Path, to dest: fs.Path,
                          progress: (uint64, uint64) -> Void = { _, _ in }) throws -> Bundle {
    let a = try zip.Archive.Open(source.Value)
    defer { a.Close() }
    var abi = ""
    for f in a.Files where f.Name.hasSuffix("/kernel-ranchu") {
        abi = string(f.Name.dropLast("/kernel-ranchu".count))
    }
    if abi.isEmpty || abi.contains("/") {
        throw ConvertError.corrupt("\(source.Value) is not an Android emulator image (no <abi>/kernel-ranchu)")
    }
    let prefix = abi + "/"
    var total: uint64 = 0
    for f in a.Files where f.Name.hasPrefix(prefix) && !f.IsDir { total += uint64(f.UncompressedSize) }

    try fs.CreateDir(dest, all: true)
    var b = Bundle(Files: [], ABI: abi, DiskSize: 0, Written: 0)
    var done: uint64 = 0
    // 64 KiB pieces: a hole is skipped at that grain.
    var buf = [uint8](repeating: 0, count: 1 << 16)
    for f in a.Files where f.Name.hasPrefix(prefix) && !f.IsDir {
        let name = string(f.Name.dropFirst(prefix.count))
        if name == "NOTICE.txt" || name.contains("..") || name.hasPrefix("/") {
            done += uint64(f.UncompressedSize)
            continue
        }
        let path = dest / name
        if let slash = name.lastIndex(of: "/") {
            try fs.CreateDir(dest / string(name[..<slash]), all: true)
        }
        let out = try fs.Create(path)
        do {
            try out.SetLength(f.UncompressedSize)
            var r = try a.Open(f)
            var at: int64 = 0
            while true {
                let n = try r.Read(into: &buf)
                if n == 0 { break }
                let piece = n == buf.count ? buf : Array(buf[0..<n])
                if !allZero(piece) {
                    try out.Write(piece, at: at)
                    b.Written += uint64(n)
                }
                at += int64(n)
                done += uint64(n)
                progress(done, total)
            }
            try out.Close()
        } catch {
            try? out.Close()
            throw error
        }
        b.Files.append(name)
        if name == "system.img" || name == "vendor.img" || name == "userdata.img" { b.DiskSize += uint64(f.UncompressedSize) }
    }
    for req in AndroidRequired where !b.Files.contains(req) {
        throw ConvertError.corrupt("\(source.Value) has no \(prefix)\(req)")
    }
    return b
}
