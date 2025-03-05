// ServerHandlers.swift
// Handlers for server-related IMAP commands

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP CAPABILITY command
public final class CapabilityHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler {
    /// Collected capabilities
    private var capabilities: [Capability] = []
    
    /// Initialize a new capability handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    override public init(commandTag: String, promise: EventLoopPromise<[Capability]>) {
        super.init(commandTag: commandTag, promise: promise)
    }
    
    /// Handle a tagged OK response by succeeding the promise with the capabilities
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        let caps = lock.withLock { self.capabilities }
        succeedWithResult(caps)
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
    
    /// Handle an untagged response
    /// - Parameter response: The untagged response
    /// - Returns: Whether the response was handled by this handler
    override public func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(.capabilityData(let capabilities)) = response {
            lock.withLock {
                self.capabilities = capabilities
            }
            
            // We've processed the untagged response, but we're not done yet
            // Return false to indicate we haven't completed processing
            return false
        }
        
        // Not a capability response
        return false
    }
}

/// Handler for IMAP COPY command
public final class CopyHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// Initialize a new copy handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    override public init(commandTag: String, promise: EventLoopPromise<Void>) {
        super.init(commandTag: commandTag, promise: promise)
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
public final class StoreHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// Initialize a new store handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    override public init(commandTag: String, promise: EventLoopPromise<Void>) {
        super.init(commandTag: commandTag, promise: promise)
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
public final class ExpungeHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// Initialize a new expunge handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    override public init(commandTag: String, promise: EventLoopPromise<Void>) {
        super.init(commandTag: commandTag, promise: promise)
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
