// FetchHeadersHandler.swift
// A specialized handler for IMAP fetch headers operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH HEADERS command
public final class FetchHeadersHandler: BaseIMAPCommandHandler<[EmailHeader]>, @unchecked Sendable {
    /// Collected email headers
    private var emailHeaders: [EmailHeader] = []
    
    /// Initialize a new fetch headers handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - fetchPromise: The promise to fulfill when the fetch completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, fetchPromise: EventLoopPromise<[EmailHeader]>, timeoutSeconds: Int = 10, logger: Logger) {
        super.init(commandTag: commandTag, promise: fetchPromise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Succeed with the collected headers
        succeedWithResult(lock.withLock { self.emailHeaders })
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let handled = super.processResponse(response)
        
        // Process fetch responses
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }
        
        // Return the result from the base class
        return handled
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
                header.subject = subject.decodeMIMEHeader()
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
                let dateString = String(date)
                
                // Remove timezone comments in parentheses
                let cleanDateString = dateString.replacingOccurrences(of: "\\s*\\([^)]+\\)\\s*$", with: "", options: .regularExpression)
                
                // Create a date formatter for RFC 5322 dates
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                
                // Try different date formats commonly used in email headers
                let formats = [
                    "EEE, dd MMM yyyy HH:mm:ss Z",       // RFC 5322
                    "EEE, d MMM yyyy HH:mm:ss Z",        // RFC 5322 with single-digit day
                    "d MMM yyyy HH:mm:ss Z",             // Without day of week
                    "EEE, dd MMM yy HH:mm:ss Z"          // Two-digit year
                ]
                
                for format in formats {
                    formatter.dateFormat = format
                    if let parsedDate = formatter.date(from: cleanDateString) {
                        header.date = parsedDate
                        return
                    }
                }
                
                // If we get here, none of the formats worked
                fatalError("Failed to parse email date: \(dateString)")
            }
            
            if let messageID = envelope.messageID {
                header.messageId = String(messageID)
            }
            
        case .uid(let uid):
            header.uid = Int(uid)
            
        case .flags(let flags):
            header.flags = flags.map(self.convertFlag)
            
        default:
            break
        }
    }
    
	/// Convert a NIOIMAPCore.Flag to our MessageFlag type
	private func convertFlag(_ flag: Flag) -> MessageFlag {
		let flagString = String(flag)
		
		switch flagString.uppercased() {
			case "\\SEEN":
				return .seen
			case "\\ANSWERED":
				return .answered
			case "\\FLAGGED":
				return .flagged
			case "\\DELETED":
				return .deleted
			case "\\DRAFT":
				return .draft
			default:
				// For any other flag, treat it as a custom flag
				return .custom(flagString)
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
