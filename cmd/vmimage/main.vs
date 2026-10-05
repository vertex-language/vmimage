// vmimage: pull bootable VM disk images from the vendors, by name.
//
//     vmimage --pull debian:12
//     vmimage --clone debian:12 web.raw --size 20G
//     vm-run --disk web.raw ...
package main

import (
    "fs"
    "os/process"
    "vmimage"
    "vmimage/catalog"
    "vmimage/ref"
    "vmimage/source"
    "vmimage/library"
)

func usage() {
    print("""
Usage: vmimage [--root <dir>] [--arch arm64|amd64] <action>

Actions:
  --pull <name>[@digest]            fetch, check and keep an image (debian:12, ubuntu:24.04-minimal)
  --list [distro]                   what the vendors offer
  --locate <name>                   where the vendor keeps it and how it's checked (downloads nothing)
  --images                          what is pulled
  --inspect <name>                  one image's details
  --path <name>                     print the image's file
  --clone <name> <file> [--size N]  a disk of its own to boot (N like 20G; grows it, never shrinks);
                                    an Android image clones to a directory, N sizing its userdata.img
  --rm <name>                       forget a name (the file stays until --prune)
  --prune                           delete images no name reaches, and leftover downloads

Options:
  --limit <MB>                      with --pull: stop after that much of the download (kept to resume)
""")
}

func human(_ n: int64) -> string {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = float64(n)
    var u = 0
    while v >= 1000 && u < units.count - 1 {
        v /= 1000
        u += 1
    }
    if u == 0 { return "\(n) B" }
    let tenths = int((v * 10).rounded())
    return "\(tenths / 10).\(tenths % 10) \(units[u])"
}

func pad(_ s: string, _ n: int) -> string {
    s.count >= n ? s + " " : s + string(repeating: " ", count: n - s.count)
}

/// "20G", "512M", "1024": bytes.
func parseSize(_ s: string) -> uint64? {
    guard let last = s.last else { return nil }
    var mult: uint64 = 1
    var digits = s
    switch last {
    case "k", "K": mult = 1 << 10
    case "m", "M": mult = 1 << 20
    case "g", "G": mult = 1 << 30
    case "t", "T": mult = 1 << 40
    default: break
    }
    if mult != 1 { digits = string(s.dropLast()) }
    guard let n = uint64(digits) else { return nil }
    return n * mult
}

