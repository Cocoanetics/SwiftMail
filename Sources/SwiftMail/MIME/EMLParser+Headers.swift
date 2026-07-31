// EMLParser+Headers.swift
// Header block splitting, parsing, and MessageInfo construction.

import Foundation

extension EMLParser {

    // MARK: - Header Block Splitting

    /// Split raw entity bytes into header bytes and opaque body bytes.
    ///
    /// The split happens at the first blank line, found in the original bytes:
    /// String indices and character distances are not byte offsets (CRLF is one
    /// `Character` but two bytes, non-ASCII text spans multiple UTF-8 bytes),
    /// and the body need not be valid UTF-8 at all.
    static func splitHeadersAndBody(rawData: Data) -> (headerData: Data, bodyData: Data) {
        let data = Data(rawData)
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        // A body part may begin with a blank line, meaning it has no headers
        // (RFC 2046 §5.1): the leading line break separates empty headers
        // from the body.
        if data.first == lineFeed {
            return (Data(), Data(data.dropFirst()))
        }
        if data.first == carriageReturn, data.dropFirst().first == lineFeed {
            return (Data(), Data(data.dropFirst(2)))
        }

        // The first blank line ends with "\n\n" or "\n\r\n"; the latter also
        // matches "\r\n\r\n" from its first LF. Take the earliest match so a
        // CRLF blank line later in the data cannot shadow an LF one earlier.
        let separators = [Data([lineFeed, lineFeed]), Data([lineFeed, carriageReturn, lineFeed])]
        let candidates = separators.compactMap { data.range(of: $0) }
        guard let separator = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else {
            // No blank line — the entire content is headers.
            return (data, Data())
        }

        // Drop the CR of a CRLF-terminated final header line.
        var headerEnd = separator.lowerBound
        if headerEnd > data.startIndex && data[headerEnd - 1] == carriageReturn {
            headerEnd -= 1
        }
        return (Data(data[data.startIndex..<headerEnd]), Data(data[separator.upperBound...]))
    }

    /// Decode header bytes into a `String` of LF-separated lines.
    ///
    /// Headers are ASCII by specification (RFC 5322), with UTF-8 permitted by
    /// RFC 6532; Latin-1 maps every byte, so the decode is total and malformed
    /// headers can never make parsing fail or lose body bytes. Each line is
    /// decoded independently: a single legacy 8-bit byte in one header must
    /// not flip the whole block to Latin-1 and mangle valid UTF-8 elsewhere.
    static func decodeHeaderBlock(_ headerData: Data) -> String {
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        return headerData
            .split(separator: lineFeed, omittingEmptySubsequences: false)
            .map { line -> String in
                let lineData = Data(line.last == carriageReturn ? line.dropLast() : line)
                return String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1)
                    ?? ""
            }
            .joined(separator: "\n")
    }

    /// Split a header block into lines at CRLF/LF only. RFC 5322 recognizes no
    /// other line breaks: Unicode "newlines" like NEL (which Latin-1 decoding
    /// can produce from raw byte 0x85), VT, FF, or U+2028 are ordinary header
    /// text, and splitting on them would truncate values or let crafted bytes
    /// smuggle in whole headers. The split works on the UTF-8 view because
    /// String searches are grapheme-based and CRLF is a single grapheme — a
    /// search for "\n" inside "\r\n" finds nothing on Linux.
    private static func headerLines(_ block: String) -> [String] {
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        return block.utf8
            .split(separator: lineFeed, omittingEmptySubsequences: false)
            .map { line in
                String(bytes: line.last == carriageReturn ? line.dropLast() : line, encoding: .utf8) ?? ""
            }
    }

    // MARK: - Header Parsing

    /// Parse an RFC 5322 header block into key-value pairs.
    /// Handles continuation lines (lines starting with whitespace).
    /// Keys are lowercased for uniform lookup.
    static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        let lines = headerLines(block)
        for line in lines {
            if line.isEmpty { continue }

            // Continuation line?
            if let first = line.first, first == " " || first == "\t" {
                // Append to current header value (unfolding)
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = line.firstIndex(of: ":") {
                // Save previous header
                if let key = currentKey {
                    headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
                }

                let key = String(line[line.startIndex..<colonIndex]).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...])
                currentKey = key
                currentValue = value
            }
        }

        // Save last header
        if let key = currentKey {
            headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        return headers
    }

    /// Parse all headers preserving multiple values for the same key.
    static func parseAllHeaders(_ block: String) -> [(key: String, value: String)] {
        var headers: [(key: String, value: String)] = []
        var currentKey: String?
        var currentValue: String = ""

        let lines = headerLines(block)
        for line in lines {
            if line.isEmpty { continue }

            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = line.firstIndex(of: ":") {
                if let key = currentKey {
                    headers.append((key: key, value: currentValue.trimmingCharacters(in: .whitespaces)))
                }

                let key = String(line[line.startIndex..<colonIndex]).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...])
                currentKey = key
                currentValue = value
            }
        }

        if let key = currentKey {
            headers.append((key: key, value: currentValue.trimmingCharacters(in: .whitespaces)))
        }

        return headers
    }

    // MARK: - MessageInfo Construction

    static func buildMessageInfo(from headers: [String: String]) -> MessageInfo {
        let from = headers["from"].flatMap { decodeRFC2047($0) } ?? headers["from"]
        let subject = headers["subject"].flatMap { decodeRFC2047($0) } ?? headers["subject"]
        let messageId = headers["message-id"].flatMap { MessageID($0) }

        let to = parseAddressList(headers["to"])
        let cc = parseAddressList(headers["cc"])
        let bcc = parseAddressList(headers["bcc"])

        let date = headers["date"].flatMap { parseRFC2822Date($0) }

        // Collect additional headers (everything except standard ones)
        let standardKeys: Set<String> = [
            "from", "to", "cc", "bcc", "subject", "date", "message-id",
            "content-type", "content-transfer-encoding", "mime-version"
        ]
        var additional: [String: String] = [:]
        for (key, value) in headers where !standardKeys.contains(key) {
            additional[key] = value
        }

        return MessageInfo(
            sequenceNumber: SequenceNumber(0),
            uid: nil,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            date: date,
            messageId: messageId,
            flags: [],
            parts: [],
            additionalFields: additional.isEmpty ? nil : additional
        )
    }
}
