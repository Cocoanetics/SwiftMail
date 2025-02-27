// SelectHandler.swift
// Handler for IMAP SELECT command

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP SELECT command
public final class SelectHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the select operation
    private let selectPromise: EventLoopPromise<MailboxInfo>
    
    /// The name of the mailbox being selected
    private let mailboxName: String
    
    /// Current mailbox information being built from responses
    private var mailboxInfo: MailboxInfo
    
    /// Initialize a new select handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - mailboxName: The name of the mailbox being selected
    ///   - selectPromise: The promise to fulfill when the select completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, mailboxName: String, selectPromise: EventLoopPromise<MailboxInfo>, timeoutSeconds: Int = 5, logger: Logger) {
        self.selectPromise = selectPromise
        self.mailboxName = mailboxName
        self.mailboxInfo = MailboxInfo(name: mailboxName)
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        selectPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        selectPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // If we have a first unseen message but unseen count is 0,
                // calculate the unseen count as (total messages - first unseen + 1)
                if mailboxInfo.firstUnseen > 0 && mailboxInfo.unseenCount == 0 {
                    mailboxInfo.unseenCount = mailboxInfo.messageCount - mailboxInfo.firstUnseen + 1
                }
                
                selectPromise.succeed(mailboxInfo)
            } else {
                selectPromise.fail(IMAPError.selectFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
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
                                    // Use the BinaryInteger extension to convert UID to UInt32
                                    lock.withLock {
                                        mailboxInfo.uidNext = UInt32(next)
                                    }
                                    
                                case .permanentFlags(let flags):
                                    lock.withLock {
                                        mailboxInfo.permanentFlags = flags.map { String(describing: $0) }
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
                                mailboxInfo.availableFlags = flags.map { String(describing: $0) }
                            }
                            
                        default:
                            break
                    }
                    
                default:
                    break
            }
        }
        
        // Not our tagged response
        return false
    }
} 
