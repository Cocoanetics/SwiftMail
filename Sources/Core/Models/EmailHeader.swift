// EmailHeader.swift
// Structure to hold email header information

import Foundation

/// Structure to hold email header information
public struct EmailHeader: Sendable {
    /// The sequence number of the message
    public let sequenceNumber: Int
    
    /// The UID of the message
    public var uid: Int = 0
    
    /// The subject of the email
    public var subject: String = ""
    
    /// The sender of the email
    public var from: String = ""
    
    /// The recipients of the email
    public var to: String = ""
    
    /// The CC recipients of the email
    public var cc: String = ""
    
    /// The date the email was sent
    public var date: String = ""
    
    /// The message ID
    public var messageId: String = ""
    
    /// The flags set on the message
    public var flags: [String] = []
    
    /// Additional header fields
    public var additionalFields: [String: String] = [:]
    
    /// Initialize a new email header
    /// - Parameter sequenceNumber: The sequence number of the message
    public init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }
    
    /// A string representation of the email header
    public var description: String {
        return """
        Message #\(sequenceNumber) (UID: \(uid > 0 ? String(uid) : "N/A"))
        Subject: \(subject)
        From: \(from)
        Date: \(date)
        Flags: \(flags.joined(separator: ", "))
        """
    }
} 