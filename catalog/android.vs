package catalog

import (
    "encoding/xml"
    "vmimage/source"
)

/// Google's Android SDK repository (dl.google.com/android/repository): the
/// emulator's system images built from AOSP with no Google services (no
/// GMS, no Play Store; userdebug, test-keys). Each repository directory
/// has an index, `sys-img2-3.xml`, listing a `remotePackage` per image
/// (`system-images;android-36;default;arm64-v8a`) with its zip's file
/// name, size and SHA-1; the zip sits beside the index.
///
///     android:16           Android 16 (API 36), the phone image
///     android:36           the same, by API level
///     android:16-atd       Automated Test Device: trimmed for headless tests
///     android:14-tablet    the tablet image (API 34 only so far)
///
/// The zip is not one disk: `<abi>/kernel-ranchu` (a gzip'd arm64 Image or
/// an x86 bzImage), `ramdisk.img` (LZ4-legacy cpio), `system.img` and
/// `vendor.img` (raw GPT disks: vbmeta, and super with the dynamic
/// partitions, since API 29), `encryptionkey.img`, `kernel_cmdline.txt`,
/// `VerifiedBootParams.textproto` (the androidboot.vbmeta.* arguments),
/// `advancedFeatures.ini` and `build.prop`. It boots on the emulator's
/// "ranchu" board, by direct kernel boot, not from firmware.
///
/// The Google-services images (google_apis, google_apis_playstore, and
/// the TV, Wear and Automotive ones) are left out on purpose.
public struct Android: Vendor {
    public init() {}

    public var Name: string { "android" }
    public var Releases: [string] {
        ["5", "5.1", "6", "7", "7.1", "8", "8.1", "9", "10", "11", "12", "12l", "13", "14", "15", "16"]
    }

    static let base = "https://dl.google.com/android/repository/sys-img/"

    /// Android version → API level. A number of 21 or more is an API level
    /// already, so a newer release works before this table knows it.
    static let apiLevels = ["5": "21", "5.1": "22", "6": "23", "7": "24", "7.1": "25", "8": "26", "8.1": "27", "9": "28", "10": "29", "11": "30", "12": "31", "12l": "32", "13": "33",
                            "14": "34", "15": "35", "16": "36"]

    /// Variant → repository directory and tag.
    static let variants = ["": ("android", "default"), "atd": ("aosp_atd", "aosp_atd"),
                           "tablet": ("aosp_tablet", "aosp_tablet")]

    public func Locate(release: string, variant: string, arch: string) async throws -> Located {
        guard let (dir, tag) = Android.variants[variant] else {
            throw CatalogError.unknownVariant(distro: "android", variant: variant, known: ["atd", "tablet"])
        }
        let abi = try spell(arch, ["arm64": "arm64-v8a", "amd64": "x86_64"], distro: "android")
        let index = Android.base + dir + "/sys-img2-3.xml"
        let offered = Android.Parse(try await source.Text(index), tag: tag, abi: abi)
        var api = release.lowercased()
        if api == "latest" {
            guard let newest = offered.map({ $0.API }).sorted(by: apiBefore).last else {
                throw CatalogError.noArch(distro: "android", arch: arch)
            }
            api = newest
        } else if let a = Android.apiLevels[api] {
            api = a
        }
        guard let p = offered.first(where: { $0.API == api }) else {
            let known = offered.map { $0.API }.sorted(by: apiBefore)
            throw CatalogError.unknownRelease(distro: "android", release: release, known: known)
        }
        var l = Located(Release: release == "latest" ? api : release, Variant: variant,
                        URL: Android.base + dir + "/" + p.File, FileName: p.File, ChecksumURL: index)
        l.Digest = p.Algorithm + ":" + p.Hex
        l.Size = p.Size
        l.Kind = "android-emulator"
        l.Guest = "android"
        l.Boot = "ranchu"
        l.SecureBoot = false
        l.Seed = false
        return l
    }

    /// One system image the index offers.
    public struct Package {
        /// "36", "35-ext15", "37.0".
        public var API: string
        /// "arm64-v8a-36_r02.zip", relative to the index.
        public var File: string
        public var Size: int64
        /// "sha1", and the digest.
        public var Algorithm: string
        public var Hex: string
    }

    /// The images in a repository index for `tag` and `abi`, leaving out
    /// obsolete ones.
    public static func Parse(_ text: string, tag: string, abi: string) -> [Package] {
        guard let doc = try? xml.Parse(text) else { return [] }
        var out: [Package] = []
        for pkg in doc.Root.Descendants("remotePackage") {
            guard let path = pkg.Attribute("path") else { continue }
            let parts = path.split(separator: ";").map { string($0) }
            guard parts.count == 4, parts[0] == "system-images", parts[1].hasPrefix("android-"),
                  parts[2] == tag, parts[3] == abi else { continue }
            if !pkg.Descendants("obsolete").isEmpty { continue }
            for archive in pkg.Descendants("archive") where archive.Descendants("host-os").isEmpty {
                guard let complete = archive.Descendants("complete").first,
                      let file = complete.Descendants("url").first?.Text,
                      let sum = complete.Descendants("checksum").first,
                      let size = int64(complete.Descendants("size").first?.Text ?? "") else { continue }
                out.append(Package(API: string(parts[1].dropFirst(8)), File: file, Size: size,
                                   Algorithm: sum.Attribute("type") ?? "sha1", Hex: sum.Text.lowercased()))
                break
            }
        }
        return out
    }
}

/// API levels in order: "9" < "35" < "35-ext15" < "36" < "36.1" < "37.0".
func apiBefore(_ a: string, _ b: string) -> bool {
    func key(_ s: string) -> (int, string) {
        var digits = ""
        for c in s {
            if !c.isNumber { break }
            digits.append(c)
        }
        return (int(digits) ?? 0, string(s.dropFirst(digits.count)))
    }
    let (x, y) = (key(a), key(b))
    return x.0 != y.0 ? x.0 < y.0 : x.1 < y.1
}