public func main() async -> int32 {
    var args = Array(process.Args.dropFirst())
    var root: string? = nil
    var arch: string? = nil
    var size: uint64? = nil
    var limit: int64? = nil
    var action = ""
    var operands: [string] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        let next: string? = i + 1 < args.count ? args[i + 1] : nil
        switch a {
        case "--root": root = next; i += 1
        case "--arch": arch = next; i += 1
        case "--size":
            guard let n = next, let s = parseSize(n) else {
                print("vmimage: --size takes a size like 20G")
                return 2
            }
            size = s
            i += 1
        case "--limit":
            guard let n = next, let m = int64(n) else {
                print("vmimage: --limit takes a number of MB")
                return 2
            }
            limit = m * 1_000_000
            i += 1
        case "--pull", "--list", "--locate", "--images", "--inspect", "--path", "--clone", "--rm", "--prune":
            action = a
        case "-h", "--help":
            usage()
            return 0
        default:
            operands.append(a)
        }
        i += 1
    }
    if action.isEmpty {
        usage()
        return 2
    }
    if let a = arch, a != "arm64" && a != "amd64" {
        print("vmimage: --arch is arm64 or amd64")
        return 2
    }
    do {
        switch action {
        case "--list":
            if let d = operands.first {
                guard let v = catalog.Lookup(d) else { throw catalog.CatalogError.unknownDistro(d) }
                print("\(v.Name): " + (v.Releases.isEmpty ? "any numbered release, and latest" : v.Releases.joined(separator: ", ") + ", latest"))
            } else {
                for v in catalog.All {
                    print(pad(v.Name, 12) + (v.Releases.isEmpty ? "any numbered release, and latest" : v.Releases.joined(separator: ", ") + ", latest"))
                }
            }
            return 0
        case "--locate":
            guard let name = operands.first else {
                usage()
                return 2
            }
            let parsed = try ref.Reference.Parse(name)
            guard let v = catalog.Lookup(parsed.Distro) else { throw catalog.CatalogError.unknownDistro(parsed.Distro) }
            let a = arch ?? vmimage.HostArch()
            let l = try await v.Locate(release: parsed.Release, variant: parsed.Variant, arch: a)
            print("Name:        \(parsed.Distro):\(l.Release)" + (l.Variant.isEmpty ? "" : "-" + l.Variant) + " (\(a))")
            print("URL:         \(l.URL)")
            if l.Size > 0 { print("Size:        \(human(l.Size))") }
            print("Checked by:  " + (l.Digest.isEmpty ? "\(l.FileName) in \(l.ChecksumURL)" : "\(l.Digest) (from \(l.ChecksumURL))"))
            print("Kind:        \(l.Kind)")
            print("Guest:       \(l.Guest), boots by \(l.Boot)")
            return 0
        case "--help":
            usage()
            return 0
        default:
            break
        }
        let st = try library.Store(root: root)
        switch action {
        case "--pull":
            guard let name = operands.first else {
                usage()
                return 2
            }
            do {
                let r = try await vmimage.Pull(name, into: st, arch: arch, limit: limit) { print($0) }
                print("\(r.Name)  \(r.Arch)  \(human(r.VirtualSize))  \(r.Digest.prefix(19))…")
            } catch source.SourceError.stopped(let url, let bytes, let total) {
                print("stopped at \(human(bytes)) of \(human(total)); pull again to resume")
                return 0
            }
        case "--images":
            print(pad("NAME", 24) + pad("ARCH", 7) + pad("FORMAT", 8) + pad("DISK", 10) + "DIGEST")
            for r in st.Records {
                print(pad(r.Name, 24) + pad(r.Arch, 7) + pad(r.Format, 8) + pad(human(r.VirtualSize), 10) + r.Digest.prefix(19) + "…")
            }
        case "--inspect", "--path", "--clone", "--rm":
            guard let name = operands.first else {
                usage()
                return 2
            }
            if action == "--rm" {
                let parsed = try ref.Reference.Parse(name)
                try st.Remove(parsed.Name, arch: arch ?? vmimage.HostArch())
                print("forgot \(parsed.Name)")
                return 0
            }
            guard let r = try vmimage.Resolve(name, in: st, arch: arch) else { throw library.StoreError.notFound(name) }
            switch action {
            case "--path":
                print(st.PathOf(r).Value)
            case "--inspect":
                print("Name:        \(r.Name)")
                print("Arch:        \(r.Arch)")
                print("Digest:      \(r.Digest)")
                print("Source:      \(r.URL)")
                print("Vendor file: \(r.Format)")
                if r.Kind == "disk" {
                    print("Disk:        \(human(r.VirtualSize)) (raw, sparse)")
                    print("File:        \(st.ImagePath(r.Digest).Value)")
                } else {
                    print("Kind:        \(r.Kind): kernel, ramdisk and \(human(r.VirtualSize)) of raw disks")
                    print("Directory:   \(st.BundlePath(r.Digest).Value)")
                    for e in (try? fs.ReadDir(st.BundlePath(r.Digest))) ?? [] {
                        print("             \(e.Name)")
                    }
                }
                print("Guest:       \(r.Guest), boots by \(r.Boot)")
                print("Secure Boot: \(r.SecureBoot ? "yes" : "no")")
                print("Seed:        \(r.Seed ? "wants a cloud-init seed" : "none needed")")
            default:
                guard operands.count == 2 else {
                    usage()
                    return 2
                }
                try vmimage.Clone(r, in: st, to: operands[1], size: size)
                print("\(operands[1])  from \(r.Name)")
            }
        case "--prune":
            print("freed \(human(try st.Prune()))")
        default:
            usage()
            return 2
        }
    } catch {
        print("vmimage: \(error)")
        return 1
    }
    return 0
}
