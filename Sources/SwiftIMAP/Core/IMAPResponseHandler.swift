// IMAPResponseHandler.swift
// A custom handler to process IMAP responses

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// A custom handler to process IMAP responses
public final class IMAPResponseHandler: ChannelHandler, @unchecked Sendable {
    public typealias InboundIn = Response
    
    // Promises for different command responses
    var greetingPromise: EventLoopPromise<Void>?
    var loginPromise: EventLoopPromise<Void>?
    var selectPromise: EventLoopPromise<MailboxInfo>?
    var logoutPromise: EventLoopPromise<Void>?
    var fetchPromise: EventLoopPromise<[EmailHeader]>?
    var fetchPartPromise: EventLoopPromise<Data>?
    var fetchStructurePromise: EventLoopPromise<BodyStructure>?
    
    // Tags to identify commands
    var loginTag: String?
    var selectTag: String?
    var logoutTag: String?
    var fetchTag: String?
    var fetchPartTag: String?
    var fetchStructureTag: String?
    
    // Current mailbox being selected
    var currentMailboxName: String?
    var currentMailboxInfo: MailboxInfo?
    
    // Collected email headers
    internal var emailHeaders: [EmailHeader] = []
    
    // Message part data
    internal var partData: Data = Data()
    
    // Message body structure
    internal var bodyStructure: BodyStructure?
    
    // Lock for thread-safe access to mutable properties
    internal let lock = NIOLock()
    
    // Logger for IMAP responses
    internal let logger: Logger
    
    /// Initialize a new response handler
    /// - Parameter logger: The logger to use for logging responses
    public init(logger: Logger) {
        self.logger = logger
    }
    
    /// Format an address for display
    /// - Parameter address: The address to format
    /// - Returns: A formatted string representation of the address
    internal func formatAddress(_ address: EmailAddressListElement) -> String {
        switch address {
        case .singleAddress(let emailAddress):
            let name = emailAddress.personName?.stringValue ?? ""
            let mailbox = emailAddress.mailbox?.stringValue ?? ""
            let host = emailAddress.host?.stringValue ?? ""
            
            if !name.isEmpty {
                return "\"\(name)\" <\(mailbox)@\(host)>"
            } else {
                return "\(mailbox)@\(host)"
            }
            
        case .group(let group):
            let groupName = group.groupName.stringValue
            let members = group.children.map { formatAddress($0) }.joined(separator: ", ")
            return "\(groupName): \(members)"
        }
    }
    
    /// Parse header data into an EmailHeader object
    /// - Parameters:
    ///   - data: The raw header data
    ///   - header: The EmailHeader object to update
    internal func parseHeaderData(_ data: ByteBuffer, into header: inout EmailHeader) {
        // Only parse if we don't already have this information from the envelope
        if header.subject.isEmpty || header.from.isEmpty || header.date.isEmpty {
            guard let headerString = data.getString(at: 0, length: data.readableBytes) else {
                return
            }
            
            // Parse header fields
            let lines = headerString.split(separator: "\r\n")
            var currentField = ""
            var currentValue = ""
            
            for line in lines {
                let trimmedLine = String(line).trimmingCharacters(in: .whitespaces)
                
                // Check if this is a continuation of the previous field
                if trimmedLine.first?.isWhitespace == true {
                    currentValue += " " + trimmedLine.trimmingCharacters(in: .whitespaces)
                } else if let colonIndex = trimmedLine.firstIndex(of: ":") {
                    // Process the previous field if there was one
                    if !currentField.isEmpty {
                        processHeaderField(field: currentField, value: currentValue, header: &header)
                    }
                    
                    // Start a new field
                    currentField = String(trimmedLine[..<colonIndex]).lowercased()
                    currentValue = String(trimmedLine[trimmedLine.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            
            // Process the last field
            if !currentField.isEmpty {
                processHeaderField(field: currentField, value: currentValue, header: &header)
            }
        }
    }
    
    /// Process a header field and update the EmailHeader object
    /// - Parameters:
    ///   - field: The field name
    ///   - value: The field value
    ///   - header: The EmailHeader object to update
    internal func processHeaderField(field: String, value: String, header: inout EmailHeader) {
        // Decode the MIME-encoded value
        let decodedValue = value.decodeMIMEHeader()
        
        switch field {
        case "subject":
            header.subject = decodedValue
        case "from":
            header.from = decodedValue
        case "to":
            header.to = decodedValue
        case "cc":
            header.cc = decodedValue
        case "date":
            header.date = decodedValue
        case "message-id":
            header.messageId = decodedValue
        default:
            // Store other fields in the additionalFields dictionary
            header.additionalFields[field] = decodedValue
        }
    }
    
    /// Process a message attribute and update the corresponding email header
    /// - Parameters:
    ///   - attribute: The message attribute to process
    ///   - sequenceNumber: The sequence number of the message (if known)
	internal func processMessageAttribute(_ attribute: MessageAttribute, sequenceNumber: NIOIMAPCore.SequenceNumber?) {
        // If we don't have a sequence number, we can't update a header
        guard let sequenceNumber = sequenceNumber else {
            // For attributes that come without a sequence number, we assume they belong to the last header
            lock.withLock {
                if let lastIndex = self.emailHeaders.indices.last {
                    var header = self.emailHeaders[lastIndex]
                    updateHeader(&header, with: attribute)
                    self.emailHeaders[lastIndex] = header
                }
            }
            return
        }
        
        // Find or create a header for this sequence number
        let seqNum = Int(sequenceNumber)
        lock.withLock {
            if let index = self.emailHeaders.firstIndex(where: { $0.sequenceNumber == seqNum }) {
                var header = self.emailHeaders[index]
                updateHeader(&header, with: attribute)
                self.emailHeaders[index] = header
            } else {
                var header = EmailHeader(sequenceNumber: seqNum)
                updateHeader(&header, with: attribute)
                self.emailHeaders.append(header)
            }
        }
    }
    
    /// Update an email header with information from a message attribute
    /// - Parameters:
    ///   - header: The header to update
    ///   - attribute: The attribute containing the information
    internal func updateHeader(_ header: inout EmailHeader, with attribute: MessageAttribute) {
        switch attribute {
        case .envelope(let envelope):
            // Extract information from envelope
            if let subject = envelope.subject?.stringValue {
                header.subject = subject.decodeMIMEHeader()
            }
            
            if let from = envelope.from.first {
                let fromAddress = formatAddress(from)
                header.from = fromAddress.decodeMIMEHeader()
            }
            
            if let to = envelope.to.first {
                let toAddress = formatAddress(to)
                header.to = toAddress.decodeMIMEHeader()
            }
            
            if let date = envelope.date {
                header.date = String(date)
            }
            
            if let messageID = envelope.messageID {
                header.messageId = String(messageID)
            }
            
        case .body(_, _):
				break
            
        case .uid(let uid):
            header.uid = Int(uid)
            
        case .flags(let flags):
            header.flags = flags.map { String($0) }
            
        case .internalDate(let date):
            if header.date.isEmpty {
                header.date = String(describing: date)
            }
            
        default:
            break
        }
    }
} 
