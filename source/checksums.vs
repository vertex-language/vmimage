package source

/// The digests in a vendor's checksum file, by file name. Two layouts:
///
///     <hex>  <name>            GNU: SHA256SUMS, SHA512SUMS (the name may start with *)
///     SHA256 (<name>) = <hex>  BSD: CHECKSUM files (Rocky, Alma, FreeBSD, Fedora)
///
/// The algorithm is the BSD line's own or comes from the hex's length.
public func ParseChecksums(_ text: string) -> [string: (Algorithm, string)] {
    var out: [string: (Algorithm, string)] = [:]
    for raw in text.split(separator: "\n") {
        let line = trimmed(string(raw))
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("-----") { continue }
        // BSD: ALGO (name) = hex
        if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close,
           let eq = line[close...].firstIndex(of: "=") {
            let algo = Algorithm.Named(trimmed(string(line[..<open])).replacingDashes())
            let name = string(line[line.index(after: open)..<close])
            let hex = trimmed(string(line[line.index(after: eq)...])).lowercased()
            if let a = algo ?? Algorithm.OfHex(hex), a == Algorithm.OfHex(hex) {
                out[name] = (a, hex)
            }
            continue
        }
        // GNU: hex name
        guard let space = line.firstIndex(of: " ") else { continue }
        let hex = string(line[..<space]).lowercased()
        var name = trimmed(string(line[space...]))
        if name.hasPrefix("*") { name = string(name.dropFirst()) }
        if let a = Algorithm.OfHex(hex) {
            out[name] = (a, hex)
        }
    }
    return out
}

func trimmed(_ s: string) -> string {
    var b = [uint8](s.utf8)
    while let f = b.first, f == 0x20 || f == 0x09 || f == 0x0D { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0D || l == 0x0A { b.removeLast() }
    return string(decoding: b, as: UTF8.self)
}

extension String {
    /// "SHA-256" as "SHA256".
    func replacingDashes() -> string {
        string(self.filter { $0 != "-" })
    }
}
