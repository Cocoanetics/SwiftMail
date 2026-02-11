// SMTPServer.swift
// A Swift SMTP client that encapsulates connection logic

import Foundation
import NIO
import NIOCore
import NIOSSL
import Logging

import NIOConcurrencyHelpers

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/**
 An actor that represents an SMTP server connection.
 
 This class provides functionality to:
 - Establish secure connections to SMTP servers
 - Authenticate using various mechanisms (PLAIN, LOGIN)
 - Send emails with attachments and inline content
 - Handle connection lifecycle and server capabilities
 
 Example:
 ```swift
 let server = SMTPServer(host: "smtp.example.com", port: 587)
 try await server.connect()
 try await server.authenticate(username: "user@example.com", password: "password")
 
 let email = Email(
     sender: EmailAddress("sender@example.com"),
     recipients: [EmailAddress("recipient@example.com")],
     subject: "Test Email",
     body: "Hello, World!"
 )
 try await server.sendEmail(email)
 ```
 
 - Note: All operations are logged using the Swift Logging package:
   - Critical: Fatal errors that prevent email sending
   - Error: Authentication failures, connection issues
   - Warning: TLS negotiation issues, timeout warnings
   - Notice: Successful connections and disconnections
   - Info: Email sending progress
   - Debug: SMTP command execution details
   - Trace: Raw SMTP protocol communication
 */
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
    
    /** Flag indicating whether TLS is enabled for the connection */
    private var isTLSEnabled = false
    
    /** Server capabilities reported by EHLO command */
    private var capabilities: [String] = []
    
    /** 
     Logger for SMTP operations
     
     This logger outputs SMTP-specific operations and events at appropriate levels:
     - Critical: Application cannot continue
     - Error: Operation failed but application can continue
     - Warning: Potential issues that don't impact functionality
     - Notice: Important events in normal operation
     - Info: General information about application flow
     - Debug: Detailed debugging information
     - Trace: Protocol-level communication
     
     To view these logs in Console.app:
     1. Open Console.app
     2. Search for "process:com.cocoanetics.SwiftMail"
     3. Adjust the "Action" menu to show Debug and Info messages
     */
    private let logger = Logger(label: "com.cocoanetics.SwiftMail.SMTPServer")
    
    /** 
     A logger that monitors both inbound and outbound SMTP traffic
     
     This logger captures the raw SMTP protocol communication in both directions:
     - Outbound: Commands sent to the server
     - Inbound: Responses received from the server
     
     Sensitive information like passwords and authentication tokens is automatically
     redacted in the logs.
     */
    private let duplexLogger: SMTPLogger

    // MARK: - Initialization
    
    /** 
     Initialize a new SMTP server connection
     
     - Parameters:
       - host: The hostname of the SMTP server
       - port: The port number of the SMTP server
       - numberOfThreads: The number of threads to use for the event loop group
     
     The port number determines the initial security mode:
     - Port 25: Plain SMTP (not recommended)
     - Port 587: STARTTLS (recommended)
     - Port 465: SMTPS (implicit TLS)
     
     - Note: Logs initialization at debug level with connection details
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
     
     This method establishes a connection to the SMTP server and performs initial handshaking:
     1. Creates a TCP connection to the server
     2. Sets up SSL/TLS if using port 465 (SMTPS)
     3. Receives the server's greeting
     4. Fetches server capabilities using EHLO
     5. Upgrades to TLS using STARTTLS if on port 587
     
     - Throws: 
       - `SMTPError.connectionFailed` if the connection cannot be established
       - `SMTPError.tlsFailed` if TLS negotiation fails
       - `NIOSSLError` if SSL/TLS setup fails
     - Note: Logs connection attempts and capability retrieval at info level
     */
    public func connect() async throws {
        logger.debug("Connecting to SMTP server at \(host):\(port)")
        
        // Determine if we should use SSL based on the port
        let useSSL = (port == 465) // SMTPS port
        
        // Create the bootstrap
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                if useSSL {
                    do {
                        // Create SSL context with proper configuration for secure connection
                        var tlsConfig = TLSConfiguration.makeClientConfiguration()
                        tlsConfig.certificateVerification = .fullVerification
                        tlsConfig.trustRoots = .default
                        
                        let sslContext = try NIOSSLContext(configuration: tlsConfig)
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
                        
                        // Add SSL handler first, then SMTP handlers using syncOperations
                        try! channel.pipeline.syncOperations.addHandler(sslHandler)
                        try! channel.pipeline.syncOperations.addHandlers([
							ByteToMessageHandler(SMTPLineBasedFrameDecoder()),
							self.duplexLogger,
							SMTPResponseHandler()
						])
                        
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    // Just add SMTP handlers without SSL using syncOperations
                    try! channel.pipeline.syncOperations.addHandlers([
						ByteToMessageHandler(SMTPLineBasedFrameDecoder()),
						self.duplexLogger,
						SMTPResponseHandler()
					])
                    
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }
        
        // Connect to the server
        let channel = try await bootstrap.connect(host: host, port: port).get()
        
        // Store the channel
        self.channel = channel
        
        // Wait for the server greeting using our generic handler execution pattern
        let greeting = try await executeHandlerOnly(handlerType: SMTPGreetingHandler.self)
        
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
     Authenticate with the SMTP server
     
     This method authenticates with the SMTP server using the provided credentials.
     It automatically selects the best available authentication mechanism supported
     by the server, preferring more secure methods:
     1. XOAUTH2 (if supported and token provided)
     2. PLAIN (if TLS is active)
     3. LOGIN (if TLS is active)
     
     - Parameters:
       - username: The username for authentication
       - password: The password or access token for authentication
     - Throws:
       - `SMTPError.authenticationFailed` if credentials are rejected
       - `SMTPError.connectionFailed` if not connected
       - `SMTPError.tlsRequired` if attempting to authenticate without TLS
     - Note: Logs authentication attempts at info level (without credentials)
     */
    public func login(username: String, password: String) async throws {
        
        // Check if we have PLAIN auth support
        if capabilities.contains("AUTH PLAIN") {
            let plainCommand = PlainAuthCommand(username: username, password: password)
            let result = try await executeCommand(plainCommand)
            
            // If successful, return success
            if result.success {
                return
            }
        }
        
        // If PLAIN auth failed or is not supported, try LOGIN auth
        if capabilities.contains("AUTH LOGIN") {
            let loginCommand = LoginAuthCommand(username: username, password: password)
            let result = try await executeCommand(loginCommand)
            
            // If successful, return success
            if result.success {
                return
            }
        }
        
        // If we get here, authentication failed
        throw SMTPError.authenticationFailed("Authentication failed with all available methods")
    }
    
    /**
     Authenticate with the SMTP server using XOAUTH2

     This method authenticates using the XOAUTH2 mechanism, which is required
     by Gmail and other providers when using OAuth2 access tokens for SMTP.

     - Parameters:
       - email: The email address of the account
       - accessToken: A valid OAuth2 access token
     - Throws:
       - `SMTPError.authenticationFailed` if the server does not support XOAUTH2
         or if the token is rejected
       - `SMTPError.connectionFailed` if not connected
     */
    public func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        guard capabilities.contains("AUTH XOAUTH2") else {
            throw SMTPError.authenticationFailed("Server does not support XOAUTH2 authentication")
        }

        let command = XOAuth2AuthCommand(email: email, accessToken: accessToken)
        let result = try await executeCommand(command)

        guard result.success else {
            throw SMTPError.authenticationFailed(result.errorMessage ?? "XOAUTH2 authentication failed")
        }
    }

    /**
     Disconnect from the SMTP server
     
     This method performs a clean disconnect from the server by:
     1. Sending the QUIT command
     2. Waiting for the server's response
     3. Closing the connection
     
     - Throws: 
       - `SMTPError.disconnectFailed` if the quit command fails
       - `SMTPError.connectionFailed` if already disconnected
     - Note: Logs disconnection at info level
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
     Send an email with the server
     
     This method handles the complete email sending process:
     1. Validates the connection state
     2. Processes all recipients (To, CC, BCC)
     3. Handles attachments and inline content
     4. Uses 8BITMIME if supported by the server
     
     - Parameters:
       - email: The email to send, including recipients, subject, body, and attachments
     - Throws: 
       - `SMTPError.connectionFailed` if not connected
       - `SMTPError.sendFailed` if the email cannot be sent
       - `SMTPError.recipientRejected` if any recipient is rejected
     - Note: 
       - Logs email sending at info level with recipient count
       - Logs attachment details at debug level
       - Redacts sensitive content in logs
     */
    public func sendEmail(_ email: Email) async throws {
        // Check if we have a valid channel (meaning we're connected)
        guard channel != nil else {
            logger.error("Attempting to send email without an active connection")
            throw SMTPError.connectionFailed("Not connected to SMTP server. Call connect() first.")
        }
        
        // We don't explicitly check for authentication here, as the SMTP server will reject
        // commands if not authenticated, and that will be handled by the error handling below.
        
        var allRecipients = email.recipients
        allRecipients.append(contentsOf: email.ccRecipients)
        allRecipients.append(contentsOf: email.bccRecipients)
        
        logger.debug("Sending email to \(allRecipients.count) recipients with subject: \(email.subject)")
        if !email.regularAttachments.isEmpty || !email.inlineAttachments.isEmpty {
            logger.debug("Email contains \(email.regularAttachments.count) regular attachments and \(email.inlineAttachments.count) inline attachments")
        }
        
        // Check if the server supports 8BITMIME
        let supports8BitMIME = self.capabilities.contains("8BITMIME")
        
        if supports8BitMIME {
            self.logger.debug("Server supports 8BITMIME, using it for this email")
        }
        
        do {
            // Create Mail From command using 8BITMIME if supported
            let mailFrom = try MailFromCommand(senderAddress: email.sender.address, use8BitMIME: supports8BitMIME)
            _ = try await executeCommand(mailFrom)
            
            // RCPT TO commands
            for recipient in allRecipients {
                let rcptTo = try RcptToCommand(recipientAddress: recipient.address)
                _ = try await executeCommand(rcptTo)
            }
            
            // DATA command
            let data = DataCommand()
            _ = try await executeCommand(data)
            
            // Send content
            let sendContent = SendContentCommand(email: email, use8BitMIME: supports8BitMIME)
            try await executeCommand(sendContent)
            
            self.logger.debug("Email sent successfully")
        } catch {
            self.logger.error("Failed to send email: \(error)")
            throw error
        }
    }
    
    // MARK: - Helper Methods
    
	/**
	 Execute a command and return the result
	 
	 This method handles the execution of SMTP commands by:
	 1. Validating the command
	 2. Setting up appropriate handlers
	 3. Managing command timeouts
	 4. Handling command-specific requirements (e.g., LOGIN auth)
	 
	 - Parameter command: The command to execute
	 - Returns: The result of the command execution
	 - Throws:
	   - `SMTPError.connectionFailed` if not connected
	   - `SMTPError.commandFailed` if the command execution fails
	   - `SMTPError.timeout` if the command times out
	 - Note: Logs command execution at debug level
	 */
	@discardableResult private func executeCommand<CommandType: SMTPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
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
		let handler: any SMTPCommandHandler
		
		// Special case for LoginAuthHandler which needs the command parameters
		if let loginCommand = command as? LoginAuthCommand {
			handler = LoginAuthHandler(commandTag: commandTag, promise: resultPromise as! EventLoopPromise<AuthResult>, command: loginCommand)
		}
		else
		{
			handler = CommandType.HandlerType(commandTag: commandTag, promise: resultPromise)
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
     Execute a handler without sending a command
     
     This method is used for handling server-initiated responses like the initial
     greeting. It sets up the handler and manages timeouts without sending any
     command to the server.
     
     - Parameters:
       - handlerType: The type of handler to use
       - timeoutSeconds: The timeout duration in seconds (default: 5)
     - Returns: The result from the handler
     - Throws: 
       - `SMTPError.connectionFailed` if not connected
       - `SMTPError.timeout` if the operation times out
     - Note: Logs handler execution at debug level
     */
	private func executeHandlerOnly<T: Sendable, HandlerType: SMTPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
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
				try await channel.pipeline.addHandler(handler).get()
				
				// Wait for the result
				let result = try await promise.futureResult.get()
				
				// Flush the DuplexLogger's buffer even if there was an error
				self.duplexLogger.flushInboundBuffer()
				
				return result
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
     Upgrade the connection to use TLS
     
     This method upgrades a plain connection to use TLS encryption using the
     STARTTLS command. After successful upgrade, it re-fetches server capabilities
     as they may change.
     
     - Throws: 
       - `SMTPError.tlsFailed` if TLS negotiation fails
       - `SMTPError.commandFailed` if STARTTLS command fails
       - `SMTPError.connectionFailed` if not connected
     - Note: Logs TLS upgrade attempts at info level
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
        
        // Capture the configuration before the closure to avoid concurrency issues
        let finalTlsConfig = tlsConfig
        
        // Add SSL handler to the pipeline using EventLoop submission to ensure correct thread
        try await channel.eventLoop.submit {
            let sslContext = try NIOSSLContext(configuration: finalTlsConfig)
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
        }.get()
        
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
     Fetch server capabilities using EHLO command
     
     This method sends the EHLO command to the server and processes its response
     to determine the server's supported features. It's called automatically during
     connection and after STARTTLS, but can be called manually if needed.
     
     - Returns: Array of capability strings reported by the server
     - Throws: 
       - `SMTPError.commandFailed` if the EHLO command fails
       - `SMTPError.connectionFailed` if not connected
     - Note: Updates the internal capabilities array with the server's response
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
	private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T, onTimeout: @escaping @Sendable () throws -> Void) async throws -> T {
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
