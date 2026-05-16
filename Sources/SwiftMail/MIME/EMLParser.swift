// EMLParser.swift
// Parse raw RFC 822 / EML data into a Message

import Foundation

/// Errors that can occur during EML parsing
public enum EMLParserError: Error, LocalizedError {
    case invalidData
    case missingHeaders
    case malformedHeader(String)

    public var errorDescription: String? {
        switch self {
            case .invalidData:
                "The data is not valid RFC 822 / EML content"
            case .missingHeaders:
                "No headers found in the message"
            case let .malformedHeader(detail):
                "Malformed header: \(detail)"
        }
    }
}

/// Parses raw RFC 822 / EML data into SwiftMail model types.
public enum EMLParser {
    // MARK: - Public API

    /// Parse raw EML data into a ``Message``.
    ///
    /// The returned message uses `SequenceNumber(0)` and `nil` UID because the
    /// data does not originate from an IMAP session.
    ///
    /// - Parameter data: Raw RFC 822 bytes (as obtained from `fetchRawMessage` or an `.eml` file).
    /// - Returns: A fully populated ``Message``.
    public static func parse(_ data: Data) throws -> Message {
        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw EMLParserError.invalidData
        }

        // Split headers and body at the first blank line
        let (headerBlock, bodyData) = splitHeadersAndBody(from: string, rawData: data)

        guard !headerBlock.isEmpty else {
            throw EMLParserError.missingHeaders
        }

        // Parse headers into a dictionary (preserving order isn't critical)
        let headers = parseHeaders(headerBlock)

        // Build MessageInfo
        let info = buildMessageInfo(from: headers)

        // Determine content type of the top-level entity
        let contentType = headers["content-type"] ?? "text/plain"
        let encoding = headers["content-transfer-encoding"]

        // Parse body into parts
        let parts = parseParts(contentType: contentType, encoding: encoding, bodyData: bodyData, sectionPath: [])

        return Message(header: info, parts: parts)
    }
}

// MARK: - Message convenience initializer

public extension Message {
    /// Initialize a Message by parsing raw EML / RFC 822 data.
    ///
    /// - Parameter emlData: The raw message bytes.
    /// - Throws: ``EMLParserError`` if parsing fails.
    init(emlData: Data) throws {
        self = try EMLParser.parse(emlData)
    }
}
