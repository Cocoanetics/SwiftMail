// IMAPLogger.swift
// A channel handler that logs both outgoing and incoming IMAP messages

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import SwiftMailCore
@preconcurrency import NIOIMAP
import NIOIMAPCore

/// A channel handler that logs both outgoing and incoming IMAP messages
public final class IMAPLogger: MailLogger, @unchecked Sendable {
    public typealias InboundIn = Response
    public typealias InboundOut = Response
    
    // Regular expressions for redacting sensitive information
    private let loginRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9]+ LOGIN", options: [])
    private let authRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9]+ AUTH", options: [])
    
    /// Process outgoing IMAP commands
    public override func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let command = unwrapOutboundIn(data)
        
        // Get string representation of the command
        let commandString = stringRepresentation(from: command)
        
        // Redact sensitive information in LOGIN and AUTH commands
        let range = NSRange(location: 0, length: commandString.utf16.count)
        
        if loginRegex.firstMatch(in: commandString, options: [], range: range) != nil {
            // Use the String extension to redact sensitive LOGIN information
            outboundLogger.trace("\(commandString.redactAfter("LOGIN"))")
        } else if authRegex.firstMatch(in: commandString, options: [], range: range) != nil {
            // Also redact AUTH commands which may contain encoded credentials
            outboundLogger.trace("\(commandString.redactAfter("AUTH"))")
        } else {
            outboundLogger.trace("\(commandString)")
        }
        
        // Forward the command to the next handler
        context.write(data, promise: promise)
    }
    
    /// Process incoming IMAP responses
    public override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Add the response to the buffer
        bufferInboundResponse(String(describing: response))
        
        // Forward the response to the next handler
        context.fireChannelRead(data)
    }
}
