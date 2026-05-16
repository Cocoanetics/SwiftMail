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
    enum SMTPTransportMode: Sendable, Equatable {
        case implicitTLS
        case plainText
        case startTLSIfAvailable
        case startTLSRequired
    }

    // MARK: - Properties

    /** The hostname of the SMTP server */
    let host: String

    /** The port number of the SMTP server */
    let port: Int

    /** The requested SMTP transport security policy */
    let transportSecurity: MailTransportSecurity

    /** The certificate verification policy for TLS connections */
    let certificateVerificationPolicy: MailCertificateVerificationPolicy

    /** The event loop group for handling asynchronous operations */
    let group: EventLoopGroup

    /** The channel for communication with the server */
    var channel: Channel?

    /** Flag indicating whether TLS is enabled for the connection */
    var isTLSEnabled = false

    /** Server capabilities reported by EHLO command */
    var capabilities: [String] = []

    /// Whether the server advertised the `8BITMIME` extension in the most recent EHLO response.
    public var supports8BitMIME: Bool {
        capabilities.contains("8BITMIME")
    }

    /// The server-advertised RFC 1870 `SIZE` limit from the most recent EHLO response, if present.
    public var maximumMessageSizeOctets: Int? {
        Self.maximumMessageSizeOctets(from: capabilities)
    }

    struct PreparedEmailForSend {
        let use8BitMIME: Bool
        let contentData: Data
        let emailSizeOctets: Int
        let mailFromMessageSizeOctets: Int?
    }

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
    let logger = Logger(label: "com.cocoanetics.SwiftMail.SMTPServer")

    /**
     A logger that monitors both inbound and outbound SMTP traffic

     This logger captures the raw SMTP protocol communication in both directions:
     - Outbound: Commands sent to the server
     - Inbound: Responses received from the server

     Sensitive information like passwords and authentication tokens is automatically
     redacted in the logs.
     */
    let duplexLogger: SMTPLogger

    // MARK: - Initialization

    /**
     Initialize a new SMTP server connection

     - Parameters:
       - host: The hostname of the SMTP server
       - port: The port number of the SMTP server
       - transportSecurity: The transport security policy to use for this connection
       - certificateVerificationPolicy: The certificate verification policy to use for TLS connections
       - numberOfThreads: The number of threads to use for the event loop group

     `.automatic` infers the initial security mode from the port:
     - Port 25: Plain SMTP (not recommended)
     - Port 587: STARTTLS (recommended)
     - Port 465: SMTPS (implicit TLS)
     Passing an explicit `transportSecurity` value overrides this port-inferred behavior.

     - Note: Logs initialization at debug level with connection details
     */
    public init(
        host: String,
        port: Int,
        transportSecurity: MailTransportSecurity = .automatic,
        certificateVerificationPolicy: MailCertificateVerificationPolicy = .fullVerification,
        numberOfThreads: Int = 1
    ) {
        self.host = host
        self.port = port
        self.transportSecurity = transportSecurity
        self.certificateVerificationPolicy = certificateVerificationPolicy
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)

		let outboundLogger = Logger(label: "com.cocoanetics.SwiftMail.SMTP_OUT")
		let inboundLogger = Logger(label: "com.cocoanetics.SwiftMail.SMTP_IN")

		self.duplexLogger = SMTPLogger(outboundLogger: outboundLogger, inboundLogger: inboundLogger)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Command Execution

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
    @discardableResult
    func executeCommand<CommandType: SMTPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        // Ensure we have a valid channel
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }

        try command.validate()

        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        let commandTag = UUID().uuidString
        let commandData = command.toCommandData()
        let handler = makeCommandHandler(for: command, commandTag: commandTag, resultPromise: resultPromise)

        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(command.timeoutSeconds))) {
            resultPromise.fail(SMTPError.connectionFailed("Response timeout"))
        }

        do {
            try await channel.pipeline.addHandler(handler).get()

            // Send the command to the server as raw bytes + CRLF
            var buffer = channel.allocator.buffer(capacity: commandData.count + 2)
            buffer.writeBytes(commandData)
            buffer.writeBytes([0x0D, 0x0A]) // CRLF
            try await channel.writeAndFlush(buffer).get()

            let result = try await resultPromise.futureResult.get()
            scheduledTask.cancel()
            duplexLogger.flushInboundBuffer()
            return result
        } catch {
            scheduledTask.cancel()
            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            resultPromise.fail(error)
            if error is SMTPError {
                throw error
            } else {
                throw SMTPError.connectionFailed("Command failed: \(error.localizedDescription)")
            }
        }
    }

    /// Build the handler for the given command, applying special-case wiring for `LoginAuthCommand`.
    private func makeCommandHandler<CommandType: SMTPCommand>(
        for command: CommandType,
        commandTag: String,
        resultPromise: EventLoopPromise<CommandType.ResultType>
    ) -> any SMTPCommandHandler {
        // Special case for LoginAuthHandler which needs the command parameters.
        // LoginAuthCommand's result type is AuthResult, so this cast is guaranteed.
        if let loginCommand = command as? LoginAuthCommand {
            // swiftlint:disable:next force_cast
            let authPromise = resultPromise as! EventLoopPromise<AuthResult>
            return LoginAuthHandler(
                commandTag: commandTag,
                promise: authPromise,
                command: loginCommand
            )
        }
        return CommandType.HandlerType(commandTag: commandTag, promise: resultPromise)
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
    func executeHandlerOnly<T: Sendable, HandlerType: SMTPCommandHandler>(
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
     Execute an async operation with a timeout
     - Parameters:
        - seconds: The timeout in seconds
        - operation: The async operation to execute
        - onTimeout: The closure to execute on timeout
     - Returns: The result of the operation
     - Throws: An error if the operation fails or times out
     */
	private func withTimeout<T: Sendable>(
		seconds: TimeInterval,
		operation: @escaping @Sendable () async throws -> T,
		onTimeout: @escaping @Sendable () throws -> Void
	) async throws -> T {
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
