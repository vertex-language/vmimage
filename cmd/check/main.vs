// vmimage's checks, offline: names, checksum files, hashing.
//
//     vsc run ./cmd/check
package main

import (
    "archive/zip"
    "compress/gzip"
    "compress/zstd"
    "crypto/sha256"
    "io"
    "fs"
    "vmimage/catalog"
    "vmimage/convert"
    "vmimage/ref"
    "vmimage/source"
    "vm/disk/qcow2"
)

var failures: int32 = 0

func check(_ ok: bool, _ what: string) {
    if ok {
        print("ok    \(what)")
    } else {
        print("FAIL  \(what)")
        failures += 1
    }
}

func testReference() {
    func name(_ s: string) -> string { (try? ref.Reference.Parse(s))?.description ?? "error" }
    check(name("debian") == "debian:latest", "a bare name is latest")
    check(name("debian:12") == "debian:12", "a release")
    check(name("ubuntu:24.04-minimal") == "ubuntu:24.04-minimal", "a variant")
    if let r = try? ref.Reference.Parse("debian:12-generic") {
        check(r.Distro == "debian" && r.Release == "12" && r.Variant == "generic", "distro, release and variant apart")
    } else {
        check(false, "distro, release and variant apart")
    }
    let h = String(repeating: "a", count: 128)
    check(name("debian:12@sha512:" + h) == "debian:12@sha512:" + h, "a digest")
    check(name("Debian") == "error", "upper case is refused")
    check(name("debian:") == "error", "an empty release is refused")
    check(name("debian:-minimal") == "error", "a release can't be empty before a variant")
    check(name("debian:12@md5:abc") == "error", "another algorithm is refused")
    check(name("a/b") == "error", "a path is refused")
}

func testChecksums() {
    let gnu = """
    # a comment
    \(String(repeating: "a", count: 64))  debian-12.qcow2
    \(String(repeating: "b", count: 128)) *ubuntu.img
    """
    let m = source.ParseChecksums(gnu)
    check(m["debian-12.qcow2"]?.1 == String(repeating: "a", count: 64) && m["debian-12.qcow2"]?.0 == source.Algorithm.sha256, "GNU line, sha256")
    check(m["ubuntu.img"]?.0 == source.Algorithm.sha512, "GNU line, a * before the name, sha512")
    let bsd = "SHA256 (Alma.qcow2) = \(String(repeating: "c", count: 64))\nSHA512 (x.xz) = \(String(repeating: "d", count: 128))\n"
    let b = source.ParseChecksums(bsd)
    check(b["Alma.qcow2"]?.1 == String(repeating: "c", count: 64) && b["x.xz"]?.0 == source.Algorithm.sha512, "BSD lines")
    check(source.ParseChecksums("not a checksum line\n").isEmpty, "junk is ignored")
}

