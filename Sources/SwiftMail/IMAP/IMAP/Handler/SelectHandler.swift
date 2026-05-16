// SelectHandler.swift
// Handler for IMAP SELECT command

import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOIMAP
import NIOIMAPCore

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
        guard case let .untagged(untaggedResponse) = response else {
            return false
        }

        switch untaggedResponse {
            case let .conditionalState(status):
                handleConditionalState(status)
            case let .mailboxData(mailboxData):
                handleMailboxData(mailboxData)
            default:
                break
        }

        // We've processed the untagged response, but we're not done yet
        return false
    }

    /// Apply a conditional-state response to mailbox info.
    private func handleConditionalState(_ status: UntaggedStatus) {
        // Handle OK responses with response text
        guard case let .ok(responseText) = status,
              let responseCode = responseText.code else {
            return
        }
        applyResponseCode(responseCode)
    }

    /// Apply a response code (from OK responses) to mailbox info.
    private func applyResponseCode(_ responseCode: ResponseTextCode) {
        switch responseCode {
            case let .unseen(firstUnseen):
                lock.withLock {
                    mailboxInfo.firstUnseen = Int(firstUnseen)
                }

            case let .uidValidity(validity):
                lock.withLock {
                    mailboxInfo.uidValidity = UIDValidity(nio: validity)
                }

            case let .uidNext(next):
                // Convert NIOIMAPCore.UID to SwiftIMAP.UID
                lock.withLock {
                    mailboxInfo.uidNext = UID(UInt32(next))
                }

            case let .permanentFlags(flags):
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

    /// Extract mailbox information from mailbox data.
    private func handleMailboxData(_ mailboxData: MailboxData) {
        switch mailboxData {
            case let .exists(count):
                lock.withLock {
                    mailboxInfo.messageCount = Int(count)
                }

            case let .recent(count):
                lock.withLock {
                    mailboxInfo.recentCount = Int(count)
                }

            case let .flags(flags):
                lock.withLock {
                    mailboxInfo.availableFlags = flags.map(self.convertFlag)
                }

            default:
                break
        }
    }

    /// Convert a NIOIMAPCore.Flag to our MessageFlag type
    private func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
        let flagString = String(flag)
        return convertFlagString(flagString)
    }

    /// Convert a NIOIMAPCore.PermanentFlag to our MessageFlag type
    private func convertFlag(_ flag: PermanentFlag) -> Flag {
        switch flag {
            case let .flag(coreFlag):
                convertFlag(coreFlag)
            case .wildcard:
                .custom("wildcard")
        }
    }

    /// Convert a flag string to our MessageFlag type
    private func convertFlagString(_ flagString: String) -> Flag {
        switch flagString.uppercased() {
            case "\\SEEN":
                .seen
            case "\\ANSWERED":
                .answered
            case "\\FLAGGED":
                .flagged
            case "\\DELETED":
                .deleted
            case "\\DRAFT":
                .draft
            default:
                // For any other flag, treat it as a custom flag
                .custom(flagString)
        }
    }
}
