//
//  DisconnectHandler.swift
//  SwiftIMAP
//
//  Created by Oliver Drobnik on 04.03.25.
//

import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import OSLog

/// Handler for the disconnect response
public final class DisconnectHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler {
    /// The type of result this handler produces
    public typealias ResultType = Void
    
    /// The channel to close
    private var channel: Channel?
    
    /// Initialize a new disconnect handler
    /// - Parameters:
    ///   - commandTag: The tag associated with this command
    ///   - promise: The promise to fulfill when the disconnect completes
    ///   - timeoutSeconds: The timeout for this command in seconds
    override public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int = 5) {
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
    }
    
    public func handlerRemoved(context: ChannelHandlerContext) {
        // When removed from the pipeline, complete the disconnect operation
        context.close().whenComplete { result in
            switch result {
            case .success:
                self.promise.succeed(())
            case .failure(let error):
                if let channelError = error as? NIOCore.ChannelError, channelError == .alreadyClosed {
                    // Channel is already closed, which is fine
                    self.promise.succeed(())
                } else {
                    self.logger?.error("Error during channel closure: \(error)")
                    self.promise.fail(error)
                }
            }
        }
    }
} 
