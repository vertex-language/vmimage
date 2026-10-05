# vmimage

Pull bootable VM disk images straight from the vendors that publish them,
by a short name, with a Docker-style `name:tag`:

```bash
vmimage --pull debian:12
vmimage --pull ubuntu:24.04 --arch amd64
vmimage --clone debian:12 web.raw --size 20G      # a disk of its own
vm-run --disk web.raw --firmware …               # boot it
```

`vmimage` is for **bootable disk images only** (and Android's, which come as a kernel plus disks): the `.qcow2`, `.img`, `.raw`
and `.vhdx` files that Debian, Ubuntu, Fedora, Alpine, Rocky, AlmaLinux and
FreeBSD put on their download servers for virtual machines. A name goes in, a
checked disk image comes out (always as one sparse raw file; see
[Why raw](#why-raw)), and [`vm`](../vm) boots it. It stands alone: it shares
no code or store with the container tools.

> **Status: started.** `vmimage --pull`, `--locate`, `--images`, `--inspect`, `--path`,
> `--clone`, `--rm` and `--prune` work for **Debian, Ubuntu, AlmaLinux and Android** (AOSP, no Google services),
> checked against their live servers. Fedora, Alpine, Rocky and FreeBSD are
> next (rows marked *planned* below). `--clone` makes a raw disk; qcow2
> overlay clones are next, now that `vm/disk/qcow2` writes.

```
 vmimage CLI                    --pull · --list · --images · --inspect · --path · --clone · --rm · --prune
═══════════════════════════════════════════════════════════════════════════════════
 vmimage            Pull, Resolve, Clone: a name to a disk image on disk
 vmimage/ref  debian:12, ubuntu:24.04, fedora:40@sha256:…, with --arch
 vmimage/catalog    one resolver per vendor: where "debian:12" lives, how it's checked
 vmimage/source     HTTPS download that resumes; SHA256SUMS / SHA512SUMS / CHECKSUM files
 vmimage/library      verified images by digest, names in an index, atomic ingest
 vmimage/convert    unpack .xz/.gz/.zst; any format → sparse raw
```

## Names

`<distro>:<release>[-<variant>]`, as Docker spells `image:tag`. The release is
whatever the vendor calls it (`11`, `12`, `24.04`, `40`, `3.20`, a code name
where that is what the vendor uses); `latest` is the newest the vendor
publishes. `@sha256:…` pins the exact bytes, because a vendor's `latest`
moves under you.

| Name | Vendor | What it is |
| :--- | :--- | :--- |
| `debian:11` · `12` · `13` | cloud.debian.org | The *genericcloud* image (`debian:12-generic` has hardware drivers; `debian:12-nocloud` logs in as root with no cloud-init) |
| `ubuntu:22.04` · `24.04` · any `NN.NN` · `latest` | cloud-images.ubuntu.com | The server cloud image (`ubuntu:24.04-minimal` for the small one) |
| `fedora:40` | download.fedoraproject.org | *planned.* Fedora Cloud Base (Generic) |
| `alpine:3.20` | dl-cdn.alpinelinux.org | *planned.* The cloud image (UEFI, cloud-init) |
| `almalinux:8` · `9` · `10` | repo.almalinux.org | GenericCloud (`almalinux:9-ext4` for the ext4 one) |
| `rocky:9` | dl.rockylinux.org | *planned.* GenericCloud |
| `freebsd:14` | download.freebsd.org | *planned* (needs an xz decoder in `compress`). The VM image |
| `android:5` … `16` · `7.1` · `12l` · an API level (`36`) · `latest` | dl.google.com/android/repository | AOSP with no Google services, built by Google for the emulator (`android:15-atd`, `android:14-tablet`). Pulled as a bundle (kernel, ramdisk, raw disks). See [Android](#android) |

`--arch` is the host's by default (`arm64` on Apple silicon, `amd64`
elsewhere): a name is resolved to the file for that architecture, and an
architecture the vendor doesn't publish is an error naming the ones it does.

## How a pull works

1. **Resolve.** The catalog entry for the vendor turns the name into a URL by
   reading what the vendor publishes: a known path for Debian and Ubuntu,
   a directory listing for vendors whose file names carry a build number
   (Fedora, Alpine). No URL is hard-coded to a build that will be deleted.
2. **Checksum.** The vendor's own checksum file (`SHA512SUMS`, `SHA256SUMS`,
   `CHECKSUM`) is fetched over HTTPS and read for that file's digest. Where
   the vendor signs it, the signature is checked against the vendor's key,
   pinned in the catalog.
3. **Download.** To a `.partial` file, resuming with `Range` after a break,
   hashed as it streams. A mismatch deletes it and fails; the name is never
   pointed at unchecked bytes.
4. **Convert.** Whatever the vendor shipped (qcow2, vmdk, vhdx, `.xz`, `.gz`,
   `.zst`) is unpacked and written once as a **sparse raw image**, the one
   format the store keeps and `--path` returns; the vendor file is then
   discarded. The image is kept under the *vendor's* digest (hashing a
   multi-gigabyte raw file again would cost more than it proves), so the
   next pull still sees at once that nothing changed.
5. **Name it.** `index.json` maps `debian:12` (for the host's arch) to that
   digest. A second `--pull` of an unchanged image reads the checksum file,
   sees the digest is already there, and downloads nothing.

The store lives at `$VERTEX_VMIMAGE_ROOT`, or `vertex/vmimage` in the user's
data directory, as `blobs/sha256/<hex>` (one raw image each) plus `index.json`; `--root <dir>`
says otherwise.

## The `vmimage` command

```bash
vsc build -o ./vmimage ./cmd/vmimage

vmimage --pull debian:12                     # fetch, verify, keep
vmimage --pull ubuntu:24.04 --arch amd64
vmimage --pull debian:12@sha512:89a752d5…    # exactly the file with this digest (the vendor's)
vmimage --pull debian:12 --limit 50          # stop after 50 MB of the download (kept to resume)
vmimage --list                               # what vendors offer (names, releases, arches)
vmimage --list debian                        # one vendor's releases
vmimage --locate android:16                  # the URL, size and digest a pull would use; downloads nothing
vmimage --images                             # what is pulled
vmimage --inspect debian:12                  # format, virtual size, digest, source URL, checked how
vmimage --path debian:12                     # prints the file (a directory for a bundle), for scripts: vm-run --disk "$(vmimage --path debian:12)"
vmimage --clone debian:12 ./web.raw --size 20G     # a disk of its own to boot and change
vmimage --rm debian:12
vmimage --prune                              # delete blobs no name reaches
```

**`--clone` is what you boot.** A pulled image is a template and stays as
verified; booting it writes to it. `--clone` makes a disk of your own: on
APFS a copy-on-write clone (`clonefile`: instant, and it costs nothing until
the guest writes), elsewhere a sparse copy, and larger if `--size` says so.
`vm/disk/qcow2` writes now (`qcow2.Create` with a backing image), so
`--clone` can next make a qcow2 overlay on the pulled image instead
(`--format qcow2`): small and portable, with the same shared base.

`vsc run check` needs no network and no fixtures on disk: it makes its
test disk as it runs and writes it each way a vendor ships one (qcow2
plain and deflated with `vm/disk/qcow2`, gzip and zstd with `compress`),
then converts each back and compares.

### Why raw

Every pulled image is stored as sparse raw, whatever the vendor used, so
a consumer never has to ask what it got. Raw because:

- **It is the safest thing for `vm` to read.** `vm.OpenDisk` takes raw
  directly; vendor qcow2 files use compressed clusters (reading them was
  added to `vm/disk/qcow2` for the converter), and a base that is only read should not
  depend on a format driver at all.
- **It is the fastest:** no L2 lookups, no refcounts, one offset.
- **Sparse files keep it small on disk** (zero runs are never written),
  and `vmimage` writes it sparsely itself. APFS and ext4/xfs/btrfs keep
  holes; on NTFS the file is marked sparse.
- **Clones are cheap anyway:** APFS clones the raw file for free, and a qcow2 overlay's backing image can be raw.

The cost is size when copied by tools that don't know about holes; hence
`--clone` rather than `cp`. qcow2 is for the per-VM overlay, where its
copy-on-write earns its keep; VHDX is for Hyper-V and isn't produced.

## Android

Google builds plain AOSP for the Android emulator and publishes it in the
Android SDK repository: **no Google Mobile Services, no Play Store**,
`userdebug` with `test-keys`, Apache-licensed. These are the only
Google-hosted Android images that download anonymously, are versioned, and
come with a digest, so they are what `android:<release>` names.

**Where.** Each image family has a directory under
`https://dl.google.com/android/repository/sys-img/` with an index,
`sys-img2-3.xml` (the version `addons_list-5.xml` points at). A
`remotePackage path="system-images;android-<api>;<tag>;<abi>"` element
carries the zip's file name (relative to that directory), its size, and its
**SHA-1**, the only digest Google gives. `catalog.Android` reads the index
on each resolve, so new revisions (`_r03`) are picked up without a change here.

| Name | Directory · tag | arm64 (`arm64-v8a`) | amd64 (`x86_64`) |
| :--- | :--- | :--- | :--- |
| `android:<release>` | `android` · `default` | API 21–36 | API 21–36 (no 29) |
| `android:<release>-atd` | `aosp_atd` · `aosp_atd` (Automated Test Device: no launcher or apps, for headless tests) | API 30–36 | API 30–36 |
| `android:<release>-tablet` | `aosp_tablet` · `aosp_tablet` | API 34 | API 34 |

Releases: `5`=21, `5.1`=22, `6`=23, `7`=24, `7.1`=25, `8`=26, `8.1`=27, `9`=28, `10`=29, `11`=30, `12`=31, `12l`=32, `13`=33, `14`=34,
`15`=35, `16`=36; any number of 21 or more is taken as an API level. As of
October 2026 `android:16` for arm64 is `arm64-v8a-36_r02.zip`, 811 MB.
Left out on purpose: `google_apis`, `google_apis_playstore`, `google_atd`,
`google-tv`, `android-tv`, `android-wear`, `android-automotive` and
`android-desktop`, which carry Google services or are form factors `vm`
won't model first.

**What's in the zip** (`<abi>/` inside; API 36 arm64 shown):

| File | What it is |
| :--- | :--- |
| `kernel-ranchu` | The kernel: a gzip'd arm64 `Image` (36 MB unpacked; x86_64: a bzImage), 14 MB |
| `ramdisk.img` | LZ4 (legacy frame) cpio: the first-stage init |
| `system.img` | A raw **GPT disk** (1.9 GB): vbmeta and `super`, which holds the dynamic partitions (system, product, system_ext…) |
| `vendor.img` | A raw GPT disk (100 MB): vendor partitions |
| `encryptionkey.img` | A small disk for userdata's metadata encryption |
| `kernel_cmdline.txt` | Extra kernel arguments (`8250.nr_uarts=1`) |
| `VerifiedBootParams.textproto` | The `androidboot.vbmeta.{size,hash_alg,digest}` arguments the bootloader would pass |
| `advancedFeatures.ini` | Emulator features the image expects (VirtioInput, VirtioWifi, VirtioSndCard, VirtioVsockPipe, DynamicPartition, EncryptUserData, …) |
| `build.prop`, `source.properties` | Version (`ro.build.version.sdk=36`), build type, ABI |
| `data/` | A seed for userdata; userdata itself is made empty at first boot |

It boots by **direct kernel boot** on the emulator's `ranchu` board (a
virtio-based arm64 `virt` machine; graphics through goldfish pipes or
virtio-gpu with gfxstream), not from firmware, so a pull keeps the
pieces rather than one disk: a **bundle**.

```bash
vmimage --pull android:16          # 811 MB zip, SHA-1 checked, unpacked
vmimage --path android:16          # …/images/sha1-62ad6714…/  (a directory)
vmimage --clone android:16 ./phone --size 8G
# ./phone/kernel-ranchu ramdisk.img system.img vendor.img encryptionkey.img
#         userdata.img (8 GiB, a fresh ext4) kernel_cmdline.txt …
```

`--clone` keeps an image's own `userdata.img` where it brings an ext4 one
(Android 8.1 and older ship an empty ext4), and formats a sparse ext4 of
`--size` (6 GiB) where it doesn't ([`fs/ext4`](../fs); Android 9 ships
zeros, and mounts /data as it finds it). It adds a `cache.img` (a copy of
the image's empty userdata) for releases that mount /cache from a disk.
[`vm`](../vm) boots Android 5–9 clones: `vm-run --android <dir>` (8 and 9
with `--gles`); `android:5` (API 21, 201 MB) is the smallest image there is.

The zip is read with `archive/zip`'s file-backed `Archive`, streamed entry by
entry (never the whole archive in memory), each entry's CRC-32 checked, and
every file written sparsely in 64 KiB pieces. The store keeps the bundle as
`images/sha1-<hex>/`; its record says `kind: android-emulator`, `guest:
android`, `boot: ranchu`, for `vm` to build its machine from.

**Considered and not used:**

- **Cuttlefish** (`aosp_cf_arm64_only_phone-img-<build>.zip` plus
  `cvd-host_package.tar.gz` from ci.android.com): AOSP's own virtual device,
  pure virtio on crosvm/QEMU, and the better match for `vm` in the long
  run. But it is published only as CI builds with no stable name, and in
  October 2026 anonymous downloads (`ci.android.com/builds/latest/…`, the
  v3 build API) answer *403: rate limit exceeded for legacy API, migrate to
  Build API v4*, which needs credentials. Revisit if v4 gets a public read path.
- **GSIs** (Generic System Images, developer.android.com): a `system.img`
  only, for flashing onto a device that already has a vendor and kernel.
  Not bootable on its own.

## Using it from Vertex

```vertex
import "vmimage"

let st = try vmimage.Store()
let img = try await vmimage.Pull("debian:12", into: st)       // checked, cached
let disk = try vmimage.Clone(img, to: "web.qcow2", size: 20 << 30)
// vm.Config(disk: disk, firmware: …)
```

`vm` doesn't know about `vmimage`: `vm-run` takes the path it prints
(`--disk "$(vmimage --path debian:12)"`), and tools that want a name, such as
`container`'s VM backend, call `vmimage` themselves.

## Packages

| Package | What it does |
| :--- | :--- |
| **`vmimage`** | `Pull`, `Resolve`, `Clone`, `Image` (name, arch, format, virtual size, digest, source). The few calls the CLI and `vm` use. |
| **`vmimage/ref`** | Parses `debian:12`, `ubuntu:24.04-minimal`, `fedora:40@sha256:…`, `latest`; keeps distro, release, variant, arch and digest apart. |
| **`vmimage/catalog`** | `Vendor`, the protocol a resolver implements (`Releases()`, `Locate(release, variant, arch)` → URL, checksum URL, signature, compression), and one implementation per vendor. Adding a distro is adding a file here. |
| **`vmimage/source`** | The download: HTTPS with redirects and resume, progress, and the parsers for `SHA256SUMS`/`SHA512SUMS` (GNU), `CHECKSUM` (BSD `SHA256 (file) = …`) and signed variants. |
| **`vmimage/library`** | The images on disk, each named by the digest the vendor published (SHA-256 or SHA-512, from `crypto`), and the index that maps `debian:12` for an arch to one. Each name also records what the image is: architecture, vendor format, guest (`linux`, `bsd`), boot (`efi`), whether Secure Boot firmware boots it, and whether it wants a cloud-init seed, for `vm` to build its configuration from. |
| **`vmimage/convert`** | `UnpackAndroid`: an emulator zip to a sparse bundle directory (`archive/zip`). Unpack `.xz`/`.gz`/`.zst` (`compress`), read a qcow2/raw/vhdx header for its virtual size (`vm/disk`), flatten qcow2 (and raw, gzip, zstd) to sparse raw, synchronously; vhdx and vmdk later; qcow2 overlays once vm/disk/qcow2 can write. |

Dependencies are leaf-ward only: `net`, `compress`, `archive`, `crypto`, `encoding`, `fs`, and `vm/disk` for
image formats, so the dependency runs one way: `vmimage` uses `vm/disk`, and
`vm` never uses `vmimage`. It doesn't use `oci` or `container`.

## What it is not

- **Not for Docker images.** Container images, layers and registries are
  [`oci`](../oci)'s; running them is [`container`](../container)'s.
  `vmimage` only handles VM disk images, never a root filesystem.
- **Not firmware or kernels.** UEFI firmware stays with `vm`, and the kernel a
  container's VM boots with belongs to `container`. A vendor cloud image
  carries its own kernel and boots from the UEFI firmware `vm` already has.
- **Not installer media.** ISOs you install from (Windows, Ubuntu Desktop) are
  given to `vm-run --iso` by path; most can't be downloaded unattended anyway.
- **Not cloud-init.** A cloud image wants a seed (a user, an SSH key) on first
  boot. Making the seed disk is a `vm` job; `vmimage` only supplies the image.
- **Not a mirror.** It pulls from the vendors' own servers and publishes
  nothing.

## Roadmap

1. **Done:** `ref`, `library`, `source`, `convert` (qcow2, gzip, zstd, raw
   to sparse raw), Debian, Ubuntu and AlmaLinux: `--pull`, `--images`, `--path`,
   `--clone` (raw).
2. Fedora, Alpine, Rocky (listing-based vendors), FreeBSD (`.xz`, VHD/vmdk).
   Android: done for the emulator images (`android:16`); Cuttlefish when its builds can be fetched anonymously.
3. Signature checks for the vendors that sign their checksum files, with
   keys pinned in the catalog; `--inspect` says whether a pull was signed.
4. `--list` against the live servers; `--format qcow2` clones once `vm/disk/qcow2` writes; vhdx and vmdk conversion.
5. The `container` VM backend and other tools calling `vmimage` for a named
   disk.

## License

See [LICENSE](LICENSE).
