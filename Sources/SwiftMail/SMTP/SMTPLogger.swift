// SMTPLogger.swift
// A channel handler that logs both outgoing and incoming SMTP messages

import Foundation
import Logging
import NIO
import NIOCore
import NIOConcurrencyHelpers

/// A channel handler that logs both outgoing and incoming SMTP messages
final class SMTPLogger: MailLogger, @unchecked Sendable {
    typealias InboundIn = String
    typealias InboundOut = String

    /// Log outgoing commands and forward them to the next handler
    override func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        // Try to extract the command from the data
        let command = unwrapOutboundIn(data)

        // Get string representation of the command
        let commandString = stringRepresentation(from: command)

        // Redact sensitive information in AUTH commands
        if commandString.hasPrefix("AUTH") || commandString.hasPrefix("auth") {
            outboundLogger.trace("\(commandString.redactAfter("AUTH"))")
        } else {
            outboundLogger.trace("\(commandString)")
        }

        // Forward the data to the next handler
        context.write(data, promise: promise)
    }

    /// Log incoming responses and forward them to the next handler
    override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // MailLogger declares InboundIn = Any but the SMTP pipeline only emits
        // Strings; ignore anything else rather than crashing.
        guard let responseString = unwrapInboundIn(data) as? String else {
            context.fireChannelRead(data)
            return
        }

        bufferInboundResponse(responseString)

        // Forward the response to the next handler
        context.fireChannelRead(data)
    }
}
