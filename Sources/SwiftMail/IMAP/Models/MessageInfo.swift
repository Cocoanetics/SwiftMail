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
    public var messageId: String?
    
    /// The flags of the message
    public var flags: [Flag]
    
    /// The message parts
    public var parts: [MessagePart]
    
    /// Additional header fields
    public var additionalFields: [String: String]?

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
        case flags
        case parts
        case additionalFields
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
        messageId: String? = nil,
        flags: [Flag] = [],
        parts: [MessagePart] = [],
        additionalFields: [String: String]? = nil
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
        self.flags = flags
        self.parts = parts
        self.additionalFields = additionalFields
    }
}

public extension MessageInfo {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let sequenceNumber = try container.decode(SequenceNumber.self, forKey: .sequenceNumber)
        let uid = try container.decodeIfPresent(UID.self, forKey: .uid)
        let subject = try container.decodeIfPresent(String.self, forKey: .subject)
        let from = try container.decodeIfPresent(String.self, forKey: .from)
        let to = try container.decodeIfPresent([String].self, forKey: .to) ?? []
        let cc = try container.decodeIfPresent([String].self, forKey: .cc) ?? []
        let bcc = try container.decodeIfPresent([String].self, forKey: .bcc) ?? []
        let date = try container.decodeIfPresent(Date.self, forKey: .date)
        let internalDate = try container.decodeIfPresent(Date.self, forKey: .internalDate)
        let messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        let flags = try container.decodeIfPresent([Flag].self, forKey: .flags) ?? []
        let parts = try container.decodeIfPresent([MessagePart].self, forKey: .parts) ?? []
        let additionalFields = try container.decodeIfPresent([String: String].self, forKey: .additionalFields)

        self.init(
            sequenceNumber: sequenceNumber,
            uid: uid,
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            date: date,
            internalDate: internalDate,
            messageId: messageId,
            flags: flags,
            parts: parts,
            additionalFields: additionalFields
        )
    }
}
