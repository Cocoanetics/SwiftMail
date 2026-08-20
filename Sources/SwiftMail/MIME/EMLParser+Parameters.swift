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

    /// Split a header field body into its top-level `;`-separated segments.
    ///
    /// A `;` between the quotes of a parameter value is part of that value —
    /// `name="a;b.pdf"` is one parameter, not two — so splitting has to know
    /// where the quotes are, or a value the sender chooses decides where the
    /// parameters are.
    ///
    /// An RFC 2045 quoted-pair inside the quotes — a `\` before any character —
    /// is honored: the escaped character stands for itself, so a `\"` does not
    /// close the value. The quoted-string reader in
    /// ``extractHeaderParam(from:named:)`` applies the identical rule, so the
    /// two agree on where a value ends; if they did not, a parameter could be
    /// found in a segment whose value the reader then runs past.
    static func parameterSegments(of header: String) -> [Substring] {
        var segments: [Substring] = []
        var start = header.startIndex
        var index = header.startIndex
        var inQuotes = false

        while index < header.endIndex {
            let character = header[index]
            if inQuotes && character == "\\" {
                // Quoted-pair: the next character is literal, so it can neither
                // close the quote nor separate parameters. Skip both here, as
                // the value reader unescapes them, or the two disagree on where
                // the quoted value ends.
                index = header.index(after: index)
                if index < header.endIndex {
                    index = header.index(after: index)
                }
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ";" && !inQuotes {
                if start < index {
                    segments.append(header[start..<index])
                }
                start = header.index(after: index)
            }
            index = header.index(after: index)
        }

        if start < header.endIndex {
            segments.append(header[start...])
        }
        return segments
    }

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
            let trimmed = String(component).trimmingCharacters(in: .whitespaces)
            let paramName = trimmed.split(separator: "=", maxSplits: 1).first
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if !skipParams.contains(paramName) {
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

        for segment in parameterSegments(of: header) {
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
            if value.hasPrefix("\"") {
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
        var result = ""
        var index = quoted.index(after: quoted.startIndex) // past the opening quote

        while index < quoted.endIndex {
            let character = quoted[index]
            if character == "\\" {
                let next = quoted.index(after: index)
                guard next < quoted.endIndex else { break }
                result.append(quoted[next])
                index = quoted.index(after: next)
            } else if character == "\"" {
                break
            } else {
                result.append(character)
                index = quoted.index(after: index)
            }
        }

        return result
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
    /// and percent-decode its value. A single segment only — continuations
    /// (`name*0*=`) are not read.
    static func extractExtendedHeaderParam(from header: String, named name: String) -> String? {
        guard let raw = extractHeaderParam(from: header, named: name + "*") else { return nil }
        // Strip the encoding prefix, e.g. "UTF-8''filename.txt".
        guard let separator = raw.range(of: "''") else { return raw }
        let value = String(raw[separator.upperBound...])
        return value.removingPercentEncoding ?? value
    }

    /// Extract the disposition type (e.g. "attachment", "inline") from Content-Disposition.
    static func extractDispositionType(from disposition: String?) -> String? {
        guard let disp = disposition else { return nil }
        let parts = disp.split(separator: ";", maxSplits: 1)
        return parts.first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
