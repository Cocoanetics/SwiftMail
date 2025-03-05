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
                    SMTPResponseHandler(server: self),
                    OutboundLogger(logger: self.outboundLogger)
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
        
        // Fetch capabilities using our new method
        let capabilities = try await fetchCapabilities()
        
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
     Execute a command and return the result
     - Parameter command: The command to execute
     - Returns: The result of the command
     - Throws: An error if the command fails
     */
    public func executeCommand<CommandType: SMTPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        // Ensure we have a valid channel
        guard let channel = channel else {
            print("DEBUG - Not connected to SMTP server")
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Validate the command
        try command.validate()
        
        // Create a promise for the result
        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        
        // Generate a command tag for traceability
        let commandTag = UUID().uuidString
        
        // Create the command string
        let commandString = command.toCommandString()
        
        // Log command type for debugging
        print("DEBUG - Executing command of type: \(type(of: command))")
        
        // Create the handler for this command
        var handler: (any SMTPCommandHandler)?
        
        // Check if the command is an AuthCommand
        if let authCommand = command as? AuthCommand, 
           CommandType.ResultType.self == AuthResult.self {
            print("DEBUG - Creating AuthHandler for AuthCommand")
            logger.debug("Creating AuthHandler for AuthCommand")
            // Use the initializer directly
            let authHandler = AuthHandler(
                commandTag: commandTag,
                promise: resultPromise as! EventLoopPromise<AuthResult>,
                method: authCommand.method,
                username: authCommand.username,
                password: authCommand.password,
                channel: channel
            )
            handler = authHandler
            print("DEBUG - AuthHandler initialized with method: \(authCommand.method), username: \(authCommand.username), channel: \(channel)")
            logger.debug("AuthHandler created successfully")
        } else {
            print("DEBUG - Creating handler using initializer")
            logger.debug("Creating handler using initializer")

            // All command handlers are initialized directly with the required parameters.
            // This modern approach avoids the need for a createHandler method on each command.
            handler = CommandType.HandlerType(
                commandTag: commandTag,
                promise: resultPromise
            )
            print("DEBUG - Handler created successfully: \(type(of: handler))")
            logger.debug("Handler created successfully: \(type(of: handler))")
        }
        
        // Set the logger on the handler if it implements LoggableHandler
        if var loggableHandler = handler as? LoggableHandler {
            loggableHandler.logger = logger
            print("DEBUG - Logger set on handler")
            logger.debug("Logger set on handler")
        } else {
            print("DEBUG - Handler does not implement LoggableHandler")
            logger.debug("Handler does not implement LoggableHandler")
        }
        
        // Store the current handler
        self.currentHandler = handler
        
        // Log the command (except for AUTH which may contain sensitive data)
        if commandString.hasPrefix("AUTH") {
            print("DEBUG - Sending: AUTH [credentials redacted]")
            logger.debug("Sending: AUTH [credentials redacted]")
        } else {
            print("DEBUG - Sending: \(commandString)")
            logger.debug("Sending: \(commandString)")
        }
        
        // Create a timeout for the command
		let timeoutSeconds = command.timeoutSeconds
		
		let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            print("DEBUG - Command timed out after \(timeoutSeconds) seconds")
            self.logger.warning("Command timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(SMTPError.connectionFailed("Response timeout"))
        }
        
        do {
            // Add the command handler to the pipeline
            // We need to cast to ChannelHandler since SMTPCommandHandler doesn't conform to ChannelHandler
            if let channelHandler = handler as? ChannelHandler {
                print("DEBUG - Adding handler to pipeline")
                logger.debug("Adding handler to pipeline")
                try await channel.pipeline.addHandler(channelHandler).get()
                print("DEBUG - Handler added to pipeline successfully")
                logger.debug("Handler added to pipeline successfully")
                
                // Send the command to the server
                let buffer = channel.allocator.buffer(string: commandString + "\r\n")
                print("DEBUG - Sending command to server")
                logger.debug("Sending command to server")
                try await channel.writeAndFlush(buffer).get()
                print("DEBUG - Command sent successfully")
                logger.debug("Command sent successfully")
                
                // Wait for the result
                print("DEBUG - Waiting for command result")
                logger.debug("Waiting for command result")
                let result = try await resultPromise.futureResult.get()
                print("DEBUG - Command completed with result")
                logger.debug("Command completed with result")
                
                // Cancel the timeout
                scheduledTask.cancel()
                
                return result
            } else {
                print("DEBUG - Handler is not a ChannelHandler: \(type(of: handler))")
                logger.error("Handler is not a ChannelHandler: \(type(of: handler))")
                throw SMTPError.connectionFailed("Handler is not a ChannelHandler")
            }
        } catch {
            // If any error occurs, fail the promise to prevent leaks
            print("DEBUG - Error executing command: \(error.localizedDescription)")
            logger.error("Error executing command: \(error.localizedDescription)")
            resultPromise.fail(error)
            
            // Cancel the timeout
            scheduledTask.cancel()
            
            // Clear the current handler
            self.currentHandler = nil
            
            throw error
        }
    }
    
    /**
     Authenticate with the SMTP server
     - Parameters:
     - username: The username for authentication
     - password: The password for authentication
     - Returns: Boolean indicating if authentication was successful
     - Throws: SMTPError if authentication fails
     */
    public func authenticate(username: String, password: String) async throws -> Bool {
        // Ensure we have a valid channel
        guard let _ = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Store the current capabilities for local use
        let currentCapabilities = self.capabilities
        print("DEBUG - Server capabilities: \(currentCapabilities)")
        logger.debug("Server capabilities: \(currentCapabilities)")
        
        // Check if the server supports authentication (either general AUTH or specific methods)
        guard currentCapabilities.contains("AUTH") || currentCapabilities.contains(where: { $0.hasPrefix("AUTH ") }) else {
            print("DEBUG - Server does not support authentication")
            throw SMTPError.authenticationFailed("Server does not support authentication")
        }
        
        // Log available auth methods
        let authMethods = currentCapabilities.filter { $0.hasPrefix("AUTH ") }
        print("DEBUG - Available authentication methods: \(authMethods)")
        logger.debug("Available authentication methods: \(authMethods)")
        
        // If we have TLS enabled, try PLAIN auth first
        // Check for either specific AUTH PLAIN or general AUTH capability
        let supportsPlain = currentCapabilities.contains("AUTH PLAIN") || 
                            (currentCapabilities.contains("AUTH") && authMethods.isEmpty)
        
        if isTLSEnabled && supportsPlain {
            print("DEBUG - Attempting PLAIN authentication (TLS enabled: \(isTLSEnabled))")
            logger.debug("Attempting PLAIN authentication (TLS enabled: \(isTLSEnabled))")
            do {
                // Create and execute AUTH PLAIN command
                let plainCommand = AuthCommand(username: username, password: password, method: .plain)
                let result = try await executeCommand(plainCommand)
                
                // If successful, return success
                if result.success {
                    print("DEBUG - PLAIN authentication successful")
                    logger.info("Authenticated successfully using PLAIN")
                    return true
                } else {
                    print("DEBUG - PLAIN authentication failed: \(result.errorMessage ?? "Unknown error")")
                    logger.warning("PLAIN authentication failed: \(result.errorMessage ?? "Unknown error")")
                }
            } catch {
                print("DEBUG - PLAIN authentication error: \(error.localizedDescription)")
                logger.warning("PLAIN authentication error: \(error.localizedDescription)")
            }
        } else {
            print("DEBUG - Skipping PLAIN authentication (TLS enabled: \(isTLSEnabled), AUTH PLAIN supported: \(supportsPlain))")
            logger.debug("Skipping PLAIN authentication (TLS enabled: \(isTLSEnabled), AUTH PLAIN supported: \(supportsPlain))")
        }
        
        // If we reach here, either PLAIN auth failed or wasn't available
        // Try LOGIN auth if supported (either specific AUTH LOGIN or general AUTH capability)
        let supportsLogin = currentCapabilities.contains("AUTH LOGIN") || 
                           (currentCapabilities.contains("AUTH") && authMethods.isEmpty)
        
        if supportsLogin {
            print("DEBUG - Attempting LOGIN authentication")
            logger.debug("Attempting LOGIN authentication")
            do {
                // Create and execute AUTH LOGIN command
                let loginCommand = AuthCommand(username: username, password: password, method: .login)
                let result = try await executeCommand(loginCommand)
                
                // If successful, return success
                if result.success {
                    print("DEBUG - LOGIN authentication successful")
                    logger.info("Authenticated successfully using LOGIN")
                    return true
                } else {
                    print("DEBUG - LOGIN authentication failed: \(result.errorMessage ?? "Unknown error")")
                    logger.warning("LOGIN authentication failed: \(result.errorMessage ?? "Unknown error")")
                    throw SMTPError.authenticationFailed(result.errorMessage ?? "Authentication failed")
                }
            } catch {
                print("DEBUG - LOGIN authentication error: \(error.localizedDescription)")
                logger.warning("LOGIN authentication error: \(error.localizedDescription)")
                throw error
            }
        } else {
            print("DEBUG - LOGIN authentication not supported by server")
            logger.debug("LOGIN authentication not supported by server")
        }
        
        // If we reach here, all authentication methods failed
        print("DEBUG - No supported authentication methods succeeded")
        throw SMTPError.authenticationFailed("No supported authentication methods succeeded")
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
        
        logger.debug("Sending QUIT command...")
        
        do {
            // Use QuitCommand instead of directly sending a string
            let quitCommand = QuitCommand()
            
            do {
                // Execute the QUIT command - it has its own timeout set to 10 seconds
                let result = try await executeCommand(quitCommand)
                logger.debug("QUIT command completed with result: \(result)")
            } catch {
                // If the QUIT command fails, just log it and continue with disconnection
                // This could happen if the server doesn't respond or responds with an error
                logger.warning("QUIT command failed: \(error.localizedDescription)")
            }
        }
        
        // Close the channel regardless of QUIT command result
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
        
        // Send MAIL FROM command using the new command class
        let mailFromCommand = MailFromCommand(senderAddress: email.sender.address)
        let mailFromSuccess = try await executeCommand(mailFromCommand)
        
        // Check if MAIL FROM was accepted
        guard mailFromSuccess else {
            throw SMTPError.sendFailed("Server rejected sender")
        }
        
        // Send RCPT TO command for each recipient using the new command class
        for recipient in email.recipients {
            let rcptToCommand = RcptToCommand(recipientAddress: recipient.address)
            let rcptToSuccess = try await executeCommand(rcptToCommand)
            
            // Check if RCPT TO was accepted
            guard rcptToSuccess else {
                throw SMTPError.sendFailed("Server rejected recipient \(recipient.address)")
            }
        }
        
        // Send DATA command using the new command class
        let dataCommand = DataCommand()
        let dataSuccess = try await executeCommand(dataCommand)
        
        // Check if DATA was accepted
        guard dataSuccess else {
            throw SMTPError.sendFailed("Server rejected DATA command")
        }
        
        // Construct email content
        let emailContent = constructEmailContent(email)
        
        // Send email content using the new command class
        let contentCommand = SendContentCommand(content: emailContent)
        let contentSuccess = try await executeCommand(contentCommand)
        
        // Check if email content was accepted
        guard contentSuccess else {
            throw SMTPError.sendFailed("Server rejected email content")
        }
        
        logger.info("Email sent successfully")
    }
    
    // MARK: - Helper Methods
    
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
        let handler = HandlerType.init(commandTag: "", promise: promise)
        
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
        // Send STARTTLS command using the modernized command approach
        let command = StartTLSCommand()
        let success = try await executeCommand(command)
        
        // Check if STARTTLS was accepted
        guard success else {
            throw SMTPError.tlsFailed("Server rejected STARTTLS")
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
        let ehloCommand = EHLOCommand(hostname: getLocalHostname())
        let capabilities = try await executeCommand(ehloCommand)
        
        // Store capabilities for later use
        self.capabilities = capabilities
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
                
                // Also add the full capability with parameters
                if baseCapability != capability {
                    capabilities.append(capability)
                }
                
                // Special handling for AUTH capability
                if baseCapability == "AUTH" {
                    // Add specific AUTH methods
                    let authMethods = capability.split(separator: " ").dropFirst()
                    for method in authMethods {
                        capabilities.append("AUTH \(method)")
                    }
                }
            }
        }
        
        print("DEBUG - Parsed capabilities: \(capabilities)")
    }
    
    /**
     Fetch server capabilities by sending EHLO command
     - Returns: Array of capability strings
     - Throws: An error if the capability command fails
     */
    @discardableResult
    public func fetchCapabilities() async throws -> [String] {
        // Create the EHLO command with the hostname
        let command = EHLOCommand(hostname: getLocalHostname())
        
        // Execute the command
        let serverCapabilities = try await executeCommand(command)
        
        // Store capabilities for later use
        self.capabilities = serverCapabilities
        logger.debug("Received server capabilities: \(serverCapabilities.joined(separator: ", "))")
        
        return serverCapabilities
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
} 
