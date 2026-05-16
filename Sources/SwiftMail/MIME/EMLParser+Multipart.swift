// EMLParser+Multipart.swift
// MIME body parsing — single part and multipart bodies.

import Foundation

extension EMLParser {
    // MARK: - MIME Body Parsing

    /// Parse the body into MessagePart(s) based on Content-Type.
    static func parseParts(
        contentType: String,
        encoding: String?,
        bodyData: Data,
        sectionPath: [Int]
    ) -> [MessagePart] {
        let lowercased = contentType.lowercased()

        if lowercased.hasPrefix("multipart/") {
            return parseMultipart(contentType: contentType, bodyData: bodyData, sectionPath: sectionPath)
        } else {
            // Single part
            let section = sectionPath.isEmpty ? [1] : sectionPath
            let disposition = extractHeaderParam(from: contentType, named: "disposition")
            let filename = extractFilename(from: contentType)

            let part = MessagePart(
                section: Section(section),
                contentType: cleanContentType(contentType),
                disposition: disposition,
                encoding: encoding,
                filename: filename,
                contentId: nil,
                data: bodyData
            )
            return [part]
        }
    }

    /// Parse a multipart body, splitting by boundary.
    static func parseMultipart(contentType: String, bodyData: Data, sectionPath: [Int]) -> [MessagePart] {
        guard let boundary = extractBoundary(from: contentType) else {
            // Can't parse without boundary — treat as opaque
            let section = sectionPath.isEmpty ? [1] : sectionPath
            return [MessagePart(
                section: Section(section),
                contentType: extractMIMEType(from: contentType),
                data: bodyData
            )]
        }

        let utf8Body = String(data: bodyData, encoding: .utf8)
        let asciiBody = String(data: bodyData, encoding: .ascii)
        guard let bodyString = utf8Body ?? asciiBody else {
            return []
        }

        let rawParts = splitMultipartByBoundary(bodyString: bodyString, boundary: boundary)
        return rawParts.enumerated().flatMap { index, rawPart -> [MessagePart] in
            buildMultipartChild(rawPart: rawPart, index: index, sectionPath: sectionPath)
        }
    }

    /// Split a multipart body string into raw part strings using the boundary
    /// delimiter. Returns an array of raw (header+body) part strings.
    static func splitMultipartByBoundary(bodyString: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        var rawParts: [String] = []
        var searchStart = bodyString.startIndex

        while searchStart < bodyString.endIndex {
            guard let delimRange = bodyString.range(of: delimiter, range: searchStart ..< bodyString.endIndex) else {
                break
            }

            // Check if this is the end delimiter
            if isMultipartEndDelimiter(bodyString: bodyString, after: delimRange.upperBound) {
                break
            }

            // Find the start of part content (skip past delimiter + line ending)
            let contentStart = skipPastDelimiterLineEnding(
                bodyString: bodyString,
                from: delimRange.upperBound
            )

            // Find the next boundary to determine the end of this part
            if let nextDelimRange = bodyString.range(of: delimiter, range: contentStart ..< bodyString.endIndex) {
                let contentEnd = trimmedPartEnd(
                    bodyString: bodyString,
                    contentStart: contentStart,
                    delimiterStart: nextDelimRange.lowerBound
                )
                rawParts.append(String(bodyString[contentStart ..< contentEnd]))
                searchStart = nextDelimRange.lowerBound
            } else {
                // No more boundaries — take the rest
                let remainder = String(bodyString[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                rawParts.append(remainder)
                break
            }
        }

        return rawParts
    }

    /// Return `true` if the characters immediately after a boundary match are
    /// `"--"`, signalling the multipart end delimiter.
    private static func isMultipartEndDelimiter(bodyString: String, after index: String.Index) -> Bool {
        guard index < bodyString.endIndex else { return false }
        return bodyString[index...].hasPrefix("--")
    }

    /// Skip past any CR/LF characters following a boundary delimiter so the
    /// caller can read the part's header block.
    private static func skipPastDelimiterLineEnding(
        bodyString: String,
        from start: String.Index
    ) -> String.Index {
        var contentStart = start
        if contentStart < bodyString.endIndex, bodyString[contentStart] == "\r" {
            contentStart = bodyString.index(after: contentStart)
        }
        if contentStart < bodyString.endIndex, bodyString[contentStart] == "\n" {
            contentStart = bodyString.index(after: contentStart)
        }
        return contentStart
    }

    /// Trim the trailing CR/LF that precedes the next boundary delimiter so the
    /// returned slice contains only the part body.
    private static func trimmedPartEnd(
        bodyString: String,
        contentStart: String.Index,
        delimiterStart: String.Index
    ) -> String.Index {
        var contentEnd = delimiterStart
        guard contentEnd > contentStart else { return contentEnd }

        let beforeEnd = bodyString.index(before: contentEnd)
        guard bodyString[beforeEnd] == "\n" else { return contentEnd }
        contentEnd = beforeEnd

        guard contentEnd > contentStart else { return contentEnd }
        let beforeLF = bodyString.index(before: contentEnd)
        if bodyString[beforeLF] == "\r" {
            contentEnd = beforeLF
        }
        return contentEnd
    }

    /// Build the `MessagePart` value(s) for a single raw multipart child string.
    /// Recursively descends into nested multipart parts.
    static func buildMultipartChild(
        rawPart: String,
        index: Int,
        sectionPath: [Int]
    ) -> [MessagePart] {
        let partNumber = index + 1
        let childPath = sectionPath.isEmpty ? [partNumber] : sectionPath + [partNumber]

        let partData = Data(rawPart.utf8)
        let (partHeaders, partBody) = splitHeadersAndBody(from: rawPart, rawData: partData)
        let headers = parseHeaders(partHeaders)

        let partContentType = headers["content-type"] ?? "text/plain"
        let partEncoding = headers["content-transfer-encoding"]
        let partDisposition = headers["content-disposition"]
        let partContentId = headers["content-id"]?.trimmingCharacters(in: .init(charactersIn: "<>"))

        let filename = extractFilename(from: partContentType) ?? extractFilename(from: partDisposition ?? "")

        if partContentType.lowercased().hasPrefix("multipart/") {
            // Recursive multipart
            return parseMultipart(contentType: partContentType, bodyData: partBody, sectionPath: childPath)
        }

        let part = MessagePart(
            section: Section(childPath),
            contentType: cleanContentType(partContentType),
            disposition: extractDispositionType(from: partDisposition),
            encoding: partEncoding?.trimmingCharacters(in: .whitespaces),
            filename: filename.flatMap { decodeRFC2047($0) },
            contentId: partContentId,
            data: partBody
        )
        return [part]
    }
}
