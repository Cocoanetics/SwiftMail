import Foundation
import NIOIMAPCore
import NIO
import Logging

/** Handler for the CLOSE command */
final class CloseHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
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
                    succeedWithResult(())
                case .no(let text):
                    failWithError(IMAPError.commandFailed("NO response: \(text)"))
                case .bad(let text):
                    failWithError(IMAPError.commandFailed("BAD response: \(text)"))
            }
            return true
        }
        
        return handled
    }
} 
