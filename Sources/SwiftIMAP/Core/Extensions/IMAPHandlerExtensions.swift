// IMAPHandlerExtensions.swift
// Extensions for IMAP command handlers

import Foundation
import os.log
import NIO
import NIOIMAPCore

// MARK: - GreetingHandler Extension

extension GreetingHandler: IMAPCommandHandler {
    public typealias ResultType = Void
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> GreetingHandler {
        let handler = GreetingHandler(
            greetingPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - LoginHandler Extension

extension LoginHandler: IMAPCommandHandler {
    public typealias ResultType = Void
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> LoginHandler {
        let handler = LoginHandler(
            commandTag: commandTag,
            loginPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - LogoutHandler Extension

extension LogoutHandler: IMAPCommandHandler {
    public typealias ResultType = Void
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Void>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> LogoutHandler {
        let handler = LogoutHandler(
            commandTag: commandTag,
            logoutPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - SelectHandler Extension

extension SelectHandler: IMAPCommandHandler {
    public typealias ResultType = MailboxInfo
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<MailboxInfo>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> SelectHandler {
        let handler = SelectHandler(
            commandTag: commandTag,
            mailboxName: "", // This will be set separately
            selectPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - FetchHeadersHandler Extension

extension FetchHeadersHandler: IMAPCommandHandler {
    public typealias ResultType = [EmailHeader]
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<[EmailHeader]>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> FetchHeadersHandler {
        let handler = FetchHeadersHandler(
            commandTag: commandTag,
            fetchPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - FetchPartHandler Extension

extension FetchPartHandler: IMAPCommandHandler {
    public typealias ResultType = Data
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<Data>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> FetchPartHandler {
        let handler = FetchPartHandler(
            commandTag: commandTag,
            fetchPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
}

// MARK: - FetchStructureHandler Extension

extension FetchStructureHandler: IMAPCommandHandler {
    public typealias ResultType = BodyStructure
    
    public static func createHandler(
        commandTag: String,
        promise: EventLoopPromise<BodyStructure>,
        timeoutSeconds: Int,
        logger: Logger
    ) -> FetchStructureHandler {
        let handler = FetchStructureHandler(
            commandTag: commandTag,
            fetchPromise: promise,
            timeoutSeconds: timeoutSeconds,
            logger: logger
        )
        let eventLoop: EventLoop = promise.futureResult.eventLoop
        handler.setupTimeout(on: eventLoop)
        return handler
    }
} 