func testHash() {
    var h = source.Digester(source.Algorithm.sha256)
    h.Write([uint8]("abc".utf8))
    check(h.Digest() == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
    var g = source.Digester(source.Algorithm.sha512)
    g.Write([uint8]("abc".utf8))
    check(g.Hex().hasPrefix("ddaf35a193617aba"), "sha512 of abc")
    var s = source.Digester(source.Algorithm.sha1)
    s.Write([uint8]("abc".utf8))
    check(s.Digest() == "sha1:a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 of abc")
    check(source.Algorithm.OfHex(String(repeating: "a", count: 40)) == source.Algorithm.sha1, "a 40-digit digest is sha1")
}

/// An excerpt of dl.google.com's sys-img2-3.xml, as Google writes it.
func testAndroidIndex() {
    let index = """
    <?xml version='1.0' encoding='utf-8'?>
    <sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <remotePackage path="system-images;android-36;default;arm64-v8a">
        <type-details xsi:type="sys-img:sysImgDetailsType"><api-level>36</api-level><tag><id>default</id></tag><abi>arm64-v8a</abi></type-details>
        <revision><major>2</major></revision>
        <archives><archive><complete>
          <size>810736863</size>
          <checksum type="sha1">62ad6714df790f89c8a8ad32552ffe20bb16fe87</checksum>
          <url>arm64-v8a-36_r02.zip</url>
        </complete></archive></archives>
      </remotePackage>
      <remotePackage path="system-images;android-36;default;x86_64">
        <archives><archive><complete><size>1</size><checksum type="sha1">00</checksum><url>x86_64-36_r02.zip</url></complete></archive></archives>
      </remotePackage>
      <remotePackage path="system-images;android-24;default;arm64-v8a" obsolete="true">
        <obsolete/>
        <archives><archive><complete><size>1</size><checksum type="sha1">00</checksum><url>old.zip</url></complete></archive></archives>
      </remotePackage>
    </sys-img:sdk-sys-img>
    """
    let p = catalog.Android.Parse(index, tag: "default", abi: "arm64-v8a")
    check(p.count == 1, "the index lists one current arm64 default image (x86_64 and obsolete left out)")
    if let a = p.first {
        check(a.API == "36" && a.File == "arm64-v8a-36_r02.zip" && a.Size == 810736863, "its API level, file and size")
        check(a.Algorithm == "sha1" && a.Hex == "62ad6714df790f89c8a8ad32552ffe20bb16fe87", "its SHA-1")
    }
}

/// A 24 MiB disk, mostly holes with three runs of data, made here and
/// shipped each way a vendor ships one (qcow2 plain and deflated, gzip'd,
/// zstd'd): each must convert back to the same raw bytes.
func fixtureRaw() -> [uint8] {
    var raw = [uint8](repeating: 0, count: 24 << 20)
    for (mib, count, v) in [(0, 1, uint8(0x41)), (5, 2, uint8(0x42)), (17, 1, uint8(0x43))] {
        for i in (mib << 20)..<((mib + count) << 20) { raw[i] = v }
    }
    // Something that isn't a run, so deflate and zstd have work to do.
    for i in 0..<4096 { raw[(9 << 20) + i] = uint8(truncatingIfNeeded: i * 31 + i / 7) }
    return raw
}

func sha(_ b: [uint8]) -> string { sha256.ToHex(sha256.Sum256(b)) }

/// Writes the fixtures into `dir`; false (and why) where one couldn't be made.
func makeFixtures(_ dir: fs.Path, _ raw: [uint8]) async -> bool {
    do {
        let cs = 65536
        for compressed in [false, true] {
            let img = try qcow2.Create(dir / (compressed ? "disk.compressed.qcow2" : "disk.plain.qcow2"), size: uint64(raw.count))
            var at = 0
            while at < raw.count {
                let cluster = Array(raw[at..<at + cs])
                if cluster.contains(where: { $0 != 0 }) {
                    if compressed { try img.WriteCompressed(uint64(at), cluster) } else { try await img.WriteAt(uint64(at), cluster) }
                }
                at += cs
            }
            try await img.Flush()
            img.Close()
        }
        try fs.WriteFile(dir / "disk.qcow2.gz", gzip.Compress(try fs.ReadFile(dir / "disk.plain.qcow2")))
        try fs.WriteFile(dir / "disk.raw.zst", zstd.Compress(raw))
        // A vmdk's magic and nothing after it: enough to be recognized and refused.
        try fs.WriteFile(dir / "disk.vmdk", [0x4B, 0x44, 0x4D, 0x56] + [uint8](repeating: 0, count: 508))
        return true
    } catch {
        check(false, "the conversion fixtures are made (\(error))")
        return false
    }
}

func testConvert(_ tmp: fs.Path) async {
    let raw = fixtureRaw()
    let want = sha(raw)
    if !(await makeFixtures(tmp, raw)) { return }
    let names = ["disk.plain.qcow2", "disk.compressed.qcow2", "disk.qcow2.gz", "disk.raw.zst"]
    let sources = ["qcow2", "qcow2", "qcow2", "raw"]
    for k in 0..<names.count {
        let name = names[k]
        let source = sources[k]
        let out = tmp / (name + ".raw")
        do {
            let c = try convert.ToRaw(tmp / name, to: out)
            check(sha((try? fs.ReadFile(out)) ?? []) == want && c.VirtualSize == uint64(raw.count), "\(name) converts to the original raw disk")
            check(c.Source.description == source && c.Written < c.VirtualSize, "\(name) is \(source) and comes out sparse (\(c.Written) of \(c.VirtualSize) bytes written)")
            let blocks = (try? fs.Stat(out).Size) ?? 0
            check(blocks == int64(raw.count), "\(name) output is the full size")
        } catch {
            check(false, "\(name) threw \(error)")
        }
    }
    do {
        _ = try convert.ToRaw(tmp / "disk.vmdk", to: tmp / "x.raw")
        check(false, "a vmdk is refused")
    } catch {
        check(true, "a vmdk is refused, not mangled")
    }
    check((try? convert.Detect(tmp / "disk.compressed.qcow2")) == convert.Format.qcow2, "qcow2 is detected by its magic")
}

/// A miniature of Google's emulator zip: unpacked without its <abi>/
/// prefix or NOTICE, with the disks written sparsely.
func testUnpackAndroid(_ tmp: fs.Path) {
    do {
        var disk = [uint8](repeating: 0, count: 3 << 20)
        for i in 0..<4096 { disk[(1 << 20) + i] = uint8(i % 251) }
        var w = zip.Writer(io.Cursor())
        try w.Add(name: "arm64-v8a/NOTICE.txt", data: [uint8]("licenses".utf8), method: .deflate)
        try w.Add(name: "arm64-v8a/kernel-ranchu", data: [uint8]("ARM64 kernel".utf8), method: .deflate)
        try w.Add(name: "arm64-v8a/ramdisk.img", data: [0x1F, 0x8B, 1, 2], method: .store)
        try w.Add(name: "arm64-v8a/system.img", data: disk, method: .deflate)
        try w.Add(name: "arm64-v8a/vendor.img", data: disk, method: .deflate)
        try w.Add(name: "arm64-v8a/data/local.prop", data: [uint8]("x=1".utf8), method: .deflate)
        try w.Close()
        let z = tmp / "android.zip"
        try fs.WriteFile(z, w.Inner.Bytes)
        let b = try convert.UnpackAndroid(z, to: tmp / "android")
        check(b.ABI == "arm64-v8a" && b.Files.count == 5 && !b.Files.contains("NOTICE.txt"), "an Android zip unpacks without its abi prefix or NOTICE (\(b.Files))")
        check(b.DiskSize == 6 << 20 && b.Written < 1 << 18, "its disks come out sparse (\(b.Written) of \(b.DiskSize) bytes written)")
        check((try? fs.ReadFile(tmp / "android/system.img")) == disk, "system.img is the original bytes")
        check((try? fs.ReadText(tmp / "android/data/local.prop")) == "x=1", "a nested file lands in its directory")

        var w2 = zip.Writer(io.Cursor())
        try w2.Add(name: "x86_64/kernel-ranchu", data: [1], method: .store)
        try w2.Close()
        try fs.WriteFile(tmp / "partial.zip", w2.Inner.Bytes)
        do {
            _ = try convert.UnpackAndroid(tmp / "partial.zip", to: tmp / "partial")
            check(false, "a zip missing system.img is refused")
        } catch {
            check(true, "a zip missing system.img is refused")
        }
    } catch {
        check(false, "unpacking an Android zip threw \(error)")
    }
}

public func main() async -> int32 {
    let tmp = (try? fs.TempDir(prefix: "vmimage-check-")) ?? fs.Path("/tmp/vmimage-check")
    testReference()
    testChecksums()
    testHash()
    testAndroidIndex()
    await testConvert(tmp)
    testUnpackAndroid(tmp)
    try? fs.RemoveAll(tmp)
    print(failures == 0 ? "ALL VMIMAGE CHECKS PASSED" : "\(failures) FAILED")
    return failures
}
