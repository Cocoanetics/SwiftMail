// FetchStructureHandler.swift
// A specialized handler for IMAP fetch structure operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH STRUCTURE command
public final class FetchStructureHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the fetch structure operation
    private let fetchPromise: EventLoopPromise<BodyStructure>
    
    /// The body structure from the response
    private var bodyStructure: BodyStructure?
    
    /// Initialize a new fetch structure handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - fetchPromise: The promise to fulfill when the fetch completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, fetchPromise: EventLoopPromise<BodyStructure>, timeoutSeconds: Int = 10, logger: Logger) {
        self.fetchPromise = fetchPromise
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        super.handleTimeout()
        fetchPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        super.handleError(error)
        fetchPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // Call the base class implementation to buffer the response
        let baseHandled = super.processResponse(response)
        
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // Fetch successful
                lock.withLock {
                    if let structure = self.bodyStructure {
                        fetchPromise.succeed(structure)
                    } else {
                        fetchPromise.fail(IMAPError.fetchFailed("No body structure received"))
                    }
                }
            } else {
                // Fetch failed
                fetchPromise.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
            }
            return true
        }
        
        // Process fetch responses
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
        }
        
        // Return the base class result
        return baseHandled
    }
    
    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case .simpleAttribute(let attribute):
                // Process simple attributes
                processMessageAttribute(attribute)
                
            default:
                break
        }
    }
    
    /// Process a message attribute
    /// - Parameter attribute: The attribute to process
    private func processMessageAttribute(_ attribute: MessageAttribute) {
        switch attribute {
            case .body(let bodyStructure, _):
                if case .valid(let structure) = bodyStructure {
                    lock.withLock {
                        self.bodyStructure = structure
                    }
                }
                
            default:
                break
        }
    }
} 
