// MessageInfo.swift
// Structure to hold email header information

import Foundation

/// Structure to hold email header and part structure information
public struct MessageInfo: Codable, Sendable {
    /// The sequence number of the message
    public var sequenceNumber: SequenceNumber

    /// The UID of the message (if available)
    public var uid: SwiftMail.UID?

    /// The subject of the message
    public var subject: String?

    /// The sender of the message
    public var from: String?

    /// The recipients of the message
    public var to: [String] = []

    /// The CC recipients of the message
    public var cc: [String] = []

    /// The BCC recipients of the message
    public var bcc: [String] = []

    /// The date of the message (from the ENVELOPE Date: header — set by the sender)
    public var date: Date?

    /// The server-side delivery date (IMAP INTERNALDATE — when the server received the message)
    public var internalDate: Date?

    /// The message ID
    public var messageId: MessageID?

    /// The message ID this message replied to (from ENVELOPE In-Reply-To)
    public var inReplyTo: MessageID?

    /// The message IDs referenced by this message (from the References header)
    public var references: [MessageID]?

    /// The flags of the message
    public var flags: [Flag]

    /// The message parts
    public var parts: [MessagePart]

    /// Additional header fields
    public var additionalFields: [String: String]?

    /// The total size of the message in bytes, from `RFC822.SIZE`. Only populated when the fetch
    /// request asks for it.
    public var size: Int?

    private enum CodingKeys: String, CodingKey {
        case sequenceNumber
        case uid
        case subject
        case from
        case to
        case cc
        case bcc
        case date
        case internalDate
        case messageId
        case inReplyTo
        case references
        case flags
        case parts
        case additionalFields
        case size
    }

    /// Initialize a new email header
    /// - Parameters:
    ///   - sequenceNumber: The sequence number of the message
    ///   - uid: The UID of the message (if available)
    ///   - subject: The subject of the message
    ///   - from: The sender of the message
    ///   - to: The recipients of the message
    ///   - cc: The CC recipients of the message
    ///   - date: The date of the message (envelope Date: header)
    ///   - internalDate: The server-side delivery date (IMAP INTERNALDATE)
    ///   - messageId: The message ID
    ///   - flags: The flags of the message
    ///   - parts: The message parts
    ///   - additionalFields: Additional header fields
    ///   - size: The total size of the message in bytes (RFC822.SIZE)
    public init(
        sequenceNumber: SequenceNumber,
        uid: SwiftMail.UID? = nil,
        subject: String? = nil,
        from: String? = nil,
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        date: Date? = nil,
        internalDate: Date? = nil,
        messageId: MessageID? = nil,
        inReplyTo: MessageID? = nil,
        references: [MessageID]? = nil,
        flags: [Flag] = [],
        parts: [MessagePart] = [],
        additionalFields: [String: String]? = nil,
        size: Int? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.internalDate = internalDate
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.flags = flags
        self.parts = parts
        self.additionalFields = additionalFields
        self.size = size
    }
}

public extension MessageInfo {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            sequenceNumber: try container.decode(SequenceNumber.self, forKey: .sequenceNumber),
            uid: try container.decodeIfPresent(UID.self, forKey: .uid),
            subject: try container.decodeIfPresent(String.self, forKey: .subject),
            from: try container.decodeIfPresent(String.self, forKey: .from),
            to: try container.decodeIfPresent([String].self, forKey: .to) ?? [],
            cc: try container.decodeIfPresent([String].self, forKey: .cc) ?? [],
            bcc: try container.decodeIfPresent([String].self, forKey: .bcc) ?? [],
            date: try container.decodeIfPresent(Date.self, forKey: .date),
            internalDate: try container.decodeIfPresent(Date.self, forKey: .internalDate),
            messageId: try Self.decodeMessageID(from: container, forKey: .messageId),
            inReplyTo: try Self.decodeMessageID(from: container, forKey: .inReplyTo),
            references: try Self.decodeReferences(from: container),
            flags: try container.decodeIfPresent([Flag].self, forKey: .flags) ?? [],
            parts: try container.decodeIfPresent([MessagePart].self, forKey: .parts) ?? [],
            additionalFields: try container.decodeIfPresent([String: String].self, forKey: .additionalFields),
            size: try container.decodeIfPresent(Int.self, forKey: .size)
        )
    }

    /// Decode a Message-ID field that may have been encoded either as a structured
    /// ``MessageID`` (current) or as a legacy bare string. Returns `nil` if absent
    /// or unparseable.
    private static func decodeMessageID(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> MessageID? {
        if let structured = try? container.decodeIfPresent(MessageID.self, forKey: key) {
            return structured
        }
        if let legacy = try container.decodeIfPresent(String.self, forKey: key) {
            return MessageID(legacy)
        }
        return nil
    }

    /// Decode `References` which may be `[MessageID]` (current), `[String]`
    /// (intermediate), or a space-separated legacy `String`.
    private static func decodeReferences(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [MessageID]? {
        if let refs = try? container.decodeIfPresent([MessageID].self, forKey: .references) {
            return refs
        }
        if let strings = try? container.decodeIfPresent([String].self, forKey: .references) {
            return strings.compactMap { MessageID($0) }
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .references) {
            let parsed = FetchMessageInfoHandler.parseMessageIDs(from: raw)
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }
}
