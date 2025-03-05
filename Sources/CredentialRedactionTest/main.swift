// main.swift
// Test script to verify credential redaction in the IMAP logger

import Foundation
import SwiftIMAP
import SwiftMailCore
import Logging
import NIO

// Set up logging
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .trace
    return handler
}

let logger = Logger(label: "com.cocoanetics.SwiftIMAP.CredentialTest")
logger.info("Starting credential redaction test")

// Create test data
let loginCommand = "A002 LOGIN \"oliver.drobnik@gmail.com\" \"hbag cedn riho gsrj\""
let nonLoginCommand = "A001 CAPABILITY"

// Test the logger directly
let outboundLogger = Logger(label: "com.cocoanetics.SwiftIMAP.IMAP_OUT")
let inboundLogger = Logger(label: "com.cocoanetics.SwiftIMAP.IMAP_IN")

// Create a test IMAPLogger
let imapLogger = IMAPLogger(outboundLogger: outboundLogger, inboundLogger: inboundLogger)

// Test with a login command
logger.info("Testing LOGIN command redaction")
if let loginData = loginCommand.data(using: .utf8) {
    let buffer = ByteBuffer(data: loginData)
    logger.info("Original command: \(loginCommand)")
    logger.info("Testing redaction...")
    
    // We can't directly test the write method's return value since it returns a NIOCore.EventLoopFuture
    // Instead, we rely on the logger output to show in the console
    _ = imapLogger.write(context: try! MockChannelHandlerContext(), data: .byteBuffer(buffer))
}

// Test with a non-login command
logger.info("Testing non-LOGIN command (should not be redacted)")
if let nonLoginData = nonLoginCommand.data(using: .utf8) {
    let buffer = ByteBuffer(data: nonLoginData)
    logger.info("Original command: \(nonLoginCommand)")
    logger.info("Testing non-redaction...")
    
    _ = imapLogger.write(context: try! MockChannelHandlerContext(), data: .byteBuffer(buffer))
}

logger.info("Test completed")

// Simple mock implementation of ChannelHandlerContext for testing
class MockChannelHandlerContext: ChannelHandlerContext {
    var eventLoop: EventLoop {
        fatalError("Not implemented")
    }
    
    var channel: Channel {
        fatalError("Not implemented")
    }
    
    var pipeline: ChannelPipeline {
        fatalError("Not implemented")
    }
    
    var name: String {
        return "MockContext"
    }
    
    func fireChannelRegistered() -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelUnregistered() -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelActive() -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelInactive() -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelRead(_ data: NIOAny) -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelReadComplete() -> ChannelHandlerContext {
        return self
    }
    
    func fireChannelWritabilityChanged() -> ChannelHandlerContext {
        return self
    }
    
    func fireUserInboundEventTriggered(_ event: Any) -> ChannelHandlerContext {
        return self
    }
    
    func fireErrorCaught(_ error: Error) -> ChannelHandlerContext {
        return self
    }
    
    func write(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        // This is a mock - we don't actually forward the data
        promise?.succeed(())
    }
    
    func flush() {
        // Mock implementation
    }
    
    func writeAndFlush(_ data: NIOAny, promise: EventLoopPromise<Void>?) -> Void {
        write(data, promise: promise)
        flush()
    }
    
    func read() -> ChannelHandlerContext {
        return self
    }
    
    func close(mode: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }
    
    func triggerUserOutboundEvent(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }
    
    func waitForOutboundEvent(ofType: Any.Type, predicate: (Any) -> Bool) -> EventLoopFuture<Any> {
        fatalError("Not implemented")
    }
} 