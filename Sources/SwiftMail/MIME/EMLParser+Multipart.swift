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

        let rawParts = splitMultipartByBoundary(bodyData: bodyData, boundary: boundary)
        return rawParts.enumerated().flatMap { index, rawPart -> [MessagePart] in
            buildMultipartChild(rawPart: rawPart, index: index, sectionPath: sectionPath)
        }
    }

    /// Split a multipart body into raw (header+body) part byte blocks using the
    /// boundary delimiter, per RFC 2046 §5.1.1.
    ///
    /// All matching happens on bytes: part content is not required to be valid
    /// UTF-8, so it must never round-trip through `String`. A delimiter only
    /// counts when it starts a line and its line contains nothing after the
    /// boundary but optional transport padding — a part whose *content* merely
    /// mentions "--boundary" mid-line or as a prefix of a longer token is not
    /// split. The line break preceding a delimiter belongs to the delimiter,
    /// not to the part. The preamble (before the first delimiter) and epilogue
    /// (after the close delimiter) are discarded.
    static func splitMultipartByBoundary(bodyData: Data, boundary: String) -> [Data] {
        let data = Data(bodyData)
        let delimiter = Data("--\(boundary)".utf8)
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var rawParts: [Data] = []
        var partStart: Data.Index?
        var searchIndex = data.startIndex

        while searchIndex < data.endIndex,
              let match = data.range(of: delimiter, in: searchIndex..<data.endIndex) {
            // A delimiter only counts at the start of a line whose remainder
            // is a valid delimiter-line tail; otherwise the match is ordinary
            // part content.
            let atLineStart = match.lowerBound == data.startIndex || data[match.lowerBound - 1] == lineFeed
            guard atLineStart, let line = parseDelimiterLineTail(in: data, after: match.upperBound) else {
                searchIndex = match.lowerBound + 1
                continue
            }

            // Close out the running part: its content ends before the line
            // break that precedes this delimiter.
            if let start = partStart {
                rawParts.append(Data(data[start..<partEnd(in: data, start: start, delimiterStart: match.lowerBound)]))
            }

            if line.isClose {
                return rawParts
            }
            partStart = line.contentStart
            searchIndex = line.contentStart
        }

        // Missing close delimiter — take the remainder as the final part.
        if let start = partStart {
            var trimmedEnd = data.endIndex
            while trimmedEnd > start && (data[trimmedEnd - 1] == lineFeed || data[trimmedEnd - 1] == carriageReturn) {
                trimmedEnd -= 1
            }
            rawParts.append(Data(data[start..<trimmedEnd]))
        }
        return rawParts
    }

    /// Validate what follows a matched boundary: an optional `--` (marking the
    /// close delimiter), optional transport padding, then CRLF, LF, or end of
    /// data. Returns `nil` when something else follows — the boundary was a
    /// prefix of ordinary text, not a delimiter line.
    private static func parseDelimiterLineTail(
        in data: Data,
        after boundaryEnd: Data.Index
    ) -> (contentStart: Data.Index, isClose: Bool)? {
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        let dash: UInt8 = 0x2D
        let space: UInt8 = 0x20
        let tab: UInt8 = 0x09

        var cursor = boundaryEnd
        let isClose = cursor + 1 < data.endIndex && data[cursor] == dash && data[cursor + 1] == dash
        if isClose {
            cursor += 2
        }

        while cursor < data.endIndex && (data[cursor] == space || data[cursor] == tab) {
            cursor += 1
        }

        if cursor < data.endIndex && data[cursor] == carriageReturn {
            cursor += 1
        }
        if cursor < data.endIndex {
            guard data[cursor] == lineFeed else {
                return nil
            }
            cursor += 1
        }
        return (cursor, isClose)
    }

    /// The content of a part ends before the line break that precedes the next
    /// boundary delimiter; that line break belongs to the delimiter.
    private static func partEnd(
        in data: Data,
        start: Data.Index,
        delimiterStart: Data.Index
    ) -> Data.Index {
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        var end = delimiterStart
        if end > start && data[end - 1] == lineFeed {
            end -= 1
            if end > start && data[end - 1] == carriageReturn {
                end -= 1
            }
        }
        return end
    }

    /// Build the `MessagePart` value(s) for a single raw multipart child.
    /// Recursively descends into nested multipart parts.
    static func buildMultipartChild(
        rawPart: Data,
        index: Int,
        sectionPath: [Int]
    ) -> [MessagePart] {
        let partNumber = index + 1
        let childPath = sectionPath.isEmpty ? [partNumber] : sectionPath + [partNumber]

        let (partHeaderData, partBody) = splitHeadersAndBody(rawData: rawPart)
        let headers = parseHeaders(decodeHeaderBlock(partHeaderData))

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
