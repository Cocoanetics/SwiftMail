// CompressHandler.swift
// Handler for COMPRESS=DEFLATE command

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers
import NIOSSL

/// Handler for IMAP COMPRESS command
public final class CompressHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// Initialize a new compress handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the command completes
    override public init(commandTag: String, promise: EventLoopPromise<Void>) {
        super.init(commandTag: commandTag, promise: promise)
    }
    
    /// Handle a tagged OK response by setting up compression and succeeding the promise
    /// - Parameter response: The tagged response
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Success! The server accepted our COMPRESS command
        // IMPORTANT: NIO will handle compression setup - we can't modify the pipeline here
        // because we're already in the pipeline processing a response
        succeedWithResult(())
    }
    
    /// Handle a tagged error response
    /// - Parameter response: The tagged response
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
    
    /// Handle channel read event
    /// - Parameters:
    ///   - context: The channel handler context
    ///   - data: The inbound data
    override public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // We're only interested in our tagged response
        if case .tagged(let taggedResponse) = response, taggedResponse.tag == commandTag {
            // Mark as completed before locking to avoid deadlock
            self.handleCompletion(context: context)
            
            lock.withLock {
                if case .ok = taggedResponse.state {
                    // Server accepted our compression request
                    handleTaggedOKResponse(taggedResponse)
                } else {
                    // Server rejected our compression request
                    handleTaggedErrorResponse(taggedResponse)
                }
                
                // Remove this handler from the pipeline
                context.pipeline.removeHandler(self, promise: nil)
            }
        } else {
            // Pass other responses down the pipeline
            context.fireChannelRead(data)
        }
    }
} 
