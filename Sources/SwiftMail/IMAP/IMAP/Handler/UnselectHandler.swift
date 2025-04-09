import Foundation
import NIOIMAPCore
import NIO
import Logging

/**
 Handler for the UNSELECT command
 
 This handler processes responses from the IMAP server to the UNSELECT command.
 The UNSELECT command is an extension to IMAP defined in RFC 3691 that allows
 a client to deselect the current mailbox without expunging deleted messages.
 */
final class UnselectHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never
    
    override func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let handled = super.processResponse(response)
        
        // Process the response
        if case .tagged(let tagged) = response, tagged.tag == commandTag {
            // This is our tagged response, handle it
            switch tagged.state {
                case .ok:
                    // UNSELECT succeeded
                    succeedWithResult(())
                case .no(let text):
                    // UNSELECT failed with NO response
                    failWithError(IMAPError.commandFailed("NO response: \(text)"))
                case .bad(let text):
                    // UNSELECT failed with BAD response (likely not supported)
                    failWithError(IMAPError.commandFailed("BAD response: \(text)"))
            }
            return true
        }
        
        return handled
    }
} 
