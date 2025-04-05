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
    public var to: String?
    
    /// The CC recipients of the message
    public var cc: String?
    
    /// The date of the message
    public var date: Date?
    
    /// The message ID
    public var messageId: String?
    
    /// The flags of the message
    public var flags: [Flag]
    
    /// The message parts
    public var parts: [MessagePart]
    
    /// Additional header fields
    public var additionalFields: [String: String]?
    
    /// Initialize a new email header
    /// - Parameters:
    ///   - sequenceNumber: The sequence number of the message
    ///   - uid: The UID of the message (if available)
    ///   - subject: The subject of the message
    ///   - from: The sender of the message
    ///   - to: The recipients of the message
    ///   - cc: The CC recipients of the message
    ///   - date: The date of the message
    ///   - messageId: The message ID
    ///   - flags: The flags of the message
    ///   - parts: The message parts
    ///   - additionalFields: Additional header fields
    public init(
        sequenceNumber: SequenceNumber,
        uid: SwiftMail.UID? = nil,
        subject: String? = nil,
        from: String? = nil,
        to: String? = nil,
        cc: String? = nil,
        date: Date? = nil,
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
        self.date = date
        self.messageId = messageId
        self.flags = flags
        self.parts = parts
        self.additionalFields = additionalFields
    }
}
