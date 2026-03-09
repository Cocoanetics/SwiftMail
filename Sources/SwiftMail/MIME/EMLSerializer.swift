// EMLSerializer.swift
// Serialize a Message back to RFC 822 / EML format

import Foundation

/// Errors that can occur during EML serialization
public enum EMLSerializerError: Error, LocalizedError {
    case missingPartData(Section)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .missingPartData(let section):
            return "Missing data for message part \(section.description)"
        case .encodingFailed:
            return "Failed to encode the message as UTF-8"
        }
    }
}

/// Serializes a ``Message`` to raw RFC 822 / EML bytes.
public struct EMLSerializer {

    // MARK: - Public API

    /// Serialize a ``Message`` to RFC 822 / EML data.
    ///
    /// Part data is written as-is (it should already be in transfer-encoded form,
    /// e.g. base64 for binary attachments).
    ///
    /// - Parameter message: The message to serialize.
    /// - Returns: Raw RFC 822 bytes ready to be written to a `.eml` file or appended to IMAP.
    public static func serialize(_ message: Message) throws -> Data {
        var output = ""

        // Write standard headers
        let header = message.header

        if let from = header.from {
            output += "From: \(from)\r\n"
        }

        if !header.to.isEmpty {
            output += "To: \(header.to.joined(separator: ", "))\r\n"
        }

        if !header.cc.isEmpty {
            output += "Cc: \(header.cc.joined(separator: ", "))\r\n"
        }

        if !header.bcc.isEmpty {
            output += "Bcc: \(header.bcc.joined(separator: ", "))\r\n"
        }

        if let subject = header.subject {
            output += "Subject: \(subject)\r\n"
        }

        if let date = header.date {
            output += "Date: \(formatRFC2822Date(date))\r\n"
        }

        if let messageId = header.messageId {
            output += "Message-ID: \(messageId.description)\r\n"
        }

        output += "MIME-Version: 1.0\r\n"

        // Write additional headers
        if let additional = header.additionalFields {
            for (key, value) in additional.sorted(by: { $0.key < $1.key }) {
                // Capitalize the header name
                let headerName = capitalizeHeaderName(key)
                output += "\(headerName): \(value)\r\n"
            }
        }

        // Determine structure from parts
        let parts = message.parts

        if parts.isEmpty {
            // No parts — write an empty body
            output += "Content-Type: text/plain; charset=UTF-8\r\n"
            output += "\r\n"
        } else if parts.count == 1, let part = parts.first {
            // Single part message
            output += serializePartHeaders(part)
            output += "\r\n"
            if let data = part.data {
                output += stringFromData(data)
            }
        } else {
            // Multipart message — determine the structure
            try serializeMultipart(parts: parts, output: &output)
        }

        guard let data = output.data(using: .utf8) else {
            throw EMLSerializerError.encodingFailed
        }

        return data
    }

    // MARK: - Multipart Serialization

    /// Group parts by their section prefix and serialize as multipart.
    private static func serializeMultipart(parts: [MessagePart], output: inout String) throws {
        // Determine multipart type from content types
        let multipartType = inferMultipartType(from: parts)
        let boundary = generateBoundary()

        output += "Content-Type: multipart/\(multipartType); boundary=\"\(boundary)\"\r\n"
        output += "\r\n"
        output += "This is a multi-part message in MIME format.\r\n"

        // Group parts by top-level section to detect nested multipart
        let grouped = groupPartsByTopLevel(parts)

        for group in grouped {
            output += "\r\n--\(boundary)\r\n"

            if group.count == 1, let part = group.first {
                // Single part in this group
                output += serializePartHeaders(part)
                output += "\r\n"
                if let data = part.data {
                    output += stringFromData(data)
                }
            } else {
                // Nested multipart group
                try serializeMultipart(parts: group, output: &output)
            }
        }

        output += "\r\n--\(boundary)--\r\n"
    }

    /// Serialize headers for a single part.
    private static func serializePartHeaders(_ part: MessagePart) -> String {
        var headers = ""

        var ct = part.contentType
        if let filename = part.filename {
            ct += "; name=\"\(filename)\""
        }
        headers += "Content-Type: \(ct)\r\n"

        if let encoding = part.encoding {
            headers += "Content-Transfer-Encoding: \(encoding)\r\n"
        }

        if let disposition = part.disposition {
            var dispValue = disposition
            if let filename = part.filename {
                dispValue += "; filename=\"\(filename)\""
            }
            headers += "Content-Disposition: \(dispValue)\r\n"
        }

        if let contentId = part.contentId {
            headers += "Content-ID: <\(contentId)>\r\n"
        }

        return headers
    }

    /// Infer the multipart subtype from the parts' content types.
    private static func inferMultipartType(from parts: [MessagePart]) -> String {
        let types = Set(parts.map { $0.contentType.lowercased() })

        // If all parts are text variants → alternative
        if types.allSatisfy({ $0.hasPrefix("text/") }) {
            return "alternative"
        }

        // If any part has a content ID → related
        if parts.contains(where: { $0.contentId != nil }) {
            return "related"
        }

        // Default to mixed
        return "mixed"
    }

    /// Group parts by their top-level section number.
    /// Parts [1], [2] stay separate. Parts [1,1], [1,2] are grouped under [1].
    private static func groupPartsByTopLevel(_ parts: [MessagePart]) -> [[MessagePart]] {
        // If all parts are top-level (single component section), return each as its own group
        let allTopLevel = parts.allSatisfy { $0.section.components.count == 1 }
        if allTopLevel {
            return parts.map { [$0] }
        }

        // Group by first component
        var groups: [Int: [MessagePart]] = [:]
        for part in parts {
            let topLevel = part.section.components.first ?? 1
            groups[topLevel, default: []].append(part)
        }

        return groups.keys.sorted().map { groups[$0]! }
    }

    // MARK: - Helpers

    /// Format a Date as RFC 2822 string.
    private static func formatRFC2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Capitalize a header name (e.g. "x-mailer" → "X-Mailer").
    private static func capitalizeHeaderName(_ name: String) -> String {
        return name.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: "-")
    }

    /// Generate a unique MIME boundary string.
    private static func generateBoundary() -> String {
        return "SwiftMail-Boundary-\(UUID().uuidString)"
    }

    /// Convert Data to a string, preferring UTF-8 then ASCII.
    private static func stringFromData(_ data: Data) -> String {
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}

// MARK: - Message convenience method

public extension Message {
    /// Serialize this message to raw EML / RFC 822 data.
    ///
    /// Part data is written as-is (already transfer-encoded from IMAP FETCH).
    ///
    /// - Returns: Raw RFC 822 bytes.
    /// - Throws: ``EMLSerializerError`` if serialization fails.
    func emlData() throws -> Data {
        return try EMLSerializer.serialize(self)
    }
}
