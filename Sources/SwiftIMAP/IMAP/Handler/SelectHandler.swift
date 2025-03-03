// SelectHandler.swift
// Handler for IMAP SELECT command

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP SELECT command
public final class SelectHandler: BaseIMAPCommandHandler<Mailbox.Status>, IMAPCommandHandler, @unchecked Sendable {
    /// The type of result this handler produces
    public typealias ResultType = Mailbox.Status
    
    /// Current mailbox information being built from responses
    private var mailboxInfo: Mailbox.Status
    
    /// Static property to hold the mailbox name between command creation and handler initialization
    private static var pendingMailboxName: String = ""
    
    /// Prepare the handler for a specific mailbox
    /// - Parameter mailboxName: The name of the mailbox to select
    public static func prepareForMailbox(_ mailboxName: String) {
        pendingMailboxName = mailboxName
    }
    
    /// Create a new handler instance
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public static func createHandler(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int, logger: Logger) -> Self {
        guard let handler = SelectHandler(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger) as? Self else {
            fatalError("Failed to create SelectHandler")
        }
        return handler
    }
    
    /// Initialize a new select handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    override public init(commandTag: String, promise: EventLoopPromise<Mailbox.Status>, timeoutSeconds: Int = 5, logger: Logger) {
        self.mailboxInfo = Mailbox.Status()
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise with the mailbox info
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        // If we have a first unseen message but unseen count is 0,
        // calculate the unseen count as (total messages - first unseen + 1)
        if mailboxInfo.firstUnseen > 0 && mailboxInfo.unseenCount == 0 {
            mailboxInfo.unseenCount = mailboxInfo.messageCount - mailboxInfo.firstUnseen + 1
        }
        
        // Succeed with the mailbox info
        succeedWithResult(mailboxInfo)
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.selectFailed(String(describing: response.state)))
    }
    
    /// Handle untagged responses to extract mailbox information
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func handleUntaggedResponse(_ response: Response) -> Bool {
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
                                    // Use the BinaryInteger extension to convert UIDValidity to UInt32
                                    lock.withLock {
                                        mailboxInfo.uidValidity = UInt32(validity)
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
