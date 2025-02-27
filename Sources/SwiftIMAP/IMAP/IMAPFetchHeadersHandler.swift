// IMAPFetchHeadersHandler.swift
// A specialized handler for IMAP fetch headers operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH HEADERS command
public final class IMAPFetchHeadersHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the fetch headers operation
    private let fetchPromise: EventLoopPromise<[EmailHeader]>
    
    /// Collected email headers
    private var emailHeaders: [EmailHeader] = []
    
    /// Initialize a new fetch headers handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - fetchPromise: The promise to fulfill when the fetch completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, fetchPromise: EventLoopPromise<[EmailHeader]>, timeoutSeconds: Int = 10, logger: Logger) {
        self.fetchPromise = fetchPromise
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        super.handleTimeout()
        fetchPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        super.handleError(error)
        fetchPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let baseHandled = super.processResponse(response)
        
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // Fetch successful
                fetchPromise.succeed(lock.withLock { self.emailHeaders })
            } else {
                // Fetch failed
                fetchPromise.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
        // Process fetch responses
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }
        
        // Return the base class result
        return baseHandled
    }
    
    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case .simpleAttribute(let attribute):
                // Process simple attributes (no sequence number)
                processMessageAttribute(attribute, sequenceNumber: nil)
                
            case .start(let sequenceNumber):
                // Create a new header for this sequence number
                let header = EmailHeader(sequenceNumber: Int(sequenceNumber.rawValue))
                lock.withLock {
                    self.emailHeaders.append(header)
                }
                
            case .streamingBegin(_, _):
                // We don't create headers for streamingBegin
                // This avoids misinterpreting the byte count as a sequence number
                break
                
            case .streamingBytes(_):
                // Process streaming bytes if needed
                // For headers, we typically don't need to process the raw header data
                break
                
            default:
                break
        }
    }
    
    /// Process a message attribute and update the corresponding email header
    /// - Parameters:
    ///   - attribute: The message attribute to process
    ///   - sequenceNumber: The sequence number of the message (if known)
    private func processMessageAttribute(_ attribute: MessageAttribute, sequenceNumber: SequenceNumber?) {
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
        let seqNum = Int(sequenceNumber.value)
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
    private func updateHeader(_ header: inout EmailHeader, with attribute: MessageAttribute) {
        switch attribute {
        case .envelope(let envelope):
            // Extract information from envelope
            if let subject = envelope.subject?.stringValue {
                header.subject = subject
            }
            
            // Handle from addresses - check if array is not empty
            if !envelope.from.isEmpty {
                header.from = formatAddress(envelope.from[0])
            }
            
            // Handle to addresses - check if array is not empty
            if !envelope.to.isEmpty {
                header.to = formatAddress(envelope.to[0])
            }
            
            if let date = envelope.date {
                header.date = String(date)
            }
            
            if let messageID = envelope.messageID {
                header.messageId = String(messageID)
            }
            
        case .uid(let uid):
            header.uid = Int(uid)
            
        case .flags(let flags):
            header.flags = flags.map { String(describing: $0) }
            
        default:
            break
        }
    }
    
    /// Format an address for display
    /// - Parameter address: The address to format
    /// - Returns: A formatted string representation of the address
    private func formatAddress(_ address: EmailAddressListElement) -> String {
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
} 
