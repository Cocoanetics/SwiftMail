// MoveHandler.swift
// Handler for IMAP MOVE command

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/** Handler for IMAP MOVE command */
public final class MoveHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    /** The result type for this handler */
    public typealias ResultType = Void
    
    /**
     Initialize a new move handler
     - Parameters:
       - commandTag: The tag associated with this command
       - movePromise: The promise to fulfill when the move completes
       - timeoutSeconds: The timeout for this command in seconds
       - logger: The logger to use for logging responses
     */
    public init(commandTag: String, movePromise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: movePromise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /**
     Create a handler for the MOVE command
     - Parameters:
       - commandTag: The tag for the command
       - promise: The promise to fulfill with the result
       - timeoutSeconds: The timeout in seconds
       - logger: The logger to use
     - Returns: A handler for the MOVE command
     */
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> MoveHandler {
        return MoveHandler(
            commandTag: commandTag,
            movePromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
    }
    
    /**
     Process an incoming response
     - Parameter response: The response to process
     - Returns: Whether the response was handled by this handler
     */
    override public func processResponse(_ response: Response) -> Bool {
        // Log the response using the base handler
        let baseHandled = super.processResponse(response)
        
        // Check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // The move was successful
                succeedWithResult(())
            } else {
                // The move failed
                failWithError(IMAPError.commandFailed("Move failed: \(String(describing: taggedResponse.state))"))
            }
            return true
        }
        
        // Not our tagged response
        return baseHandled
    }
} 