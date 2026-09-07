// EMLParser+Parameters.swift
// Helpers for extracting MIME header parameters (boundary, filename, etc.).

import Foundation

extension EMLParser {

    // MARK: - Header Parameter Extraction

    /// Extract the MIME type (e.g. "text/html") from a full Content-Type value.
    static func extractMIMEType(from contentType: String) -> String {
        let parts = contentType.split(separator: ";", maxSplits: 1)
        return parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? contentType
    }

    // The branches are the MIME lexical states rather than independent paths.
    // swiftlint:disable cyclomatic_complexity
    /// Split a header field body into its top-level `;`-separated segments.
    ///
    /// A `;` between the quotes of a parameter value is part of that value —
    /// `name="a;b.pdf"` is one parameter, not two — so splitting has to know
    /// where the quotes are, or a value the sender chooses decides where the
    /// parameters are.
    ///
    /// RFC 822 comments are ignored as grammar, including nested comments, so a
    /// quote or semicolon in a comment cannot change the parameter structure.
    /// An RFC 2045 quoted-pair inside quotes or a comment — a `\` before any
    /// character — is honored: the escaped character stands for itself, so a
    /// `\"` does not close the value. The quoted-string reader in
    /// ``extractHeaderParam(from:named:)`` applies the identical rule, so the
    /// two agree on where a value ends; if they did not, a parameter could be
    /// found in a segment whose value the reader then runs past.
    static func parameterSegments(of header: String) -> [Substring] {
        var segments: [Substring] = []
        var start = header.startIndex
        var index = header.startIndex
        var inQuotes = false
        var commentDepth = 0
        let scalars = header.unicodeScalars

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if (inQuotes || commentDepth > 0) && scalar == "\\" {
                // Quoted-pair: the next character is literal, so it can neither
                // close the quote nor separate parameters. Skip both here, as
                // the value reader unescapes them, or the two disagree on where
                // the quoted value ends.
                index = scalars.index(after: index)
                if index < scalars.endIndex {
                    index = scalars.index(after: index)
                }
                continue
            }
            if commentDepth > 0 {
                if scalar == "(" {
                    commentDepth += 1
                } else if scalar == ")" {
                    commentDepth -= 1
                }
            } else if !inQuotes && scalar == "(" {
                commentDepth = 1
            } else if scalar == "\"" {
                inQuotes.toggle()
            } else if scalar == ";" && !inQuotes {
                if start < index {
                    segments.append(header[start..<index])
                }
                start = scalars.index(after: index)
            }
            index = scalars.index(after: index)
        }

