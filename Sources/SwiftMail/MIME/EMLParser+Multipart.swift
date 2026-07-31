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

    /// Split a multipart body into opaque byte slices using valid boundary lines.
    /// The preamble, epilogue, and CRLF framing around each part are discarded.
    static func splitMultipartByBoundary(bodyData: Data, boundary: String) -> [Data] {
        let marker = Data("--\(boundary)".utf8)
        guard !marker.isEmpty else { return [] }

        var rawParts: [Data] = []
        var currentPartStart: Data.Index?
        var searchStart = bodyData.startIndex

        while let delimiter = nextMultipartDelimiter(
            in: bodyData,
            marker: marker,
            startingAt: searchStart
        ) {
            if let partStart = currentPartStart {
                let partEnd = trimLineEnding(
                    before: delimiter.range.lowerBound,
                    notBefore: partStart,
                    in: bodyData
                )
                rawParts.append(Data(bodyData[partStart..<partEnd]))
            }

            if delimiter.isClosing {
                currentPartStart = nil
                break
            }

            currentPartStart = delimiter.lineEnd
            searchStart = delimiter.lineEnd
        }

        if let partStart = currentPartStart {
            rawParts.append(Data(bodyData[partStart...]))
        }

        return rawParts
    }

    private struct MultipartDelimiter {
        let range: Range<Data.Index>
        let lineEnd: Data.Index
        let isClosing: Bool
    }

    /// Locate the next delimiter line without decoding any MIME body bytes.
    private static func nextMultipartDelimiter(
        in data: Data,
        marker: Data,
        startingAt start: Data.Index
    ) -> MultipartDelimiter? {
        var searchStart = start

        while searchStart < data.endIndex,
              let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            guard isStartOfLine(range.lowerBound, in: data),
                  let delimiter = multipartDelimiter(in: data, markerRange: range) else {
                searchStart = data.index(after: range.lowerBound)
                continue
            }
            return delimiter
        }

        return nil
    }

    private static func isStartOfLine(_ index: Data.Index, in data: Data) -> Bool {
        index == data.startIndex || data[data.index(before: index)] == 0x0A
    }

    private static func multipartDelimiter(
        in data: Data,
        markerRange: Range<Data.Index>
    ) -> MultipartDelimiter? {
        var cursor = markerRange.upperBound
        let isClosing = hasBytePair(0x2D, 0x2D, in: data, at: cursor)
        if isClosing {
            cursor = data.index(cursor, offsetBy: 2)
        }

        while cursor < data.endIndex && (data[cursor] == 0x20 || data[cursor] == 0x09) {
            cursor = data.index(after: cursor)
        }

        let lineEnd: Data.Index
        if cursor == data.endIndex {
            lineEnd = cursor
        } else if data[cursor] == 0x0A {
            lineEnd = data.index(after: cursor)
        } else if hasBytePair(0x0D, 0x0A, in: data, at: cursor) {
            lineEnd = data.index(cursor, offsetBy: 2)
        } else {
            return nil
        }

        return MultipartDelimiter(range: markerRange, lineEnd: lineEnd, isClosing: isClosing)
    }

    private static func hasBytePair(
        _ first: UInt8,
        _ second: UInt8,
        in data: Data,
        at start: Data.Index
    ) -> Bool {
        guard start < data.endIndex else { return false }
        let next = data.index(after: start)
        return next < data.endIndex && data[start] == first && data[next] == second
    }

    private static func trimLineEnding(
        before end: Data.Index,
        notBefore start: Data.Index,
        in data: Data
    ) -> Data.Index {
        var trimmedEnd = end
        guard trimmedEnd > start else { return trimmedEnd }

        let previous = data.index(before: trimmedEnd)
        guard data[previous] == 0x0A else { return trimmedEnd }
        trimmedEnd = previous

        if trimmedEnd > start {
            let beforeLF = data.index(before: trimmedEnd)
            if data[beforeLF] == 0x0D {
                trimmedEnd = beforeLF
            }
        }
        return trimmedEnd
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

        guard let (partHeaders, partBody) = try? splitHeadersAndBody(rawData: rawPart) else {
            return []
        }
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
