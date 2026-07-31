// EMLParser+Headers.swift
// Header block splitting, parsing, and MessageInfo construction.

import Foundation

extension EMLParser {

    // MARK: - Header Block Splitting

    /// Split raw message bytes into a decoded header block and an opaque body.
    static func splitHeadersAndBody(rawData: Data) throws -> (String, Data) {
        // Find the blank-line separator in the original bytes. String indices
        // and character distances are not byte offsets: CRLF is one Character
        // but two bytes, and non-ASCII header text can span multiple UTF-8 bytes.
        for separator in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
            guard let range = rawData.range(of: separator) else { continue }
            let headerData = rawData[..<range.lowerBound]
            guard let headerBlock = String(bytes: headerData, encoding: .utf8) else {
                throw EMLParserError.invalidData
            }
            return (headerBlock, Data(rawData[range.upperBound...]))
        }

        // No body — entire content is headers
        guard let headerBlock = String(bytes: rawData, encoding: .utf8) else {
            throw EMLParserError.invalidData
        }
        return (headerBlock, Data())
    }

    // MARK: - Header Parsing

    /// Parse an RFC 5322 header block into key-value pairs.
    /// Handles continuation lines (lines starting with whitespace).
    /// Keys are lowercased for uniform lookup.
    static func parseHeaders(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        let lines = block.components(separatedBy: .newlines)
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

        let lines = block.components(separatedBy: .newlines)
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
