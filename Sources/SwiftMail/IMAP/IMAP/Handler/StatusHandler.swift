import Foundation
import Logging
import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP STATUS command
final class StatusHandler: BaseIMAPCommandHandler<NIOIMAPCore.MailboxStatus>, IMAPCommandHandler, @unchecked Sendable {
    /// The type of result this handler produces
    typealias ResultType = NIOIMAPCore.MailboxStatus
    
    	/// The mailbox status being built
	private var mailboxInfo = NIOIMAPCore.MailboxStatus()
	
	/// Initialize a new status handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the status completes
    override init(commandTag: String, promise: EventLoopPromise<NIOIMAPCore.MailboxStatus>) {
        // Initialize with default values
        mailboxInfo = NIOIMAPCore.MailboxStatus()
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
        failWithError(IMAPError.commandFailed("STATUS command failed: \(String(describing: response.state))"))
    }
    
    /// Handle untagged responses to extract mailbox information
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Process untagged responses for mailbox information
        if case .untagged(let untaggedResponse) = response {
            // Extract mailbox information from untagged responses
            switch untaggedResponse {
                case .mailboxData(let mailboxData):
                    // Extract mailbox information from mailbox data
                    switch mailboxData {
                        case .status(_, let statusData):
                            // The statusData is already a NIOIMAPCore.MailboxStatus
                            lock.withLock {
                                mailboxInfo = statusData
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
}
