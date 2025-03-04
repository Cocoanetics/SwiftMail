// SMTPResponseHandler.swift
// A channel handler that processes SMTP responses

import Foundation
import NIO
import Logging

/**
 A channel handler that processes SMTP responses
 */
internal class SMTPResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    
    private weak var server: SMTPServer?
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.SMTPResponseHandler")
    
    init(server: SMTPServer) {
        self.server = server
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        
        // Convert the buffer to a string
        if let string = buffer.getString(at: 0, length: buffer.readableBytes) {
            // Process the response line
            Task {
                await server?.processResponseLine(string)
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log the error
        logger.error("Error in SMTP channel: \(error)")
        
        // Close the channel
        context.close(promise: nil)
    }
} 