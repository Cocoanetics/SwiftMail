// IMAPFetchPartHandler.swift
// A specialized handler for IMAP fetch part operations

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP FETCH PART command
public final class IMAPFetchPartHandler: BaseIMAPCommandHandler, @unchecked Sendable {
    /// Promise for the fetch part operation
    private let fetchPromise: EventLoopPromise<Data>
    
    /// Collected message part data
    private var partData: Data = Data()
    
    /// Initialize a new fetch part handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - fetchPromise: The promise to fulfill when the fetch completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    ///   - logger: The logger to use for logging responses
    public init(commandTag: String, fetchPromise: EventLoopPromise<Data>, timeoutSeconds: Int = 10, logger: Logger) {
        self.fetchPromise = fetchPromise
        super.init(commandTag: commandTag, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    /// Handle a timeout for this command
    override public func handleTimeout() {
        fetchPromise.fail(IMAPError.timeout)
    }
    
    /// Handle an error
    override public func handleError(_ error: Error) {
        fetchPromise.fail(error)
    }
    
    /// Process an incoming response
    /// - Parameter response: The response to process
    /// - Returns: Whether the response was handled by this handler
    override public func processResponse(_ response: Response) -> Bool {
        // First check if this is our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            if case .ok = taggedResponse.state {
                // Fetch successful
                fetchPromise.succeed(lock.withLock { self.partData })
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
        
        // Not our tagged response
        return false
    }
    
    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case .simpleAttribute(let attribute):
                // Process simple attributes
                processMessageAttribute(attribute)
                
            case .streamingBegin(let kind, _):
                // Log the beginning of streaming data
                logger.debug("Streaming begin for \(String(describing: kind))")
                
            case .streamingBytes(let data):
                // Collect the streaming body data
                lock.withLock {
                    self.partData.append(Data(data.readableBytesView))
                }
                
            default:
                break
        }
    }
    
    /// Process a message attribute
    /// - Parameter attribute: The attribute to process
    private func processMessageAttribute(_ attribute: MessageAttribute) {
        switch attribute {
            case .body(let bodyStructure, _):
                // We're primarily interested in the body data which comes through streaming
                // but we can log the body structure for debugging
                logger.debug("Received body structure: \(String(describing: bodyStructure))")
                
            default:
                break
        }
    }
} 