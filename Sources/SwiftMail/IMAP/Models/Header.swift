// Header.swift
// Structure to hold email header information

import Foundation

/// Structure to hold email header information
public struct Header: Codable, Sendable {
    /// The sequence number of the message
    public var sequenceNumber: Int
    
    /// The UID of the message (if available)
    public var uid: Int = 0
    
    /// The subject of the message
    public var subject: String = ""
    
    /// The sender of the message
    public var from: String = ""
    
    /// The recipients of the message
    public var to: String = ""
    
    /// The CC recipients of the message
    public var cc: String = ""
    
    /// The date of the message
    public var date: Date = .distantPast
    
    /// The message ID
    public var messageId: String = ""
    
    /// The flags of the message
    public var flags: [Flag] = []
    
    /// Additional header fields
    public var additionalFields: [String: String] = [:]
    
    /// Initialize a new email header
    /// - Parameter sequenceNumber: The sequence number of the message
    public init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }
} 
