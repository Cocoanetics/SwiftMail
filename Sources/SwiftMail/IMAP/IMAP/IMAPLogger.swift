// IMAPLogger.swift
// A channel handler that logs both outgoing and incoming IMAP messages

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers

@preconcurrency import NIOIMAP
import NIOIMAPCore

/// A channel handler that logs both outgoing and incoming IMAP messages
final class IMAPLogger: MailLogger, @unchecked Sendable {
	typealias InboundIn = Response
	typealias InboundOut = Response
    
    // Regular expressions for redacting sensitive information
    private let loginRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9]+ LOGIN", options: [])
    private let authRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9]+ AUTH", options: [])
    private let contextPrefix: String

    init(outboundLogger: Logging.Logger, inboundLogger: Logging.Logger, contextPrefix: String = "") {
        self.contextPrefix = contextPrefix
        super.init(outboundLogger: outboundLogger, inboundLogger: inboundLogger)
    }

    private func decorate(_ message: String) -> String {
        guard !contextPrefix.isEmpty else { return message }
        return "\(contextPrefix) \(message)"
    }
    
    /// Process outgoing IMAP commands
	override func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let command = unwrapOutboundIn(data)
        
        // Get string representation of the command
        let commandString = stringRepresentation(from: command)
        
        // Redact sensitive information in LOGIN and AUTH commands
        let range = NSRange(location: 0, length: commandString.utf16.count)
        
        if loginRegex.firstMatch(in: commandString, options: [], range: range) != nil {
            // Use the String extension to redact sensitive LOGIN information
            outboundLogger.trace("\(decorate(commandString.redactAfter("LOGIN")))")
        } else if authRegex.firstMatch(in: commandString, options: [], range: range) != nil {
            // Also redact AUTH commands which may contain encoded credentials
            outboundLogger.trace("\(decorate(commandString.redactAfter("AUTH")))")
        } else {
            outboundLogger.trace("\(decorate(commandString))")
        }
        
        // Forward the command to the next handler
        context.write(data, promise: promise)
    }
    
    /// Process incoming IMAP responses
	override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        // Get log message, abbreviating FETCH responses if needed
        let logMessage: String
        if let resp = response as? Response {
            logMessage = abbreviateResponse(resp)
        } else {
            logMessage = String(describing: response)
        }
        
        // Add the response to the buffer
        bufferInboundResponse(decorate(logMessage))
        
        // Forward the response to the next handler
        context.fireChannelRead(data)
    }
    
    /// Abbreviate FETCH responses containing large body data
    private func abbreviateResponse(_ response: Response) -> String {
        // Check if this is a FETCH response
        if case .fetch(let fetchResponse) = response {
            // Check if it's streaming bytes (large body data)
            if case .streamingBytes(let buffer) = fetchResponse {
                let size = buffer.readableBytes
                if size > 256 {
                    // Truncate to first 256 bytes and show size
                    var preview = buffer
                    let previewData = preview.readString(length: min(256, size)) ?? ""
                    return ".fetch(.streamingBytes(\(size) bytes): \(previewData)..."
                }
            }
        }
        
        // For non-FETCH or small responses, use default string representation
        return String(describing: response)
    }
}
