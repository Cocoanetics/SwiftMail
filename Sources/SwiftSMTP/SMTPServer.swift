// SMTPServer.swift
// A Swift SMTP client that encapsulates connection logic

import Foundation
import os.log
import NIO
import NIOCore
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
    
    /** The current command handler */
    private var currentHandler: (any SMTPCommandHandler)?
    
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
                        // Create SSL context with proper configuration for secure connection
                        var tlsConfig = TLSConfiguration.makeClientConfiguration()
                        tlsConfig.certificateVerification = .fullVerification
                        tlsConfig.trustRoots = .default
                        
                        let sslContext = try NIOSSLContext(configuration: tlsConfig)
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
        
        // Wait for the server greeting using our generic handler execution pattern
        let greeting = try await executeHandlerOnly(handlerType: GreetingHandler.self)
        
        // Check if the greeting is positive
        guard greeting.code >= 200 && greeting.code < 300 else {
            throw SMTPError.connectionFailed("Server rejected connection: \(greeting.message)")
        }
        
        // Send EHLO command and get capabilities
        let capabilities = try await sendEHLO()
        
        // If not using SSL and port is standard SMTP port, try STARTTLS
        if !useSSL && port == 587 && capabilities.contains("STARTTLS") {
            do {
                try await startTLS()
            } catch {
                // For Gmail and other secure servers, we should not continue without encryption
                if host.contains("gmail.com") || host.contains("google.com") {
                    logger.error("STARTTLS failed for Gmail SMTP: \(error.localizedDescription). Cannot continue without encryption.")
                    throw SMTPError.tlsFailed("Gmail requires encryption: \(error.localizedDescription)")
                } else {
                    logger.warning("STARTTLS failed: \(error.localizedDescription). Continuing without encryption.")
                }
            }
        }
        
        logger.info("Connected to SMTP server \(self.host):\(self.port)")
    }
    
    /**
     Send EHLO command to get server capabilities
     - Returns: Array of server capabilities
     - Throws: An error if the command fails
     */
    private func sendEHLO() async throws -> [String] {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Create the handler promise
        let promise = channel.eventLoop.makePromise(of: [String].self)
        
        // Create the handler
		let handler = EHLOHandler.init(commandTag: "", promise: promise)
        
        // Execute the handler with the EHLO command
        let newCapabilities = try await executeHandler(handler, command: "EHLO \(getLocalHostname())")
        
        // Store capabilities for later use
        capabilities = newCapabilities
        
        return newCapabilities
    }
    
    /**
     Authenticate with the SMTP server
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
     - Throws: An error if the authentication fails
     */
    public func authenticate(username: String, password: String) async throws {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Check if authentication is supported
        if !capabilities.contains("AUTH") && 
           !capabilities.contains("AUTH=LOGIN") && 
           !capabilities.contains("AUTH=PLAIN") {
            logger.notice("Authentication not supported by server, skipping login")
            return
        }
        
        logger.info("Authenticating with SMTP server")
        
        // Try authentication methods in order of preference
        if isTLSEnabled && (capabilities.contains("AUTH=PLAIN") || capabilities.contains("AUTH")) {
            // Try PLAIN auth (single step authentication)
            do {
                // Format: \0username\0password
                let authString = "\u{0}\(username)\u{0}\(password)"
                let authData = Data(authString.utf8).base64EncodedString()
                
                // Create the handler promise
                let promise = channel.eventLoop.makePromise(of: AuthResult.self)
                
                // Create the handler
                let handler = AuthHandler(
                    commandTag: nil,
                    promise: promise,
                    timeoutSeconds: 30,
                    method: .plain,
                    username: username,
                    password: password,
                    channel: channel
                )
                
                // Execute the handler with the AUTH PLAIN command
                let result = try await executeHandler(handler, command: "AUTH PLAIN \(authData)")
                
                // Check if authentication was successful
                guard result.success else {
                    let errorMessage = result.errorMessage ?? "Authentication failed"
                    throw SMTPError.authenticationFailed(errorMessage)
                }
                
                logger.info("Authentication successful using PLAIN method")
                return
            } catch {
                logger.warning("PLAIN authentication failed: \(error.localizedDescription), trying LOGIN method")
                // Fall through to try LOGIN method
            }
        }
        
        // Try AUTH LOGIN (two-step authentication)
        do {
            // Create the handler promise
            let promise = channel.eventLoop.makePromise(of: AuthResult.self)
            
            // Create the handler
            let handler = AuthHandler(
                commandTag: nil,
                promise: promise,
                timeoutSeconds: 30,
                method: .login,
                username: username,
                password: password,
                channel: channel
            )
            
            // Execute the handler with the AUTH LOGIN command
            let result = try await executeHandler(handler, command: "AUTH LOGIN")
            
            // Check if authentication was successful
            guard result.success else {
                let errorMessage = result.errorMessage ?? "Authentication failed"
                throw SMTPError.authenticationFailed(errorMessage)
            }
            
            logger.info("Authentication successful using LOGIN method")
        } catch {
            logger.error("Authentication failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /**
     Disconnect from the SMTP server
     - Throws: An error if the disconnection fails
     */
    public func disconnect() async throws {
        guard let channel = channel else {
            logger.warning("Attempted to disconnect when channel was already nil")
            return
        }
        
        // Try to send QUIT command but don't wait for response
        do {
            let buffer = channel.allocator.buffer(string: "QUIT\r\n")
            try await channel.writeAndFlush(buffer).get()
            logger.debug("QUIT command sent")
        } catch {
            logger.debug("Failed to send QUIT command: \(error.localizedDescription)")
        }
        
        // Simply close the channel without waiting for response
        // Note: This may result in an "SSL unclean shutdown" message in the logs,
        // which is normal behavior when closing SSL/TLS connections and can be safely ignored
        channel.close(promise: nil)
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
        guard let _ = channel else {
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
        
        do {
            // Send the command
            let buffer = channel.allocator.buffer(string: command + "\r\n")
            try await channel.writeAndFlush(buffer).get()
            
            logger.debug("SMTP command sent, waiting for response")
            
            // Wait for the response with a timeout
            return try await withTimeout(seconds: 30.0, operation: {
                try await promise.futureResult.get()
            }, onTimeout: {
                // Fulfill the promise with an error response to prevent leaks
                promise.fail(SMTPError.connectionFailed("Response timeout"))
                throw SMTPError.connectionFailed("Response timeout")
            })
        } catch {
            // If any error occurs, fail the promise to prevent leaks
            promise.fail(error)
            throw error
        }
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
     Execute a handler for an SMTP command
     - Parameters:
        - handler: The handler to execute
        - command: The command to send
     - Returns: The result of the handler
     - Throws: An error if the command fails
     */
    private func executeHandler<H: SMTPCommandHandler>(_ handler: H, command: String? = nil) async throws -> H.ResultType {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Set the current handler
        currentHandler = handler
        
        // Send the command if provided
        if let command = command {
            // Log the outgoing command (except for AUTH commands which contain sensitive data)
            if !command.hasPrefix("AUTH") && !command.contains("LOGIN") {
                outboundLogger.debug("\(command)")
            } else {
                outboundLogger.debug("[AUTH COMMAND]")
            }
            
            // Send the command
            let buffer = channel.allocator.buffer(string: command + "\r\n")
            try await channel.writeAndFlush(buffer).get()
        }
        
        do {
            // Wait for the handler to complete with a timeout
            return try await withTimeout(seconds: Double(handler.timeoutSeconds), operation: {
                try await handler.promise.futureResult.get()
            }, onTimeout: {
                // Fulfill the promise with an error to prevent leaks
                handler.promise.fail(SMTPError.connectionFailed("Response timeout"))
                throw SMTPError.connectionFailed("Response timeout")
            })
        } catch {
            // If any error occurs, fail the promise to prevent leaks
            handler.promise.fail(error)
            throw error
        }
    }
    
    /**
     Execute a handler for an SMTP command without sending a command
     - Parameters:
        - handlerType: The type of handler to create
        - timeoutSeconds: The timeout in seconds
     - Returns: The result of the handler
     - Throws: An error if the command fails
     */
    private func executeHandlerOnly<T, HandlerType: SMTPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 30
    ) async throws -> T where HandlerType.ResultType == T {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Create the handler promise
        let promise = channel.eventLoop.makePromise(of: T.self)
        
        // Create the handler directly using initializer
        let handler = HandlerType.init(commandTag: "", promise: promise, timeoutSeconds: timeoutSeconds)
        
        // Set the logger on the handler if it has one
        if var loggable = handler as? LoggableHandler {
            loggable.logger = inboundLogger
        }
        
        // Set the current handler so the response handler can route responses to it
        currentHandler = handler
        
        do {
            // Wait for the handler to complete with a timeout
            return try await withTimeout(seconds: Double(timeoutSeconds), operation: {
                try await promise.futureResult.get()
            }, onTimeout: {
                // Fulfill the promise with an error to prevent leaks
                promise.fail(SMTPError.connectionFailed("Response timeout"))
                // Clear the current handler
                self.currentHandler = nil
                throw SMTPError.connectionFailed("Response timeout")
            })
        } catch {
            // If any error occurs, fail the promise to prevent leaks
            promise.fail(error)
            // Clear the current handler
            self.currentHandler = nil
            throw error
        }
    }
    
    /**
     Process a response from the server using the current handler
     - Parameter response: The response to process
     */
    internal func processResponse(_ response: SMTPResponse) {
        // Log the response
        inboundLogger.debug("\(response.message)")
        
        // If there's a current handler, let it process the response
        if let handler = currentHandler {
            // If the handler indicates it's complete, clear it
            if handler.processResponse(response) {
                currentHandler = nil
            }
        } else if let promise = responsePromise {
            // For backward compatibility, fulfill the promise with the response
            promise.succeed(response)
            responsePromise = nil
        }
    }
    
    /**
     Handle errors in the SMTP channel
     - Parameter error: The error that occurred
     */
    internal func handleChannelError(_ error: Error) {
        // Check if the error is an SSL unclean shutdown, which is common during disconnection
        if let sslError = error as? NIOSSLError, case .uncleanShutdown = sslError {
            logger.notice("SSL unclean shutdown in SMTP channel (this is normal during disconnection)")
        } else {
            logger.error("Error in SMTP channel: \(error.localizedDescription)")
        }
        
        // If there's a current handler, fail its promise
        if let handler = currentHandler {
            // Use a generic function to handle the promise failure
            failHandler(handler: handler, error: error)
            currentHandler = nil
        } else if let promise = responsePromise {
            // For backward compatibility
            promise.fail(error)
            responsePromise = nil
        }
    }
    
    /**
     Generic function to fail a handler's promise with an error
     - Parameters:
       - handler: The handler whose promise should be failed
       - error: The error to fail with
     */
    private func failHandler<H: SMTPCommandHandler>(handler: H, error: Error) {
        handler.promise.fail(error)
    }
    
    /**
     Get the local hostname for EHLO command
     - Returns: The local hostname
     */
    private func getLocalHostname() -> String {
        // Try to get the actual hostname
        if let hostname = Host.current().name {
            return hostname
        }
        
        // Try to get a local IP address as a fallback
        if let localIP = getLocalIPAddress() {
            return "[\(localIP)]"
        }
        
        // Use a domain-like format as a last resort
        return "swift-smtp-client.local"
    }
    
    /**
     Get the local IP address
     - Returns: The local IP address as a string, or nil if not available
     */
    private func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer {
            freeifaddrs(ifaddr)
        }
        
        // Iterate through linked list of interfaces
        var currentAddr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        var foundAddress: String? = nil
        
        while let addr = currentAddr {
            let interface = addr.pointee
            
            // Check for IPv4 or IPv6 interface
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                // Check interface name starts with "en" (Ethernet) or "wl" (WiFi)
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("wl") {
                    // Convert interface address to a human readable string
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    if let address = String(validatingUTF8: hostname) {
                        foundAddress = address
                        break
                    }
                }
            }
            
            // Move to next interface
            currentAddr = interface.ifa_next
        }
        
        return foundAddress
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
        
        // Create SSL context with proper configuration for secure connection
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .fullVerification
        tlsConfig.trustRoots = .default
        
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
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
            }
        }
    }
} 
