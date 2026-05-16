import Foundation
import Logging
import NIO
import NIOIMAPCore

/** Handler for the CLOSE command */
final class CloseHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never

    override func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let handled = super.processResponse(response)

        // Process the response
        if case let .tagged(tagged) = response, tagged.tag == commandTag {
            // This is our tagged response, handle it
            switch tagged.state {
                case .ok:
                    succeedWithResult(())
                case let .no(text):
                    failWithError(IMAPError.commandFailed("NO response: \(text)"))
                case let .bad(text):
                    failWithError(IMAPError.commandFailed("BAD response: \(text)"))
            }
            return true
        }

        return handled
    }
}
