// ServerHandlers.swift
// Handlers for server-related IMAP commands

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP CAPABILITY command
public final class CapabilityHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    /// Collected capabilities
    private var capabilities: [Capability] = []
    
    /// Initialize a new capability handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    override public init(commandTag: String, promise: EventLoopPromise<[Capability]>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    ///   - logger: The logger to use
    /// - Returns: A handler for the command
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<[Capability]>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> CapabilityHandler {
        return CapabilityHandler(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise with the capabilities
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        logger.debug("Received tagged OK response for CAPABILITY command: \(response.tag)")
        let caps = lock.withLock { self.capabilities }
        logger.debug("Succeeding with \(caps.count) capabilities")
        succeedWithResult(caps)
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        logger.error("Received error response for CAPABILITY command: \(String(describing: response.state))")
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        logger.debug("Processing response in CapabilityHandler: \(String(describing: response))")
        
        // First check if this is a tagged response for our command
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            logger.debug("Received tagged response for our command: \(taggedResponse.tag)")
            return super.processResponse(response)
        }
        
        // Then check for untagged capability data
        if case .untagged(.capabilityData(let capabilities)) = response {
            logger.debug("Received capability data with \(capabilities.count) capabilities")
            lock.withLock {
                self.capabilities = capabilities
            }
            return true
        }
        
        logger.debug("Ignoring unrelated response")
        return false
    }
    
    /// Override channelRead to ensure we see all responses
    override public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        logger.debug("CapabilityHandler channelRead: \(String(describing: response))")
        
        // Let the base handler's processResponse method handle the response
        // This will call handleTaggedOKResponse or handleTaggedErrorResponse for tagged responses
        // and will call handleCompletion if the response is handled
        let handled = super.processResponse(response)
        
        // If not handled by the base handler's processResponse, check if it's an untagged capability response
        if !handled {
            if case .untagged(.capabilityData(let capabilities)) = response {
                logger.debug("Received capability data with \(capabilities.count) capabilities")
                lock.withLock {
                    self.capabilities = capabilities
                }
                // Don't call handleCompletion here as we're still waiting for the tagged OK response
            }
        }
        
        // Always forward the response to the next handler
        context.fireChannelRead(data)
    }
}

/// Handler for IMAP COPY command
public final class CopyHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    /// Initialize a new copy handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    override public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    ///   - logger: The logger to use
    /// - Returns: A handler for the command
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> CopyHandler {
        return CopyHandler(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.copyFailed(String(describing: response.state)))
    }
}

/// Handler for IMAP STORE command
public final class StoreHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    /// Initialize a new store handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    override public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    ///   - logger: The logger to use
    /// - Returns: A handler for the command
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> StoreHandler {
        return StoreHandler(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.storeFailed(String(describing: response.state)))
    }
}

/// Handler for IMAP EXPUNGE command
public final class ExpungeHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    /// Initialize a new expunge handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    override public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int = 5, logger: Logger) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Create a handler for the command
    /// - Parameters:
    ///   - commandTag: The tag for the command
    ///   - promise: The promise to fulfill with the result
    ///   - timeoutSeconds: The timeout in seconds
    ///   - logger: The logger to use
    /// - Returns: A handler for the command
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> ExpungeHandler {
        return ExpungeHandler(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a tagged OK response by succeeding the promise
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.expungeFailed(String(describing: response.state)))
    }
} 
