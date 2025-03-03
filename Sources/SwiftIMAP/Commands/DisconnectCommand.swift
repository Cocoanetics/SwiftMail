// DisconnectCommand.swift
// Command for gracefully disconnecting from an IMAP server

import Foundation
import os.log
import NIOIMAP
import NIOIMAPCore
import NIO

/// Command to gracefully disconnect from the server
public struct DisconnectCommand: IMAPCommand {
    /// The type of result returned by this command
    public typealias ResultType = Void
    
    /// The handler type for this command
    public typealias HandlerType = DisconnectHandler
    
    /// Returns the handler type for this command
    public var handlerType: HandlerType.Type {
        return DisconnectHandler.self
    }
    
    /// The timeout for this command in seconds
    public var timeoutSeconds: Int = 10
    
    /// Initialize a disconnect command
    public init() {}
    
    /// Validate the command
    public func validate() throws {
        // No validation needed
    }
    
    /// Convert to a tagged command
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        // Disconnect doesn't actually send a command, but we need to conform to the protocol
        // This will never be sent to the server as we handle it specially
        return TaggedCommand(tag: tag, command: .noop)
    }
}

/// Handler for the disconnect response
public final class DisconnectHandler: IMAPCommandHandler {
    public typealias ResultType = Void
    public typealias InboundIn = Response
    public typealias InboundOut = Never
    
    private let promise: EventLoopPromise<Void>
    private let commandTag: String
    private var scheduledTask: Scheduled<Void>?
    private let logger: Logger
    
    public static func createHandler(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int, logger: Logger) -> Self {
        return self.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    public init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int, logger: Logger) {
        self.promise = promise
        self.commandTag = commandTag
        self.logger = logger
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) -> EventLoopFuture<Void> {
        // We're not interested in server responses when disconnecting
        return context.eventLoop.makeSucceededFuture(())
    }
    
    public func handleTimeout() {
        promise.fail(IMAPError.timeout)
    }
    
    public func cancelTimeout() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
    
    public func setupTimeout(on eventLoop: EventLoop) {
        let deadline = NIODeadline.now() + .seconds(10)
        scheduledTask = eventLoop.scheduleTask(deadline: deadline) { [weak self] in
            self?.handleTimeout()
        }
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
                    self.logger.error("Error during channel closure: \(error)")
                    self.promise.fail(error)
                }
            }
        }
    }
} 