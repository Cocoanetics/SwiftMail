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

    /// Clean a Content-Type value for storage in MessagePart.
    /// Preserves charset and other relevant params, strips name/filename/boundary.
    static func cleanContentType(_ contentType: String) -> String {
        let components = contentType.split(separator: ";")
        guard let mimeType = components.first else { return contentType }

        var result = String(mimeType).trimmingCharacters(in: .whitespaces)
        let skipParams: Set = ["name", "filename", "boundary"]

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
        extractHeaderParam(from: contentType, named: "boundary")
    }

    /// Extract a named parameter from a header value (e.g. `boundary="abc"` → `abc`).
    static func extractHeaderParam(from header: String, named name: String) -> String? {
        // Case-insensitive search for name=value or name="value"
        let pattern = name + "="
        guard let range = header.range(of: pattern, options: .caseInsensitive) else {
            return nil
        }

        var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Remove quotes
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let endQuote = value.firstIndex(of: "\"") {
                value = String(value[value.startIndex ..< endQuote])
            }
        } else {
            // Unquoted — take until semicolon or end
            if let semi = value.firstIndex(of: ";") {
                value = String(value[value.startIndex ..< semi])
            }
            value = value.trimmingCharacters(in: .whitespaces)
        }

        return value
    }

    /// Extract filename from Content-Type or Content-Disposition header.
    static func extractFilename(from header: String) -> String? {
        // Try filename* (RFC 5987 extended) first, then filename, then name
        if let filename = extractHeaderParam(from: header, named: "filename*") {
            // Strip encoding prefix like "UTF-8''filename.txt"
            if let idx = filename.range(of: "''") {
                let value = String(filename[idx.upperBound...])
                return value.removingPercentEncoding ?? value
            }
            return filename
        }

        return extractHeaderParam(from: header, named: "filename")
            ?? extractHeaderParam(from: header, named: "name")
    }

    /// Extract the disposition type (e.g. "attachment", "inline") from Content-Disposition.
    static func extractDispositionType(from disposition: String?) -> String? {
        guard let disp = disposition else { return nil }
        let parts = disp.split(separator: ";", maxSplits: 1)
        return parts.first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
