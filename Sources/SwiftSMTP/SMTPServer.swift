// SMTPServer.swift
// A Swift SMTP client that encapsulates connection logic

import Foundation
import NIO
import NIOCore
import NIOSSL
import Logging
import SwiftMailCore

#if os(Linux)
import Glibc
#endif

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
    
    /** Flag indicating whether TLS is enabled */
    private var isTLSEnabled = false
    
    /** Server capabilities reported by EHLO command */
    private var capabilities: [String] = []
    
    /**
     Logger for SMTP operations
     */
    private let logger = Logger(label: "com.cocoanetics.SwiftMail.SMTPServer")
    
	// A logger on the channel that watches both directions
	private let duplexLogger: SMTPLogger

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
		
		let outboundLogger = Logger(label: "com.cocoanetics.SwiftMail.SMTP_OUT")
		let inboundLogger = Logger(label: "com.cocoanetics.SwiftMail.SMTP_IN")

		self.duplexLogger = SMTPLogger(outboundLogger: outboundLogger, inboundLogger: inboundLogger)
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
                    self.duplexLogger,
                    SMTPResponseHandler()
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
    @discardableResult public func executeCommand<CommandType: SMTPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        // Ensure we have a valid channel
        guard let channel = channel else {
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
        
        // Create the handler using standard initialization
        let commandHandler = CommandType.HandlerType(commandTag: commandTag, promise: resultPromise)
        
        // Create special handlers with additional parameters if needed
        var handler: ChannelHandler
        
        // Special case for LoginAuthHandler which needs the command parameters
        if let _ = commandHandler as? LoginAuthHandler,
           let loginCommand = command as? LoginAuthCommand {
            
            // Re-init with command parameters
            let loginHandler = LoginAuthHandler(
                commandTag: commandTag,
                promise: resultPromise as! EventLoopPromise<AuthResult>,
                command: loginCommand
            )
            
            // Store the handler
            handler = loginHandler
        } else {
            // For all other handlers, use the standard cast
            guard let channelHandler = commandHandler as? ChannelHandler else {
                throw SMTPError.connectionFailed("Handler is not a ChannelHandler")
            }
            handler = channelHandler
        }
        
        // Create a timeout for the command
		let timeoutSeconds = command.timeoutSeconds
		
		let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            resultPromise.fail(SMTPError.connectionFailed("Response timeout"))
        }
        
        do {
            // Add the command handler to the pipeline
            try await channel.pipeline.addHandler(handler).get()
            
            // Send the command to the server
            let buffer = channel.allocator.buffer(string: commandString + "\r\n")
            try await channel.writeAndFlush(buffer).get()
            
            // Wait for the result
            let result = try await resultPromise.futureResult.get()
            
            // Cancel the timeout
            scheduledTask.cancel()
			
			// Flush the DuplexLogger's buffer after command execution
			duplexLogger.flushInboundBuffer()
            
            return result
        } catch {
            // Cancel the timeout
            scheduledTask.cancel()
            
            // If it's a timeout error, throw a more specific error
            if error is SMTPError {
                throw error
            } else {
                throw SMTPError.connectionFailed("Command failed: \(error.localizedDescription)")
            }
        }
    }
    
    /**
     Authenticate with the SMTP server
     - Parameters:
     - username: The username to authenticate with
     - password: The password to authenticate with
     - Returns: A boolean indicating if authentication was successful
     - Throws: SMTPError if authentication fails
     */
    public func authenticate(username: String, password: String) async throws -> Bool {
        
        // Check if we have PLAIN auth support
        if capabilities.contains("AUTH PLAIN") {
            let plainCommand = PlainAuthCommand(username: username, password: password)
            let result = try await executeCommand(plainCommand)
            
            // If successful, return success
            if result.success {
                return true
            }
        }
        
        // If PLAIN auth failed or is not supported, try LOGIN auth
        if capabilities.contains("AUTH LOGIN") {
            let loginCommand = LoginAuthCommand(username: username, password: password)
            let result = try await executeCommand(loginCommand)
            
            // If successful, return success
            if result.success {
                return true
            }
        }
        
        // If we get here, authentication failed
        throw SMTPError.authenticationFailed("Authentication failed with all available methods")
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
        
		// Use QuitCommand instead of directly sending a string
		let quitCommand = QuitCommand()
		
		// Execute the QUIT command - it has its own timeout set to 10 seconds
		try await executeCommand(quitCommand)
        
        // Close the channel regardless of QUIT command result
        channel.close(promise: nil)
        self.channel = nil
        
        logger.info("Disconnected from SMTP server")
    }
    
    // MARK: - Email Sending
    
    /**
     Send an email
     - Parameters:
        - email: The email to send
     - Throws: An error if the email cannot be sent
     */
    public func sendEmail(_ email: Email) async throws {
        guard let _ = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }
        
        // Log information about the email being sent
        let totalRecipients = email.recipients.count + email.ccRecipients.count + email.bccRecipients.count
        logger.info("Sending email from \(email.sender) to \(totalRecipients) recipients")
        
        // Log additional details in debug mode
        if email.htmlBody != nil {
            logger.debug("Email contains HTML content")
        }
        
        if let attachments = email.attachments, !attachments.isEmpty {
            let inlineCount = attachments.filter { $0.isInline }.count
            let regularCount = attachments.count - inlineCount
            
            if inlineCount > 0 {
                logger.debug("Email contains \(inlineCount) inline attachment(s)")
            }
            
            if regularCount > 0 {
                logger.debug("Email contains \(regularCount) regular attachment(s)")
            }
        }
        
        // Send MAIL FROM command using the new command class
        let mailFromCommand = try MailFromCommand(senderAddress: email.sender.address)
        let mailFromSuccess = try await executeCommand(mailFromCommand)
        
        // Check if MAIL FROM was accepted
        guard mailFromSuccess else {
            throw SMTPError.sendFailed("Server rejected sender")
        }
        
        // Send RCPT TO command for each recipient (To, CC, and BCC) using the new command class
        for recipient in email.allRecipients {
            let rcptToCommand = try RcptToCommand(recipientAddress: recipient.address)
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
        
        do {
            // Wait for the handler to complete with a timeout
            return try await withTimeout(seconds: Double(timeoutSeconds), operation: {
                // Add the handler to the pipeline
                if let channelHandler = handler as? ChannelHandler {
                    try await channel.pipeline.addHandler(channelHandler).get()
                    
                    // Wait for the result
                    let result = try await promise.futureResult.get()
                    
                    // Flush the DuplexLogger's buffer even if there was an error
                    self.duplexLogger.flushInboundBuffer()
                    
                    return result
                } else {
                    throw SMTPError.connectionFailed("Handler is not a ChannelHandler")
                }
            }, onTimeout: {
                // Fulfill the promise with an error to prevent leaks
                promise.fail(SMTPError.connectionFailed("Response timeout"))
                throw SMTPError.connectionFailed("Response timeout")
            })
        } catch {
            // If any error occurs, fail the promise to prevent leaks
            promise.fail(error)
            
            // Flush the DuplexLogger's buffer even if there was an error
            duplexLogger.flushInboundBuffer()

            throw error
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
        
        // Error handling is now done directly by the handlers
    }
    
    /**
     Construct the email content with headers and body
     - Parameters:
        - email: The email to construct content for
     - Returns: The constructed email content
     */
    private func constructEmailContent(_ email: Email) -> String {
        var content = ""
        
        // Add headers
        content += "From: \(email.sender)\r\n"
        
        // Add To header if there are primary recipients
        if !email.recipients.isEmpty {
            content += "To: \(email.recipients.map { $0.description }.joined(separator: ", "))\r\n"
        }
        
        // Add CC header if there are CC recipients
        if !email.ccRecipients.isEmpty {
            content += "Cc: \(email.ccRecipients.map { $0.description }.joined(separator: ", "))\r\n"
        }
        
        // Note: BCC recipients are not included in the headers (that's why they're "blind")
        
        content += "Subject: \(email.subject)\r\n"
        content += "MIME-Version: 1.0\r\n"
        
        // Generate boundaries
        let mainBoundary = "SwiftSMTP-Boundary-\(UUID().uuidString)"
        let altBoundary = "SwiftSMTP-Alt-Boundary-\(UUID().uuidString)"
        let relatedBoundary = "SwiftSMTP-Related-Boundary-\(UUID().uuidString)"
        
        let hasHtmlBody = email.htmlBody != nil
        let hasInlineAttachments = !email.inlineAttachments.isEmpty
        let hasRegularAttachments = !email.regularAttachments.isEmpty
        
        // Determine the structure based on what we have
        if hasRegularAttachments {
            // If we have regular attachments, use multipart/mixed as the top level
            content += "Content-Type: multipart/mixed; boundary=\"\(mainBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // Start with the text/html part
            if hasHtmlBody {
                content += "--\(mainBoundary)\r\n"
                
                if hasInlineAttachments {
                    // If we have inline attachments, use multipart/related for HTML and inline attachments
                    content += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
                    
                    // First add the multipart/alternative part
                    content += "--\(relatedBoundary)\r\n"
                    content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
                    
                    // Add text part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/plain; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                    
                    // Add inline attachments
                    for attachment in email.inlineAttachments {
                        content += "--\(relatedBoundary)\r\n"
                        content += "Content-Type: \(attachment.mimeType)"
                        content += "; name=\"\(attachment.filename)\"\r\n"
                        content += "Content-Transfer-Encoding: base64\r\n"
                        
                        if let contentID = attachment.contentID {
                            content += "Content-ID: <\(contentID)>\r\n"
                        }
                        
                        content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
                        
                        // Encode attachment data as base64
                        let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                        content += "\(base64Data)\r\n\r\n"
                    }
                    
                    // End related boundary
                    content += "--\(relatedBoundary)--\r\n\r\n"
                } else {
                    // No inline attachments, just use multipart/alternative
                    content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
                    
                    // Add text part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/plain; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                }
            } else {
                // Just text, no HTML
                content += "--\(mainBoundary)\r\n"
                content += "Content-Type: text/plain; charset=UTF-8\r\n"
                content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                content += "\(email.textBody)\r\n\r\n"
            }
            
            // Add regular attachments
            for attachment in email.regularAttachments {
                content += "--\(mainBoundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)\r\n"
                content += "Content-Transfer-Encoding: base64\r\n"
                content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
                
                // Encode attachment data as base64
                let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                content += "\(base64Data)\r\n\r\n"
            }
            
            // End main boundary
            content += "--\(mainBoundary)--\r\n"
        } else if hasHtmlBody && hasInlineAttachments {
            // HTML with inline attachments but no regular attachments - use multipart/related
            content += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // First add the multipart/alternative part
            content += "--\(relatedBoundary)\r\n"
            content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            
            // Add text part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n\r\n"
            
            // Add inline attachments
            for attachment in email.inlineAttachments {
                content += "--\(relatedBoundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)"
                content += "; name=\"\(attachment.filename)\"\r\n"
                content += "Content-Transfer-Encoding: base64\r\n"
                
                if let contentID = attachment.contentID {
                    content += "Content-ID: <\(contentID)>\r\n"
                }
                
                content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
                
                // Encode attachment data as base64
                let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                content += "\(base64Data)\r\n\r\n"
            }
            
            // End related boundary
            content += "--\(relatedBoundary)--\r\n"
        } else if hasHtmlBody {
            // Only HTML, no attachments - use multipart/alternative
            content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // Add text part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n"
        } else {
            // Simple text email
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += email.textBody
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
        let ehloCommand = EHLOCommand(hostname: String.localHostname)
        let rawResponse = try await executeCommand(ehloCommand)

        // Parse capabilities from raw response
        let capabilities = parseCapabilities(from: rawResponse)

        // Store capabilities for later use
        self.capabilities = capabilities
    }
    
    /**
     Parse server capabilities from EHLO response
     - Parameter response: The EHLO response message
     - Returns: Array of server capabilities
     */
    private func parseCapabilities(from response: String) -> [String] {
        // Create a new array for capabilities
        var parsedCapabilities = [String]()
        
        // Split the response into lines
        let lines = response.split(separator: "\n")
        
        // Process each line (skip the first line which is the greeting)
        for line in lines.dropFirst() {
            // Extract the capability (remove the response code prefix if present)
            let capabilityLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // For EHLO responses, each line starts with a response code (e.g., "250-AUTH LOGIN PLAIN")
            if capabilityLine.count > 4 && (capabilityLine.prefix(4).hasPrefix("250-") || capabilityLine.prefix(4).hasPrefix("250 ")) {
                // Extract the capability (after the response code)
                let capabilityPart = capabilityLine.dropFirst(4).trimmingCharacters(in: .whitespaces)
                
                // Special handling for AUTH capability which may list multiple methods
                if capabilityPart.hasPrefix("AUTH ") {
                    // Add the base AUTH capability
                    parsedCapabilities.append("AUTH")
                    
                    // Extract and add each individual auth method
                    let authMethods = capabilityPart.dropFirst(5).split(separator: " ")

					for method in authMethods {
                        let authMethod = "AUTH \(method)"
                        parsedCapabilities.append(authMethod)
					}
                } else {
                    // For other capabilities, add them as-is
                    parsedCapabilities.append(capabilityPart)
                }
            }
        }
        
        return parsedCapabilities
    }
    
    /**
     Fetch server capabilities by sending EHLO command
     - Returns: Array of capability strings
     - Throws: An error if the capability command fails
     */
    @discardableResult
    public func fetchCapabilities() async throws -> [String] {
        let command = EHLOCommand(hostname: String.localHostname)
        
        do {
            let response = try await executeCommand(command)
            
            // Parse the capabilities from the raw response
            let capabilities = parseCapabilities(from: response)
            
            // Store capabilities for later use
            self.capabilities = capabilities
            
            return capabilities
        } catch {
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
} 