        if start < header.endIndex {
            segments.append(header[start...])
        }
        return segments
    }
    // swiftlint:enable cyclomatic_complexity

    /// Clean a Content-Type value for storage in MessagePart.
    /// Preserves charset and other relevant params, strips name/filename/boundary.
    static func cleanContentType(_ contentType: String) -> String {
        let components = parameterSegments(of: contentType)
        guard let mimeType = components.first else { return contentType }

        var result = String(mimeType).trimmingCharacters(in: .whitespaces)
        // The RFC 2231 extended spellings are skipped alongside the plain ones,
        // so a name that had to be written as `name*=` is not left in the stored
        // content type for a later re-serialization to append a second copy of.
        let skipParams: Set<String> = ["name", "filename", "boundary", "name*", "filename*"]

        for component in components.dropFirst() {
            let trimmed = removingComments(from: component).trimmingCharacters(in: .whitespaces)
            let paramName = trimmed.split(separator: "=", maxSplits: 1).first
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if !skipParams.contains(paramName) && !isFilenameContinuation(paramName) {
                result += "; \(trimmed)"
            }
        }

        return result
    }

    /// Extract the boundary parameter from a Content-Type header.
    static func extractBoundary(from contentType: String) -> String? {
        return extractHeaderParam(from: contentType, named: "boundary")
    }

    /// Extract a named parameter from a header value (e.g. `boundary="abc"` → `abc`).
    ///
    /// `name` has to be the whole attribute of a parameter, not merely a
    /// substring of the header. The values are sender-chosen, so an unanchored
    /// search lets a sender put an attribute *inside* a legal quoted value and
    /// pick what the library reports: a `filename="evil.exe name*=UTF-8''invoice.pdf"`
    /// is one parameter naming `evil.exe …`, and reading its interior `name*=`
    /// reports `invoice.pdf` instead. Anchoring also keeps `name` and `filename`
    /// distinct attributes, so neither is found inside the other.
    static func extractHeaderParam(from header: String, named name: String) -> String? {
        let attribute = name.lowercased()

        for rawSegment in parameterSegments(of: header) {
            let segment = removingComments(from: rawSegment)
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let candidate = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard candidate == attribute else { continue }

            let value = String(segment[segment.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)

            // A quoted value ends at the first unescaped `"`; an unquoted value
            // already ends at the segment's `;`. The quoted form is read with
            // the same RFC 2045 quoted-pair rule the splitter used to find this
            // segment — a `\` escapes the next character — and unescaped as it
            // is read, so `"a\"b"` yields `a"b`.
            if value.unicodeScalars.first == "\"" {
                return unquote(value)
            }

            return value
        }

        return nil
    }

    /// Read a MIME quoted-string, stopping at the first unescaped `"` and
    /// unescaping each RFC 2045 quoted-pair (`\x` → `x`). `quoted` must begin
    /// with the opening `"`.
    private static func unquote(_ quoted: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = quoted.unicodeScalars
        var index = scalars.index(after: scalars.startIndex) // past the opening quote

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\\" {
                let next = scalars.index(after: index)
                guard next < scalars.endIndex else { break }
                result.append(scalars[next])
                index = scalars.index(after: next)
            } else if scalar == "\"" {
                break
            } else {
                result.append(scalar)
                index = scalars.index(after: index)
            }
        }

        return String(result)
    }

    /// The `filename`/`name` spellings a part's filename can be written as, in
    /// the order they outrank each other. `true` selects the RFC 2231 extended
    /// spelling (`filename*=`), `false` the literal one.
    private static let filenameSpellings: [(attribute: String, extended: Bool)] = [
        ("filename", true),
        ("filename", false),
        ("name", true),
        ("name", false)
    ]

    /// Extract the filename from the headers that can carry one — a part's
    /// Content-Type and Content-Disposition — given in the order the caller
    /// considers them.
    ///
    /// Precedence is by ATTRIBUTE first and spelling second:
    /// `filename*`, `filename`, `name*`, `name`.
    ///
    /// RFC 2183 §2.3 makes `filename` the parameter that names the file; `name`
    /// is the deprecated Content-Type spelling, so `filename` outranks it in
    /// either spelling. RFC 2231 §4 ranks only the two spellings of ONE
    /// attribute — where a sender writes both, the encoded one carries the
    /// characters the literal one could not — so `filename*` outranks
    /// `filename` and `name*` outranks `name`, but neither extended spelling
    /// reaches past the attribute above it. A `filename` that cannot be written
    /// literally is emitted as `filename*=`, and the Content-Type `name` the
    /// same way, so a serializer's own output reads back either way.
    ///
    /// The ranking is resolved across all of the headers together rather than
    /// one header at a time: taking the first header that yields anything would
    /// let a Content-Type `name*` win over a Content-Disposition `filename`,
    /// which is the reverse of RFC 2183 §2.3.
    static func extractFilename(from headers: String...) -> String? {
        for spelling in filenameSpellings {
            for header in headers {
                let value = spelling.extended
                    ? extractExtendedHeaderParam(from: header, named: spelling.attribute)
                    : extractHeaderParam(from: header, named: spelling.attribute)
                if let value {
                    return value
                }
            }
        }

        return nil
    }

    /// Extract an RFC 2231 extended parameter (`name*=charset'language'value`)
    /// and percent-decode its value. Continuations may mix encoded segments
    /// (`name*0*=`, `name*1*=`) with literal ones (`name*2=`). Encoded segments
    /// are percent-decoded individually while literal segments retain `%`
    /// sequences as text, per RFC 2231 §4.1.
    static func extractExtendedHeaderParam(from header: String, named name: String) -> String? {
        let raw: String
        let continuations: [(value: String, encoded: Bool)]
        if let single = extractHeaderParam(from: header, named: name + "*") {
            raw = single
            continuations = []
        } else if let continued = extendedContinuation(from: header, named: name) {
            raw = continued.initial
            continuations = continued.following
        } else {
            return nil
        }

        guard let charsetEnd = raw.firstIndex(of: "'") else { return nil }
        let languageStart = raw.index(after: charsetEnd)
        guard let languageEnd = raw[languageStart...].firstIndex(of: "'") else { return nil }

        let charset = raw[..<charsetEnd].lowercased()
        let encodedValue = raw[raw.index(after: languageEnd)...]
        guard var bytes = percentDecodedBytes(encodedValue) else { return nil }
        guard let continuationBytes = decodedContinuationBytes(continuations) else { return nil }
        bytes.append(contentsOf: continuationBytes)
        return decodeExtendedBytes(bytes, charset: charset)
    }

    private static func decodeExtendedBytes(_ bytes: [UInt8], charset: String) -> String? {
        switch charset {
            case "utf-8", "utf8":
                return String(bytes: bytes, encoding: .utf8)
            case "us-ascii", "ascii":
                guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
                return String(bytes: bytes, encoding: .ascii)
            case "iso-8859-1", "iso8859-1", "latin1":
                return String(bytes: bytes, encoding: .isoLatin1)
            default:
                return nil
        }
    }

    private static func extendedContinuation(
        from header: String,
        named name: String
    ) -> (initial: String, following: [(value: String, encoded: Bool)])? {
        guard let initial = extractHeaderParam(from: header, named: "\(name)*0*") else { return nil }
        var following: [(value: String, encoded: Bool)] = []
        var index = 1

        while true {
            if let encoded = extractHeaderParam(from: header, named: "\(name)*\(index)*") {
                following.append((encoded, true))
            } else if let literal = extractHeaderParam(from: header, named: "\(name)*\(index)") {
                following.append((literal, false))
            } else {
                break
            }
            index += 1
        }
        return (initial, following)
    }

    private static func decodedContinuationBytes(_ continuations: [(value: String, encoded: Bool)]) -> [UInt8]? {
        var bytes: [UInt8] = []
        for continuation in continuations {
            if continuation.encoded {
                guard let decoded = percentDecodedBytes(continuation.value[...]) else { return nil }
                bytes.append(contentsOf: decoded)
            } else {
                bytes.append(contentsOf: continuation.value.utf8)
            }
        }
        return bytes
    }

    // The branches mirror the scanner above while deciding which scalars remain.
    // swiftlint:disable cyclomatic_complexity
    /// Remove RFC 822 comments outside quoted-strings. A single space replaces
    /// each comment so tokens on its two sides cannot be joined accidentally.
    private static func removingComments(from value: Substring) -> String {
        var result = String.UnicodeScalarView()
        var inQuotes = false
        var commentDepth = 0
        var index = value.unicodeScalars.startIndex
        let scalars = value.unicodeScalars

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if (inQuotes || commentDepth > 0) && scalar == "\\" {
                if commentDepth == 0 {
                    result.append(scalar)
                }
                let next = scalars.index(after: index)
                if next < scalars.endIndex {
                    if commentDepth == 0 {
                        result.append(scalars[next])
                    }
                    index = scalars.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if commentDepth > 0 {
                if scalar == "(" {
                    commentDepth += 1
                } else if scalar == ")" {
                    commentDepth -= 1
                    if commentDepth == 0 {
                        result.append(" ")
                    }
                }
            } else if !inQuotes && scalar == "(" {
                commentDepth = 1
            } else {
                result.append(scalar)
                if scalar == "\"" {
                    inQuotes.toggle()
                }
            }
            index = scalars.index(after: index)
        }

        return String(result)
    }
    // swiftlint:enable cyclomatic_complexity

    private static func isFilenameContinuation(_ attribute: String) -> Bool {
        for name in ["name", "filename"] where attribute.hasPrefix(name + "*") {
            var suffix = attribute.dropFirst(name.count + 1)
            if suffix.last == "*" {
                suffix.removeLast()
            }
            if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    private static func percentDecodedBytes(_ value: Substring) -> [UInt8]? {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0

        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2])
                else { return nil }
                result.append(high << 4 | low)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return byte - UInt8(ascii: "0")
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                return byte - UInt8(ascii: "A") + 10
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                return byte - UInt8(ascii: "a") + 10
            default:
                return nil
        }
    }

    /// Extract the disposition type (e.g. "attachment", "inline") from Content-Disposition.
    static func extractDispositionType(from disposition: String?) -> String? {
        guard let disp = disposition else { return nil }
        let parts = disp.split(separator: ";", maxSplits: 1)
        return parts.first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
