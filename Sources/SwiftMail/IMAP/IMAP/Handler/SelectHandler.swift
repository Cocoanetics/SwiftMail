// SelectHandler.swift
// Handler for IMAP SELECT command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP SELECT command
final class SelectHandler: BaseIMAPCommandHandler<Mailbox.Selection>, IMAPCommandHandler, @unchecked Sendable {
    /// The type of result this handler produces
    typealias ResultType = Mailbox.Selection
    
    /// The mailbox selection being built
    private var mailboxInfo = Mailbox.Selection()
    
    /// Initialize a new select handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the select completes
    override init(commandTag: String, promise: EventLoopPromise<Mailbox.Selection>) {
        // Initialize with default values
        mailboxInfo = Mailbox.Selection()
        super.init(commandTag: commandTag, promise: promise)
    }
    
    	/// Handle a tagged OK response by succeeding the promise with the mailbox info
	/// - Parameter response: The tagged response
	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		// Succeed with the mailbox info
		succeedWithResult(mailboxInfo)
	}
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.selectFailed(String(describing: response.state)))
    }
    
    /// Handle untagged responses to extract mailbox information
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Process untagged responses for mailbox information
        if case .untagged(let untaggedResponse) = response {
            // Extract mailbox information from untagged responses
            switch untaggedResponse {
                case .conditionalState(let status):
                    // Handle OK responses with response text
                    if case .ok(let responseText) = status {
                        // Check for response codes in the response text
                        if let responseCode = responseText.code {
                            switch responseCode {
                                case .unseen(let firstUnseen):
                                    lock.withLock {
                                        mailboxInfo.firstUnseen = Int(firstUnseen)
                                    }
                                    
                                case .uidValidity(let validity):
                                    lock.withLock {
                                        mailboxInfo.uidValidity = UIDValidity(nio: validity)
                                    }
                                    
                                case .uidNext(let next):
                                    // Convert NIOIMAPCore.UID to SwiftIMAP.UID
                                    lock.withLock {
                                        mailboxInfo.uidNext = UID(UInt32(next))
                                    }
                                    
                                case .permanentFlags(let flags):
                                    lock.withLock {
                                        mailboxInfo.permanentFlags = flags.map(self.convertFlag)
                                    }
                                    
                                case .readOnly:
                                    lock.withLock {
                                        mailboxInfo.isReadOnly = true
                                    }
                                    
                                case .readWrite:
                                    lock.withLock {
                                        mailboxInfo.isReadOnly = false
                                    }
                                    
                                default:
                                    break
                            }
                        }
                    }
                    
                case .mailboxData(let mailboxData):
                    // Extract mailbox information from mailbox data
                    switch mailboxData {
                        case .exists(let count):
                            lock.withLock {
                                mailboxInfo.messageCount = Int(count)
                            }
                            
                        case .recent(let count):
                            lock.withLock {
                                mailboxInfo.recentCount = Int(count)
                            }
                            
                        case .flags(let flags):
                            lock.withLock {
                                mailboxInfo.availableFlags = flags.map(self.convertFlag)
                            }
                            
                        default:
                            break
                    }
                    
                default:
                    break
            }
            
            // We've processed the untagged response, but we're not done yet
            return false
        }
        
        return false
    }
    
    /// Convert a NIOIMAPCore.Flag to our MessageFlag type
    private func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
        let flagString = String(flag)
        return convertFlagString(flagString)
    }
    
    /// Convert a NIOIMAPCore.PermanentFlag to our MessageFlag type
    private func convertFlag(_ flag: PermanentFlag) -> Flag {
        switch flag {
        case .flag(let coreFlag):
            return convertFlag(coreFlag)
        case .wildcard:
            return .custom("wildcard")
        }
    }
    
    /// Convert a flag string to our MessageFlag type
    private func convertFlagString(_ flagString: String) -> Flag {
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
} 
