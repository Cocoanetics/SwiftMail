// SMTPServer.swift
// A Swift SMTP client that encapsulates connection logic

import Foundation
import os.log
import NIO
import NIOSSL
import Logging
import SwiftMailCore

/** An actor that represents an SMTP server connection */
public actor SMTPServer {
    // MARK: - Properties
    
    /** The hostname of the SMTP server */
    private let host: String
    
    /** The port number of the SMTP server */
    private let port: Int
    
    /** The event loop group for handling asynchronous operations */
    private let group: EventLoopGroup
    
    /** The channel for communication with the server */
    private var channel: Channel?
    
    /** The promise for the current SMTP response */
    private var responsePromise: EventLoopPromise<SMTPResponse>?
    
    /** The current SMTP response buffer */
    private var currentResponse = ""
    
    /** Flag indicating whether TLS is enabled */
    private var isTLSEnabled = false
    
    /** Server capabilities reported by EHLO command */
    private var capabilities: [String] = []
    
    /**
     Logger for SMTP operations
     */
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.SMTPServer")
    
    /** Logger for outgoing SMTP commands */
    private let outboundLogger = Logger(label: "com.cocoanetics.SwiftSMTP.SMTP_OUT")
    
    /** Logger for incoming SMTP responses */
    private let inboundLogger = Logger(label: "com.cocoanetics.SwiftSMTP.SMTP_IN")
    
    // MARK: - Initialization
    
    /**
     Initialize a new SMTP server connection
     - Parameters:
     - host: The hostname of the SMTP server
     - port: The port number of the SMTP server
     - numberOfThreads: The number of threads to use for the event loop group
     */
    public init(host: String, port: Int, numberOfThreads: Int = 1) {
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
    }
    
    deinit {
        try? group.syncShutdownGracefully()
    }
    
    // MARK: - Connection and Authentication
    
    /**
     Connect to the SMTP server
     - Returns: A boolean indicating whether the connection was successful
     - Throws: An error if the connection fails
     */
    public func connect() async throws {
        logger.info("Connecting to SMTP server \(self.host):\(self.port)")
        
        // Determine if we should use SSL based on the port
        let useSSL = (port == 465) // SMTPS port
        
        // Create the bootstrap
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let handlers: [ChannelHandler] = [
                    ByteToMessageHandler(SMTPLineBasedFrameDecoder()),
                    SMTPResponseHandler(server: self)
                ]
                
                if useSSL {
                    do {
                        // Create SSL context for secure connection
                        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
                        
                        // Add SSL handler first, then SMTP handlers
                        return channel.pipeline.addHandler(sslHandler).flatMap {
                            channel.pipeline.addHandlers(handlers)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    // Just add SMTP handlers without SSL
                    return channel.pipeline.addHandlers(handlers)
                }
            }
        
        // Connect to the server
        let channel = try await bootstrap.connect(host: host, port: port).get()
        
        // Store the channel
        self.channel = channel
        
        // Wait for the server greeting
        let greeting = try await receiveResponse()
        
        // Check if the greeting is positive
        guard greeting.code >= 200 && greeting.code < 300 else {
            throw SMTPError.connectionFailed("Server rejected connection: \(greeting.message)")
        }
        
        // Send EHLO command and store capabilities
        let ehloResponse = try await sendCommand("EHLO \(getLocalHostname())")
        parseCapabilities(from: ehloResponse.message)
        
        // If not using SSL and port is standard SMTP port, try STARTTLS
        if !useSSL && port == 587 && capabilities.contains("STARTTLS") {
            do {
                try await startTLS()
            } catch {
                logger.warning("STARTTLS failed: \(error.localizedDescription). Continuing without encryption.")
            }
        }
        
        logger.info("Connected to SMTP server \(self.host):\(self.port)")
    }
    
    /**
     Parse server capabilities from EHLO response
     - Parameter response: The EHLO response message
     */
    private func parseCapabilities(from response: String) {
        // Clear existing capabilities
        capabilities.removeAll()
        
        // Split the response into lines
        let lines = response.split(separator: "\n")
        
        // Process each line (skip the first line which is the greeting)
        for line in lines.dropFirst() {
            // Extract the capability (remove the response code prefix if present)
            let capabilityLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if capabilityLine.count > 4 && capabilityLine.prefix(4).allSatisfy({ $0.isNumber || $0 == "-" }) {
                // This is a line with a response code prefix (e.g., "250-SIZE 20480000")
                let capability = String(capabilityLine.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                
                // Extract the base capability (before any parameters)
                let baseCapability = capability.split(separator: " ").first.map(String.init) ?? capability
                capabilities.append(baseCapability)
                
                logger.debug("Detected server capability: \(baseCapability)")
            }
        }
        
        logger.info("Server capabilities: \(capabilities.joined(separator: ", "))")
    }
    
    /**
     Start TLS encryption for the connection
     - Throws: An error if the TLS negotiation fails
     */
    private func startTLS() async throws {
        // Send STARTTLS command
        let response = try await sendCommand("STARTTLS")
        
        // Check if STARTTLS was accepted
        guard response.code >= 200 && response.code < 300 else {
            throw SMTPError.tlsFailed("Server rejected STARTTLS: \(response.message)")
        }
        
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Create SSL context for secure connection
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
        
        // Add SSL handler to the pipeline
        try await channel.pipeline.addHandler(sslHandler, position: .first).get()
        
        // Set TLS flag
        isTLSEnabled = true
        
        // Send EHLO again after STARTTLS and update capabilities
        let ehloResponse = try await sendCommand("EHLO \(getLocalHostname())")
        parseCapabilities(from: ehloResponse.message)
    }
    
    /**
     Authenticate with the SMTP server
     - Parameters:
     - username: The username for authentication
     - password: The password for authentication
     - Throws: An error if the authentication fails
     */
    public func authenticate(username: String, password: String) async throws {
        guard let _ = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Check if authentication is supported
        if !capabilities.contains("AUTH") && !capabilities.contains("AUTH=LOGIN") && !capabilities.contains("AUTH=PLAIN") {
            logger.notice("Authentication not supported by server, skipping login")
            return
        }
        
        logger.info("Authenticating with SMTP server")
        
        // Send AUTH LOGIN command
        let response = try await sendCommand("AUTH LOGIN")
        
        // Check if AUTH LOGIN was accepted
        guard response.code >= 300 && response.code < 400 else {
            if response.code == 503 && response.message.contains("authentication not enabled") {
                logger.notice("Server reported authentication not enabled, continuing without authentication")
                return
            }
            throw SMTPError.authenticationFailed("Server rejected AUTH LOGIN: \(response.message)")
        }
        
        // Send username (base64 encoded)
        let usernameBase64 = Data(username.utf8).base64EncodedString()
        let usernameResponse = try await sendCommand(usernameBase64)
        
        // Check if username was accepted
        guard usernameResponse.code >= 300 && usernameResponse.code < 400 else {
            throw SMTPError.authenticationFailed("Server rejected username: \(usernameResponse.message)")
        }
        
        // Send password (base64 encoded)
        let passwordBase64 = Data(password.utf8).base64EncodedString()
        let passwordResponse = try await sendCommand(passwordBase64)
        
        // Check if authentication was successful
        guard passwordResponse.code >= 200 && passwordResponse.code < 300 else {
            throw SMTPError.authenticationFailed("Authentication failed: \(passwordResponse.message)")
        }
        
        logger.info("Authentication successful")
    }
    
    /**
     Disconnect from the SMTP server
     - Throws: An error if the disconnection fails
     */
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }
        
        logger.info("Disconnecting from SMTP server")
        
        // Send QUIT command
        _ = try await sendCommand("QUIT")
        
        // Close the connection
        try await channel.close().get()
        
        // Set the channel to nil
        self.channel = nil
        
        logger.info("Disconnected from SMTP server")
    }
    
    // MARK: - Email Sending
    
    /**
     Send an email
     - Parameter email: The email to send
     - Throws: An error if the send operation fails
     */
    public func sendEmail(_ email: Email) async throws {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        logger.info("Sending email from \(email.sender.formatted) to \(email.recipients.count) recipients")
        
        // Send MAIL FROM command
        let mailFromResponse = try await sendCommand("MAIL FROM:<\(email.sender.address)>")
        
        // Check if MAIL FROM was accepted
        guard mailFromResponse.code >= 200 && mailFromResponse.code < 300 else {
            throw SMTPError.sendFailed("Server rejected sender: \(mailFromResponse.message)")
        }
        
        // Send RCPT TO command for each recipient
        for recipient in email.recipients {
            let rcptToResponse = try await sendCommand("RCPT TO:<\(recipient.address)>")
            
            // Check if RCPT TO was accepted
            guard rcptToResponse.code >= 200 && rcptToResponse.code < 300 else {
                throw SMTPError.sendFailed("Server rejected recipient \(recipient.address): \(rcptToResponse.message)")
            }
        }
        
        // Send DATA command
        let dataResponse = try await sendCommand("DATA")
        
        // Check if DATA was accepted
        guard dataResponse.code >= 300 && dataResponse.code < 400 else {
            throw SMTPError.sendFailed("Server rejected DATA command: \(dataResponse.message)")
        }
        
        // Construct email content
        let emailContent = constructEmailContent(email)
        
        // Send email content
        let contentResponse = try await sendCommand(emailContent + "\r\n.")
        
        // Check if email content was accepted
        guard contentResponse.code >= 200 && contentResponse.code < 300 else {
            throw SMTPError.sendFailed("Server rejected email content: \(contentResponse.message)")
        }
        
        logger.info("Email sent successfully")
    }
    
    // MARK: - Helper Methods
    
    /**
     Send a command to the SMTP server
     - Parameter command: The command to send
     - Returns: The server's response
     - Throws: An error if the command fails
     */
    private func sendCommand(_ command: String) async throws -> SMTPResponse {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Log the outgoing command (except for AUTH commands which contain sensitive data)
        if !command.hasPrefix("AUTH") && !command.contains("LOGIN") {
            outboundLogger.debug("\(command)")
            logger.debug("Sending SMTP command")
        } else {
            outboundLogger.debug("[AUTH COMMAND]")
        }
        
        // Create a promise for the response
        let promise = channel.eventLoop.makePromise(of: SMTPResponse.self)
        responsePromise = promise
        
        // Send the command
        let buffer = channel.allocator.buffer(string: command + "\r\n")
        try await channel.writeAndFlush(buffer).get()
        
        logger.debug("SMTP command sent, waiting for response")
        
        // Wait for the response with a timeout
        return try await withTimeout(seconds: 30, operation: {
            try await promise.futureResult.get()
        }, onTimeout: {
            throw SMTPError.connectionFailed("Response timeout")
        })
    }
    
    /**
     Execute an async operation with a timeout
     - Parameters:
        - seconds: The timeout in seconds
        - operation: The async operation to execute
        - onTimeout: The closure to execute on timeout
     - Returns: The result of the operation
     - Throws: An error if the operation fails or times out
     */
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T, onTimeout: @escaping () throws -> Void) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            // Add the main operation
            group.addTask {
                return try await operation()
            }
            
            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                try onTimeout()
                throw SMTPError.connectionFailed("Timeout")
            }
            
            // Wait for the first task to complete
            let result = try await group.next()!
            
            // Cancel the remaining tasks
            group.cancelAll()
            
            return result
        }
    }
    
    /**
     Receive a response from the SMTP server
     - Returns: The server's response
     - Throws: An error if the receive operation fails
     */
    private func receiveResponse() async throws -> SMTPResponse {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        logger.debug("Waiting for SMTP server response")
        
        // Create a promise for the response
        let promise = channel.eventLoop.makePromise(of: SMTPResponse.self)
        responsePromise = promise
        
        // Wait for the response with a timeout
        return try await withTimeout(seconds: 30, operation: {
            try await promise.futureResult.get()
        }, onTimeout: {
            throw SMTPError.connectionFailed("Response timeout")
        })
    }
    
    /**
     Process a line of response from the server
     - Parameter line: The response line
     */
    fileprivate func processResponseLine(_ line: String) {
        // Log the incoming response
        inboundLogger.debug("\(line)")
        
        // Add the line to the current response
        currentResponse += line + "\n"
        
        // Try to extract a response code
        var responseCode = 0
        if line.count >= 3, let code = Int(line.prefix(3)), code >= 200 && code < 600 {
            responseCode = code
            logger.debug("Found valid SMTP response code: \(responseCode)")
        }
        
        // Check if this is the end of the response
        // SMTP responses end with a space after the code (for the last line of a multi-line response)
        // or if it's a single-line response with a 3-digit code
        let isEndOfResponse = (line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == " ") || 
                              (responseCode > 0 && line.count == 3)
        
        // If we have a response code and it's the end of the response
        if isEndOfResponse && responseCode > 0 {
            // Parse the response
            let message = currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Create the response object
            let response = SMTPResponse(code: responseCode, message: message)
            
            logger.debug("Completing SMTP response with code \(responseCode)")
            
            // Fulfill the promise
            responsePromise?.succeed(response)
            
            // Reset the current response
            currentResponse = ""
        }
        // Special case for "220 ESMTP" without proper line ending
        else if line.hasPrefix("220 ") {
            logger.debug("Detected greeting response: \(line)")
            
            // Create the response object
            let response = SMTPResponse(code: 220, message: line)
            
            // Fulfill the promise
            responsePromise?.succeed(response)
            
            // Reset the current response
            currentResponse = ""
        }
    }
    
    /**
     Get the local hostname for EHLO command
     - Returns: The local hostname
     */
    private func getLocalHostname() -> String {
        // Just return localhost as a fallback
        return "localhost"
    }
    
    /**
     Construct the email content
     - Parameter email: The email to send
     - Returns: The formatted email content
     */
    private func constructEmailContent(_ email: Email) -> String {
        var content = ""
        
        // Add headers
        content += "From: \(email.sender.formatted)\r\n"
        content += "To: \(email.recipients.map { $0.formatted }.joined(separator: ", "))\r\n"
        content += "Subject: \(email.subject)\r\n"
        content += "MIME-Version: 1.0\r\n"
        
        // Check if there are attachments
        if let attachments = email.attachments, !attachments.isEmpty {
            // Generate a boundary for multipart content
            let boundary = "SwiftSMTP-Boundary-\(UUID().uuidString)"
            
            // Set content type to multipart/mixed
            content += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            
            // Add text part
            content += "--\(boundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.body)\r\n\r\n"
            
            // Add attachments
            for attachment in attachments {
                content += "--\(boundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)\r\n"
                content += "Content-Transfer-Encoding: base64\r\n"
                content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
                
                // Encode attachment data as base64
                let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                content += "\(base64Data)\r\n\r\n"
            }
            
            // End boundary
            content += "--\(boundary)--\r\n"
        } else {
            // Simple email without attachments
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += email.body
        }
        
        return content
    }
    
    /**
     Wait for the initial greeting from the SMTP server
     - Returns: The server's greeting
     - Throws: An error if the greeting is not received
     */
    private func waitForInitialGreeting() async throws -> SMTPResponse {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        logger.debug("Waiting for SMTP server greeting")
        
        // Create a promise for the response
        let promise = channel.eventLoop.makePromise(of: SMTPResponse.self)
        responsePromise = promise
        
        // Wait for the response with a timeout
        return try await withTimeout(seconds: 30, operation: {
            try await promise.futureResult.get()
        }, onTimeout: {
            throw SMTPError.connectionFailed("Greeting timeout")
        })
    }
}

// MARK: - SMTP Line Based Frame Decoder

/**
 A custom line-based frame decoder for SMTP
 */
private final class SMTPLineBasedFrameDecoder: ByteToMessageDecoder {
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

// MARK: - SMTP Response Handler

/**
 A channel handler that processes SMTP responses
 */
private class SMTPResponseHandler: ChannelInboundHandler {
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

// MARK: - SMTP Response

/**
 A struct representing an SMTP server response
 */
public struct SMTPResponse: Sendable {
    /** The response code */
    public let code: Int
    
    /** The response message */
    public let message: String
}

// MARK: - Error Types

public enum SMTPError: Error, LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case sendFailed(String)
    case tlsFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "SMTP connection failed: \(message)"
        case .authenticationFailed(let message):
            return "SMTP authentication failed: \(message)"
        case .sendFailed(let message):
            return "SMTP send failed: \(message)"
        case .tlsFailed(let message):
            return "SMTP TLS negotiation failed: \(message)"
        }
    }
} 
