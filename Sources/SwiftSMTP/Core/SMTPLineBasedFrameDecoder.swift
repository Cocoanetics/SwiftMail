// SMTPLineBasedFrameDecoder.swift
// A custom line-based frame decoder for SMTP

import Foundation
import NIO
import Logging

/**
 A custom line-based frame decoder for SMTP
 */
internal final class SMTPLineBasedFrameDecoder: ByteToMessageDecoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    
    private var buffer = ""
    private var waitingTime: TimeInterval = 0
    private let checkInterval: TimeInterval = 0.1
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.SMTPDecoder")
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Read the buffer as a string
        guard let string = buffer.readString(length: buffer.readableBytes) else {
            return .needMoreData
        }
        
        logger.trace("Decoder received raw data")
        
        // Add the string to the buffer
        self.buffer += string
        
        // If we have a buffer with content, process it
        if !self.buffer.isEmpty {
            // Check if the buffer contains a complete SMTP response with \r\n
            if self.buffer.contains("\r\n") {
                processCompleteLines(context: context)
                return .continue
            } 
            // Special case for responses without proper line endings
            else if self.buffer.count >= 3 {
                // Check if it starts with a 3-digit code (SMTP response code)
                let prefix = self.buffer.prefix(3)
                if let code = Int(prefix), code >= 200 && code < 600 {
                    // This looks like a valid SMTP response code
                    logger.trace("Found valid SMTP response code: \(code)")
                    
                    // Create a new buffer with the line
                    var outputBuffer = context.channel.allocator.buffer(capacity: self.buffer.utf8.count)
                    outputBuffer.writeString(self.buffer)
                    
                    // Fire the decoded message
                    context.fireChannelRead(self.wrapInboundOut(outputBuffer))
                    
                    // Clear the buffer
                    self.buffer = ""
                    return .continue
                }
            }
            
            // If we've been waiting for a while with data in the buffer, process it anyway
            waitingTime += checkInterval
            if waitingTime > 1.0 && !self.buffer.isEmpty {
                logger.trace("Processing buffer after waiting")
                
                // Create a new buffer with the content
                var outputBuffer = context.channel.allocator.buffer(capacity: self.buffer.utf8.count)
                outputBuffer.writeString(self.buffer)
                
                // Fire the decoded message
                context.fireChannelRead(self.wrapInboundOut(outputBuffer))
                
                // Clear the buffer and reset waiting time
                self.buffer = ""
                waitingTime = 0
                return .continue
            }
        }
        
        // Need more data
        return .needMoreData
    }
    
    private func processCompleteLines(context: ChannelHandlerContext) {
        let lines = self.buffer.components(separatedBy: "\r\n")
        
        // Process all complete lines
        var processedLines = 0
        for line in lines.dropLast() { // Skip the last element which might be incomplete
            if !line.isEmpty {
                logger.trace("Processing complete line")
                
                // Create a new buffer with the line
                var outputBuffer = context.channel.allocator.buffer(capacity: line.utf8.count)
                outputBuffer.writeString(line)
                
                // Fire the decoded message
                context.fireChannelRead(self.wrapInboundOut(outputBuffer))
                
                processedLines += 1
            }
        }
        
        // Remove processed lines from the buffer
        if processedLines > 0 {
            let remainingBuffer = lines.dropFirst(processedLines).joined(separator: "\r\n")
            self.buffer = remainingBuffer.isEmpty ? "" : remainingBuffer + "\r\n"
        }
    }
    
    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        // If we have any data left in the buffer when the connection is closed, process it
        if !self.buffer.isEmpty {
            logger.trace("Processing remaining buffer at EOF")
            
            var outputBuffer = context.channel.allocator.buffer(capacity: self.buffer.utf8.count)
            outputBuffer.writeString(self.buffer)
            context.fireChannelRead(self.wrapInboundOut(outputBuffer))
            self.buffer = ""
            return .continue
        }
        
        // Try to decode any remaining data in the input buffer
        return try decode(context: context, buffer: &buffer)
    }
} 