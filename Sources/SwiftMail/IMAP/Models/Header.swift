// Header.swift
// Structure to hold email header information

import Foundation
@preconcurrency import NIOIMAPCore

/// Structure to hold email header information
public struct Header: Sendable {
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
    public var flags: [Flag] = []
    
    /// The message parts
    public var parts: [MessagePart] = []
    
    /// Additional header fields
    public var additionalFields: [String: String]?
    
    /// Initialize a new email header
    /// - Parameter sequenceNumber: The sequence number of the message
    public init(sequenceNumber: SequenceNumber) {
        self.sequenceNumber = sequenceNumber
    }
	
//	public func getPart(_ section: Section) -> Part?
//	{
//		let section = SectionSpecifier.Part(section)
//		if let part = bodyStructure?.find(section)
//		{
//			switch part {
//				case .multipart(let multipart):
//					print(multipart)
//
//				case .singlepart(let singlepart):
//					
//					switch singlepart.kind {
//							case .text:
//								break
//							
//						case .basic(let mediaType):
//							
//							let mediaType = mediaType.topLevel.debugDescription + "/" + mediaType.sub.debugDescription
//							//let fields = Dictionary<String, String>(uniqueKeysWithValues: singlepart.fields.parameters.map(\.name, \.value))
//							
//							
//							
//							return Part(mediaType: mediaType)
//
//							
//							break
//							
//						case .message(let message):
//							break
//					}
//					
//					print(singlepart)
//					
//					break
//				
//			}
//			print(part)
//		}
//		
//		return nil
//	}
}

public struct Part
{
	let mediaType: String
	//let fields: [String: String]
}

// MARK: - Encodable Implementation
extension Header: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(sequenceNumber, forKey: .sequenceNumber)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
        try container.encodeIfPresent(cc, forKey: .cc)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encode(flags, forKey: .flags)
        try container.encode(parts, forKey: .parts)
        
        // Only encode additionalFields if it exists and is not empty
        if let fields = additionalFields, !fields.isEmpty {
            try container.encode(fields, forKey: .additionalFields)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case sequenceNumber, uid, subject, from, to, cc, date, messageId, flags, parts, additionalFields
    }
}
