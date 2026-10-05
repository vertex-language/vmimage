// Package source fetches what vmimage keeps: small text files (a
// vendor's checksum list, a directory listing) and large images, over
// HTTPS, hashing as they stream and resuming a broken download.
package source

import (
    "fs"
    "net/http"
    "net/url"
)

public enum SourceError: Error, CustomStringConvertible {
    case status(code: int32, url: string)
    case tooManyRedirects(string)
    case mismatch(url: string, expected: string, got: string)
    case sizeMismatch(url: string, expected: int64, got: int64)
    /// A download cut off at the caller's limit; what came is kept to resume.
    case stopped(url: string, bytes: int64, total: int64)

    public var description: string {
        switch self {
        case .status(let c, let u): return "\(u): the server answered \(c)"
        case .tooManyRedirects(let u): return "\(u): too many redirects"
        case .mismatch(let u, let e, let g): return "\(u) is \(g), the vendor's checksum says \(e)"
        case .sizeMismatch(let u, let e, let g): return "\(u): \(g) bytes arrived, expected \(e)"
        case .stopped(let u, let b, let t): return "\(u): stopped at \(b) of \(t) bytes (kept to resume)"
        }
    }
}

func newClient() -> http.Client {
    var cfg = http.ClientConfig(enabledVersions: [http.HttpVersion.http1_1], timeoutMs: 30000)
    cfg.ReadTimeoutMs = 60000
    return http.Client(config: cfg)
}

/// Opens `address`, following redirects, with an optional byte range
/// start. Returns the stream and the URL it ended at.
func open(_ client: http.Client, _ address: string, from: int64 = 0) async throws -> http.ResponseStream {
    var target = try url.Parse(address)
    var hops = 0
    while true {
        var req = http.Request(method: "GET", url: target.RequestURI)
        req.Headers.Set("User-Agent", "vertex-vmimage/0.1")
        if from > 0 { req.Headers.Set("Range", "bytes=\(from)-") }
        var s = try await client.Open(req, url: target)
        let code = s.Response.StatusCode
        if code == 301 || code == 302 || code == 303 || code == 307 || code == 308 {
            let loc = s.Response.Headers.Get("Location")
            s.Close()
            hops += 1
            guard let l = loc, hops <= 10 else { throw SourceError.tooManyRedirects(address) }
            target = try target.Resolve(l)
            continue
        }
        if code != 200 && code != 206 {
            s.Close()
            throw SourceError.status(code: code, url: address)
        }
        return s
    }
}

/// Where `address` ends up after its redirects (the first reply's body is
/// not read).
public func Final(_ address: string) async throws -> string {
    let client = newClient()
    var target = try url.Parse(address)
    var hops = 0
    while true {
        var req = http.Request(method: "GET", url: target.RequestURI)
        req.Headers.Set("User-Agent", "vertex-vmimage/0.1")
        var s = try await client.Open(req, url: target)
        let code = s.Response.StatusCode
        let loc = s.Response.Headers.Get("Location")
        s.Close()
        if code == 301 || code == 302 || code == 303 || code == 307 || code == 308 {
            hops += 1
            guard let l = loc, hops <= 10 else { throw SourceError.tooManyRedirects(address) }
            target = try target.Resolve(l)
            continue
        }
        if code != 200 { throw SourceError.status(code: code, url: address) }
        return target.String()
    }
}

/// The hex digest of a file on disk.
public func HashFile(_ path: fs.Path, algorithm: Algorithm) throws -> string {
    var h = Digester(algorithm)
    let f = try fs.Open(path)
    defer { try? f.Close() }
    var buf = [uint8](repeating: 0, count: 1 << 20)
    while true {
        let n = try f.Read(into: &buf)
        if n == 0 { break }
        h.Write(n == buf.count ? buf : Array(buf[0..<n]))
    }
    return h.Hex()
}

/// A small text file, whole.
public func Text(_ address: string) async throws -> string {
    let client = newClient()
    var s = try await open(client, address)
    var out: [uint8] = []
    var buf = [uint8](repeating: 0, count: 64 * 1024)
    do {
        while true {
            let n = try await s.Read(into: &buf)
            if n == 0 { break }
            out.append(contentsOf: n == buf.count ? buf : Array(buf[0..<n]))
        }
    } catch {
        s.Close()
        throw error
    }
    s.Close()
    return string(decoding: out, as: UTF8.self)
}

/// What a download made.
public struct Downloaded {
    /// "sha512:…": the hash of the file, of the algorithm asked for.
    public var Digest: string
    public var Size: int64
}

/// Downloads `address` to `path`, hashing with `algorithm`. A file kept
/// at `path + ".partial"` from an earlier try is hashed and continued
/// (`Range`), or started over if the server won't. `expected`, a hex
/// digest, is checked at the end: a mismatch removes the file. `limit`
/// stops after that many bytes, keeping the partial file (to look at
/// progress without taking whole images).
public func Download(_ address: string, to path: fs.Path, algorithm: Algorithm, expected: string? = nil,
                     limit: int64? = nil, progress: (int64, int64) -> Void = { _, _ in }) async throws -> Downloaded {
    let partial = fs.Path(path.Value + ".partial")
    var hasher = Digester(algorithm)
    var have: int64 = 0
    if fs.Exists(partial) {
        let f = try fs.Open(partial)
        var buf = [uint8](repeating: 0, count: 1 << 20)
        while true {
            let n = try f.Read(into: &buf)
            if n == 0 { break }
            hasher.Write(n == buf.count ? buf : Array(buf[0..<n]))
            have += int64(n)
        }
        try f.Close()
    }
    let client = newClient()
    var s = try await open(client, address, from: have)
    var total: int64 = Int64(s.Response.Headers.Get("Content-Length") ?? "") ?? 0
    var out: fs.File
    if s.Response.StatusCode == 206 {
        total += have
        var o = fs.OpenOptions()
        o.Read = false
        o.Write = true
        o.Append = true
        out = try fs.Open(partial, o)
    } else {
        // The server sent the whole file again.
        hasher = Digester(algorithm)
        have = 0
        out = try fs.Create(partial)
    }
    var buf = [uint8](repeating: 0, count: 256 * 1024)
    var last = have
    do {
        while true {
            let n = try await s.Read(into: &buf)
            if n == 0 { break }
            let chunk = n == buf.count ? buf : Array(buf[0..<n])
            try out.Write(chunk)
            hasher.Write(chunk)
            have += int64(n)
            if have - last >= 1 << 20 {
                last = have
                progress(have, total)
            }
            if let l = limit, have >= l {
                s.Close()
                try out.Close()
                progress(have, total)
                throw SourceError.stopped(url: address, bytes: have, total: total)
            }
        }
    } catch {
        s.Close()
        try? out.Close()
        throw error
    }
    s.Close()
    try out.Close()
    progress(have, total)
    if total > 0 && have != total {
        throw SourceError.sizeMismatch(url: address, expected: total, got: have)
    }
    if let e = expected, e.lowercased() != hasher.Hex() {
        try? fs.Remove(partial)
        throw SourceError.mismatch(url: address, expected: e, got: hasher.Hex())
    }
    try fs.Rename(partial, path)
    return Downloaded(Digest: hasher.Digest(), Size: have)
}
