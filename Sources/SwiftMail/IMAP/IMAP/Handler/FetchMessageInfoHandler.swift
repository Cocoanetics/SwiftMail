// FetchHeadersHandler.swift
// A specialized handler for IMAP fetch headers operations

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH HEADERS command
final class FetchMessageInfoHandler: BaseIMAPCommandHandler<[MessageInfo]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected email headers
    private var messageInfos: [MessageInfo] = []
    
    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Call super to handle CLIENTBUG warnings
        super.handleTaggedOKResponse(response)
        
        // Succeed with the collected headers
        succeedWithResult(lock.withLock { self.messageInfos })
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func processResponse(_ response: Response) -> Bool {
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
                let messageInfo = MessageInfo(sequenceNumber: SequenceNumber(sequenceNumber.rawValue))
                lock.withLock {
                    self.messageInfos.append(messageInfo)
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
                if let lastIndex = self.messageInfos.indices.last {
                    var header = self.messageInfos[lastIndex]
                    updateHeader(&header, with: attribute)
                    self.messageInfos[lastIndex] = header
                }
            }
            return
        }
        
        // Find or create a header for this sequence number
        let seqNum = SequenceNumber(sequenceNumber.value)
        lock.withLock {
            if let index = self.messageInfos.firstIndex(where: { $0.sequenceNumber == seqNum }) {
                var header = self.messageInfos[index]
                updateHeader(&header, with: attribute)
                self.messageInfos[index] = header
            } else {
                var header = MessageInfo(sequenceNumber: seqNum)
                updateHeader(&header, with: attribute)
                self.messageInfos.append(header)
            }
        }
    }
    
    /// Update an email header with information from a message attribute
    /// - Parameters:
    ///   - header: The header to update
    ///   - attribute: The attribute containing the information
    private func updateHeader(_ header: inout MessageInfo, with attribute: MessageAttribute) {
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
            
            // Handle to addresses - capture all recipients
            header.to = envelope.to.map { formatAddress($0) }

            // Handle cc addresses - capture all recipients
            header.cc = envelope.cc.map { formatAddress($0) }

            // Handle bcc addresses - capture all recipients
            header.bcc = envelope.bcc.map { formatAddress($0) }
            
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
                        break
                    }
                }
                
                // If no format worked, log the issue instead of crashing
                if header.date == nil {
                    print("Warning: Failed to parse email date: \(dateString)")
                }
            }
            
            if let messageID = envelope.messageID {
                header.messageId = String(messageID)
            }
            
        case .uid(let uid):
				header.uid = UID(nio: uid)

        case .internalDate(let serverDate):
            let c = serverDate.components
            var dc = DateComponents()
            dc.year = c.year
            dc.month = c.month
            dc.day = c.day
            dc.hour = c.hour
            dc.minute = c.minute
            dc.second = c.second
            dc.timeZone = Foundation.TimeZone(secondsFromGMT: c.zoneMinutes * 60)
            if let date = Calendar(identifier: .gregorian).date(from: dc) {
                header.internalDate = date
            }

        case .flags(let flags):
            header.flags = flags.map(self.convertFlag)
            
        case .body(let bodyStructure, _):
            if case .valid(let structure) = bodyStructure {
                header.parts = Array<MessagePart>(structure)
            }
            
        default:
            break
        }
    }
    
	/// Convert a NIOIMAPCore.Flag to our MessageFlag type
	private func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
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
                let name = emailAddress.personName?.stringValue.decodeMIMEHeader() ?? ""
                let mailbox = emailAddress.mailbox?.stringValue ?? ""
                let host = emailAddress.host?.stringValue ?? ""
                
                if !name.isEmpty {
                    return "\"\(name)\" <\(mailbox)@\(host)>"
                } else {
                    return "\(mailbox)@\(host)"
                }
                
            case .group(let group):
                let groupName = group.groupName.stringValue.decodeMIMEHeader()
                let members = group.children.map { formatAddress($0) }.joined(separator: ", ")
                return "\(groupName): \(members)"
        }
    }
} 
