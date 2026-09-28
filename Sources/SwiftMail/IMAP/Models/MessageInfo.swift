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

    /// The authors of the message, from the `From` field. Usually one
    /// mailbox; RFC 5322 allows several. ``from`` is the same as text.
    public var fromAddresses: [AddressListEntry] = []

    /// Where replies should go, from the `Reply-To` field. ``replyTo`` is the
    /// same as text.
    public var replyToAddresses: [AddressListEntry] = []

    /// The recipients, from the `To` field. ``to`` is the same as text.
    public var toAddresses: [AddressListEntry] = []

    /// The CC recipients, from the `Cc` field. ``cc`` is the same as text.
    public var ccAddresses: [AddressListEntry] = []

    /// The BCC recipients, from the `Bcc` field. ``bcc`` is the same as text.
    public var bccAddresses: [AddressListEntry] = []

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

    /// Additional header fields (last-value-wins dictionary, source-compatible).
    public var additionalFields: [String: String]?

    /// Additional header fields in wire order, preserving repeated field instances.
    public var additionalHeaderFields: [HeaderField]?

    /// The total size of the message in bytes, from `RFC822.SIZE`. Only populated when the fetch
    /// request asks for it.
    public var size: Int?

    private enum CodingKeys: String, CodingKey {
        case sequenceNumber
        case uid
        case subject
        case fromAddresses
        case replyToAddresses
        case toAddresses
        case ccAddresses
        case bccAddresses
        case from
        case replyTo
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
        case additionalHeaderFields
        case size
    }

    /// Initialize a new email header
    /// - Parameters:
    ///   - sequenceNumber: The sequence number of the message
    ///   - uid: The UID of the message (if available)
    ///   - subject: The subject of the message
    ///   - from: The sender of the message, as address text read into ``fromAddresses``
    ///   - replyTo: The addresses to which replies should be sent, read into ``replyToAddresses``
    ///   - to: The recipients of the message, read into ``toAddresses``
    ///   - cc: The CC recipients of the message, read into ``ccAddresses``
    ///   - bcc: The BCC recipients of the message, read into ``bccAddresses``
    ///   - date: The date of the message (envelope Date: header)
    ///   - internalDate: The server-side delivery date (IMAP INTERNALDATE)
    ///   - messageId: The message ID
    ///   - flags: The flags of the message
    ///   - parts: The message parts
    ///   - additionalFields: Additional header fields (last-value-wins dictionary)
    ///   - additionalHeaderFields: Additional header fields in wire order, preserving repeated instances
    ///   - size: The total size of the message in bytes (RFC822.SIZE)
    public init(
        sequenceNumber: SequenceNumber,
        uid: SwiftMail.UID? = nil,
        subject: String? = nil,
        from: String? = nil,
        replyTo: [String] = [],
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
        additionalHeaderFields: [HeaderField]? = nil,
        size: Int? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        self.subject = subject
        self.date = date
        self.internalDate = internalDate
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.flags = flags
        self.parts = parts
        self.additionalFields = additionalFields
        self.additionalHeaderFields = additionalHeaderFields
        self.size = size
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }
}

public extension MessageInfo {
    /// Decodes a message info. Addresses come from the structured keys, or, in
    /// data encoded before they existed, from the address text, read once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.init(
            sequenceNumber: try container.decode(SequenceNumber.self, forKey: .sequenceNumber),
            uid: try container.decodeIfPresent(UID.self, forKey: .uid),
            subject: try container.decodeIfPresent(String.self, forKey: .subject),
            date: try container.decodeIfPresent(Date.self, forKey: .date),
            internalDate: try container.decodeIfPresent(Date.self, forKey: .internalDate),
            messageId: try Self.decodeMessageID(from: container, forKey: .messageId),
            inReplyTo: try Self.decodeMessageID(from: container, forKey: .inReplyTo),
            references: try Self.decodeReferences(from: container),
            flags: try container.decodeIfPresent([Flag].self, forKey: .flags) ?? [],
            parts: try container.decodeIfPresent([MessagePart].self, forKey: .parts) ?? [],
            additionalFields: try container.decodeIfPresent([String: String].self, forKey: .additionalFields),
            additionalHeaderFields: try container.decodeIfPresent([HeaderField].self, forKey: .additionalHeaderFields),
            size: try container.decodeIfPresent(Int.self, forKey: .size)
        )
        fromAddresses = try Self.decodeAddresses(from: container, forKey: .fromAddresses, legacyKey: .from)
        replyToAddresses = try Self.decodeAddresses(from: container, forKey: .replyToAddresses, legacyKey: .replyTo)
        toAddresses = try Self.decodeAddresses(from: container, forKey: .toAddresses, legacyKey: .to)
        ccAddresses = try Self.decodeAddresses(from: container, forKey: .ccAddresses, legacyKey: .cc)
        bccAddresses = try Self.decodeAddresses(from: container, forKey: .bccAddresses, legacyKey: .bcc)
    }

    /// Encodes the structured addresses, and their text under the keys older
    /// versions of SwiftMail read.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequenceNumber, forKey: .sequenceNumber)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encode(fromAddresses, forKey: .fromAddresses)
        try container.encode(replyToAddresses, forKey: .replyToAddresses)
        try container.encode(toAddresses, forKey: .toAddresses)
        try container.encode(ccAddresses, forKey: .ccAddresses)
        try container.encode(bccAddresses, forKey: .bccAddresses)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(bcc, forKey: .bcc)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(internalDate, forKey: .internalDate)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
        try container.encodeIfPresent(references, forKey: .references)
        try container.encode(flags, forKey: .flags)
        try container.encode(parts, forKey: .parts)
        try container.encodeIfPresent(additionalFields, forKey: .additionalFields)
        try container.encodeIfPresent(additionalHeaderFields, forKey: .additionalHeaderFields)
        try container.encodeIfPresent(size, forKey: .size)
    }

    /// Decode an address field from its structured key, or else from the text
    /// under `legacyKey`: one string (`from`) or one per entry (the others).
    private static func decodeAddresses(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        legacyKey: CodingKeys
    ) throws -> [AddressListEntry] {
        if let entries = try container.decodeIfPresent([AddressListEntry].self, forKey: key) {
            return entries
        }
        if let texts = try? container.decodeIfPresent([String].self, forKey: legacyKey) {
            return texts.flatMap(AddressParser.parseAddressList)
        }
        return try container.decodeIfPresent(String.self, forKey: legacyKey).map(AddressParser.parseAddressList) ?? []
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
