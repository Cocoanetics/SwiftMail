// MessagePart.swift
// Structure to hold information about a message part

import Foundation
import SwiftCross

/// A part of an email message
public struct MessagePart: Sendable {
    /// The section number (e.g., [1, 2, 3] represents "1.2.3")
    public let section: Section

    /// The content type of the part (e.g., "text/html", "image/jpeg")
    public let contentType: String

    /// The content disposition (e.g., "inline", "attachment")
    public let disposition: String?

    /// The content transfer encoding (e.g., "base64", "quoted-printable")
    public let encoding: String?

    /// The filename of the part (if any)
    public let filename: String?

    /// The content ID of the part (if any)
    public let contentId: String?

    /// The size of the part body in octets, as reported by BODYSTRUCTURE.
    /// Zero is a valid size (an empty part); `nil` means the size is unknown
    /// because the part was not built from a BODYSTRUCTURE response.
    public let size: Int?

    /// The content data (if any)
    public var data: Data?

    /// For message/rfc822 parts: metadata from the embedded message's envelope.
    /// Populated with subject, from, to, cc, date from the IMAP BODYSTRUCTURE envelope.
    /// Other MessageInfo fields (uid, flags, parts, etc.) are defaults.
    public let embeddedMessageInfo: MessageInfo?

    /// Creates a new message part
    /// - Parameters:
    ///   - section: The section number (e.g., [1, 2, 3] represents "1.2.3")
    ///   - contentType: The content type (e.g., "text/html", "image/jpeg")
    ///   - disposition: The content disposition (e.g., "inline", "attachment")
    ///   - encoding: The content transfer encoding (e.g., "base64", "quoted-printable")
    ///   - filename: The filename (if any)
    ///   - contentId: The content ID
    ///   - size: The body size in octets from BODYSTRUCTURE (optional)
    ///   - data: The content data (optional)
    ///   - embeddedMessageInfo: Envelope headers for message/rfc822 parts (optional)
    public init(
        section: Section,
        contentType: String,
        disposition: String? = nil,
        encoding: String? = nil,
        filename: String? = nil,
        contentId: String? = nil,
        size: Int? = nil,
        data: Data? = nil,
        embeddedMessageInfo: MessageInfo? = nil
    ) {
        self.section = section
        self.contentType = contentType
        self.disposition = disposition
        self.encoding = encoding
        self.filename = filename
        self.contentId = contentId
        self.size = size
        self.data = data
        self.embeddedMessageInfo = embeddedMessageInfo
    }

    /// Initialize a new message part with a dot-separated string section number
    /// - Parameters:
    ///   - sectionString: The section number as a dot-separated string (e.g., "1.2.3")
    ///   - contentType: The content type (e.g., "text/html", "image/jpeg")
    ///   - disposition: The content disposition
    ///   - filename: The filename
    ///   - contentId: The content ID
    ///   - data: The content data (optional)
    public init(
        sectionString: String,
        contentType: String,
        disposition: String? = nil,
        encoding: String? = nil,
        filename: String? = nil,
        contentId: String? = nil,
        size: Int? = nil,
        data: Data? = nil,
        embeddedMessageInfo: MessageInfo? = nil
    ) {
        self.section = Section(sectionString)
        self.contentType = contentType
        self.disposition = disposition
        self.encoding = encoding
        self.filename = filename
        self.contentId = contentId
        self.size = size
        self.data = data
        self.embeddedMessageInfo = embeddedMessageInfo
    }

    /// Get a suggested filename for the part
    /// - Returns: A filename based on part information
    public var suggestedFilename: String {
        if let filename = self.filename, !filename.isEmpty {
            // Use the original filename if available
            return filename.sanitizedFileName()
        } else {
            // Create a filename based on section number and content type.
            // Strip parameters (e.g., "; charset=utf-8") before MIME lookup.
            let baseType = contentType.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces) ?? contentType
            let fileExtension = UTType(mimeType: baseType)?.preferredFilenameExtension ?? "dat"

            return "part_\(section.description.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
        }
    }

    /// The charset declared in the Content-Type header (if present), read as a
    /// MIME parameter: the name in any case, a quoted value unquoted. A content
    /// type taken from a part's own header carries the value as the sender wrote
    /// it, and `charset="iso-2022-jp"` is as common there as the bare form.
    public var declaredCharset: String? {
        guard let charset = contentTypeParameter(named: "charset")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !charset.isEmpty else {
            return nil
        }
        return charset
    }

    /// The value of the Content-Type parameter `name`, read as a MIME parameter:
    /// the name in any case, a quoted value unquoted, comments removed. Nil when
    /// the content type has no such parameter. A text part's RFC 3676 `format`
    /// and `delsp` say how its text is read, as its charset says how its bytes are.
    ///
    /// An RFC 2231 extended value (`charset*=utf-8''gbk`, or numbered
    /// continuations) is read first; when it is absent or cannot be decoded, the
    /// plain spelling is read, as for filenames.
    public func contentTypeParameter(named name: String) -> String? {
        EMLParser.extractExtendedHeaderParam(from: contentType, named: name)
            ?? EMLParser.extractHeaderParam(from: contentType, named: name)
    }

    /// The text content of the part
    /// - Returns: The text content, or nil if can't be decoded
    public var textContent: String? {
        guard let transferDecodedData = decodedData() else {
            return nil
        }

        // Decode bytes exactly once, preferring the declared charset.
        if let declaredCharset {
            let encoding = String.Encoding(mimeCharset: declaredCharset) ?? .utf8
            if let text = String(data: transferDecodedData, encoding: encoding) {
                return text
            }
        }

        // Fallbacks for malformed/unknown charset labels in real-world mail.
        if let text = String.iso2022JP(transferDecodedData) {
            return text
        }
        if let text = String(data: transferDecodedData, encoding: .utf8) {
            return text
        }
        if let text = String.plausibleJapanese(transferDecodedData) {
            return text
        }
        let fallbackEncodings: [String.Encoding] = [.windowsCP1252, .isoLatin1, .ascii]
        for fallback in fallbackEncodings {
            if let text = String(data: transferDecodedData, encoding: fallback) {
                return text
            }
        }

        return nil
    }

    /// Decode the part content using appropriate decoding based on content type and encoding
    /// - Returns: The decoded data, or nil if no data is available
    public func decodedData() -> Data? {
        guard let data = data else {
            return nil
        }

        return data.decoded(for: self)
    }
}

// MARK: - Codable Implementation
extension MessagePart: Codable {
    private enum CodingKeys: String, CodingKey {
        case section, contentType, disposition, encoding, filename, contentId, size, data, embeddedMessageInfo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(section, forKey: .section)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(disposition, forKey: .disposition)
        try container.encodeIfPresent(encoding, forKey: .encoding)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(contentId, forKey: .contentId)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(embeddedMessageInfo, forKey: .embeddedMessageInfo)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        section = try container.decode(Section.self, forKey: .section)
        contentType = try container.decode(String.self, forKey: .contentType)
        disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        contentId = try container.decodeIfPresent(String.self, forKey: .contentId)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        embeddedMessageInfo = try container.decodeIfPresent(MessageInfo.self, forKey: .embeddedMessageInfo)
    }
}
