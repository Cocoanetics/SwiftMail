import Foundation
import NIOCore
import Logging
import NIOSSL

/**
 A channel handler for processing SMTP responses and forwarding them to the appropriate command handler
 */
final class SMTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
	typealias InboundIn = String
	typealias InboundOut = SMTPResponse
    
    /// Current accumulated response lines
    private var currentResponse = ""
    
    /// Current response code
    private var currentCode: Int = 0
    
    /**
     Handle an incoming response line
     - Parameters:
        - context: The channel handler context
        - data: The incoming data (response line)
     */
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)
        processLine(line, context: context)
    }
    
    /**
     Handle channel errors
     - Parameters:
        - context: The channel handler context
        - error: The error that occurred
     */
	func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Fire the error to the next handler in the pipeline
        context.fireErrorCaught(error)
    }
    
    /**
     Process a response line from the server
     - Parameter line: The response line to process
     - Parameter context: The channel handler context
     */
    private func processLine(_ line: String, context: ChannelHandlerContext) {
        // Add the line to the current response
        currentResponse += line + "\n"
        
        // Try to extract a response code
        if line.count >= 3, let code = Int(line.prefix(3)), code >= 200 && code < 600 {
            currentCode = code
        }
        
        // Check if this is the end of the response
        // SMTP responses end with a space after the code (for the last line of a multi-line response)
        // or if it's a single-line response with a 3-digit code
        let isEndOfResponse = (line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == " ") || 
                              (currentCode > 0 && line.count == 3)
        
        // If we have a response code and it's the end of the response
        if isEndOfResponse && currentCode > 0 {
            // Parse the response
            let message = currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Create the response object
            let response = SMTPResponse(code: currentCode, message: message)
            
            // Fire the response directly to the next handler in the pipeline
            context.fireChannelRead(self.wrapInboundOut(response))
            
            // Reset the current response
            currentResponse = ""
            currentCode = 0
        }
        // Special case for "220 ESMTP" without proper line ending
        else if line.hasPrefix("220 ") && currentResponse.count <= line.count + 1 {
            // Create the response object
            let response = SMTPResponse(code: 220, message: line)
            
            // Fire the response directly to the next handler in the pipeline
            context.fireChannelRead(self.wrapInboundOut(response))
            
            // Reset the current response
            currentResponse = ""
            currentCode = 0
        }
    }
}

/**
 A frame decoder for SMTP responses that extracts individual response lines
 */
final class SMTPLineBasedFrameDecoder: ByteToMessageDecoder {
	typealias InboundIn = ByteBuffer
	typealias InboundOut = String
    
    /// Maximum line length (to prevent memory issues)
    private let maxLength: Int
    
    /// Whether to strip the delimiter from the output
    private let stripDelimiter: Bool
    
    /**
     Initialize a new line-based frame decoder
     - Parameters:
        - maxLength: Maximum allowed line length
        - stripDelimiter: Whether to strip the delimiter from the output
     */
	init(maxLength: Int = 8192, stripDelimiter: Bool = true) {
        self.maxLength = maxLength
        self.stripDelimiter = stripDelimiter
    }
    
    /**
     Decode incoming data into lines
     - Parameters:
        - context: The channel handler context
        - buffer: The incoming data buffer
     - Returns: Decoding result
     */
	func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Check if we can find a line delimiter
        guard let delimiterIndex = buffer.readableBytesView.firstIndex(where: { $0 == 0x0A /* \n */ }) else {
            return .needMoreData
        }
        
        let length = delimiterIndex - buffer.readerIndex + (stripDelimiter ? 0 : 1)
        
        if length > maxLength {
            // Line is too long, skip it
            buffer.moveReaderIndex(forwardBy: length + 1)
            return .continue
        }
        
        let line = buffer.readString(length: length)!
        
        // Skip the delimiter
        buffer.moveReaderIndex(forwardBy: 1)
        
        // Remove carriage return if present (handle \r\n)
        let cleanedLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
        
        // Write the decoded line to the next handler
        context.fireChannelRead(self.wrapInboundOut(cleanedLine))
        
        return .continue
    }
    
	func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        // Just use the normal decode for the last bytes
        return try decode(context: context, buffer: &buffer)
    }
} 
