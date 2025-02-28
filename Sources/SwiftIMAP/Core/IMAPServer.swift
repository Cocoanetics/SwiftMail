// IMAPServer.swift
// A Swift IMAP client that encapsulates connection logic

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL
import NIOConcurrencyHelpers

/** An actor that represents an IMAP server connection */
public actor IMAPServer {
    // MARK: - Properties
    
    /** The hostname of the IMAP server */
    private let host: String
    
    /** The port number of the IMAP server */
    private let port: Int
    
    /** The event loop group for handling asynchronous operations */
    private let group: EventLoopGroup
    
    /** The channel for communication with the server */
    private var channel: Channel?
    
    /** Counter for generating unique command tags */
    private var commandTagCounter: Int = 0
    
    /**
     Logger for IMAP operations
     To view these logs in Console.app:
     1. Open Console.app
     2. In the search field, type "process:com.cocoanetics.SwiftIMAP"
     3. You may need to adjust the "Action" menu to show "Include Debug Messages" and "Include Info Messages"
     */
    private let logger = Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "IMAPServer")
    
    /** Logger for outgoing IMAP commands */
    private let outboundLogger = Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "IMAP OUT")
    
    /** Logger for incoming IMAP responses */
    private let inboundLogger = Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "IMAP IN")
    
    // MARK: - Initialization
    
    /**
     Initialize a new IMAP server connection
     - Parameters:
       - host: The hostname of the IMAP server
       - port: The port number of the IMAP server
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
    
    // MARK: - Commands
    
    /**
     Connect to the IMAP server
     - Returns: A boolean indicating whether the connection was successful
     - Throws: An error if the connection fails
     */
    public func connect() async throws {
        // Create SSL context for secure connection
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        
        // Capture the host as a local variable to avoid capturing self
        let host = self.host
        
        // Create the bootstrap
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let sslHandler = try! NIOSSLClientHandler(context: sslContext, serverHostname: host)
                
                // Create the IMAP client pipeline
                return channel.pipeline.addHandlers([
                    sslHandler,
                    IMAPClientHandler(),
                    OutboundLogger(logger: self.outboundLogger)
                ])
            }
        
        // Connect to the server
        let channel = try await bootstrap.connect(host: host, port: port).get()
        
        // Store the channel
        self.channel = channel
        
        // Wait for the server greeting using our generic handler execution pattern
        try await executeHandlerOnly(handlerType: GreetingHandler.self, timeoutSeconds: 5)
    }
    
    /**
     Login to the IMAP server
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
     - Throws: An error if the login fails
     */
    public func login(username: String, password: String) async throws {
        let command = LoginCommand(username: username, password: password)
        try await executeCommand(command)
    }
    
    /**
     Select a mailbox
     - Parameter mailboxName: The name of the mailbox to select
     - Returns: Information about the selected mailbox
     - Throws: An error if the select operation fails
     */
    public func selectMailbox(_ mailboxName: String) async throws -> MailboxInfo {
        let command = SelectMailboxCommand(mailboxName: mailboxName)
        return try await executeCommand(command)
    }
    
    /**
     Logout from the IMAP server
     - Throws: An error if the logout fails
     */
    public func logout() async throws {
        let command = LogoutCommand()
        try await executeCommand(command)
    }
    
    /**
     Close the connection to the IMAP server
     - Throws: An error if the close operation fails
     */
    public func close() async throws {
        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        // Close the connection
        do {
            try await channel.close().get()
        } catch let error as NIOCore.ChannelError where error == .alreadyClosed {
            // Channel is already closed, which is fine
        }
    }
    
    /**
     Fetch headers for messages in the selected mailbox
     - Parameters:
       - identifierSet: The set of message identifiers to fetch
       - limit: Optional limit on the number of headers to return
     - Returns: An array of email headers
     - Throws: An error if the fetch operation fails
     */
    public func fetchHeaders<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) async throws -> [EmailHeader] {
        let command = FetchHeadersCommand(identifierSet: identifierSet, limit: limit)
        var headers = try await executeCommand(command)
        
        // Apply limit if specified
        if let limit = limit, headers.count > limit {
            headers = Array(headers.prefix(limit))
        }
        
        return headers
    }
    
    /**
     Fetch a specific part of a message
     - Parameters:
       - identifier: The message identifier (SequenceNumber or UID)
       - sectionPath: The section path to fetch as an array of integers (e.g., [1], [1, 1], [2], etc.)
     - Returns: The content of the message part as Data
     - Throws: An error if the fetch operation fails
     */
    public func fetchMessagePart<T: MessageIdentifier>(identifier: T, sectionPath: [Int]) async throws -> Data {
        let command = FetchMessagePartCommand(identifier: identifier, sectionPath: sectionPath)
        return try await executeCommand(command)
    }
    
    /**
     Fetch the structure of a message to determine its parts
     - Parameter identifier: The message identifier (SequenceNumber or UID)
     - Returns: The body structure of the message
     - Throws: An error if the fetch operation fails
     */
    public func fetchMessageStructure<T: MessageIdentifier>(identifier: T) async throws -> BodyStructure {
        let command = FetchStructureCommand(identifier: identifier)
        return try await executeCommand(command)
    }
    
    /**
     Fetch all parts of a message
     - Parameter identifier: The message identifier (SequenceNumber or UID)
     - Returns: An array of message parts
     - Throws: An error if the fetch operation fails
     */
    public func fetchAllMessageParts<T: MessageIdentifier>(identifier: T) async throws -> [MessagePart] {
        // First, fetch the message structure to determine the parts
        let structure = try await fetchMessageStructure(identifier: identifier)
        
        // Process the structure recursively and return the parts
        return try await recursivelyFetchParts(structure, sectionPath: [], identifier: identifier)
    }
    
    /**
     Process a body structure recursively to fetch all parts
     - Parameters:
       - structure: The body structure to process
       - sectionPath: Array of integers representing the hierarchical section path
       - identifier: The message identifier (SequenceNumber or UID)
     - Returns: An array of message parts
     - Throws: An error if the fetch operation fails
     */
    private func recursivelyFetchParts<T: MessageIdentifier>(_ structure: BodyStructure, sectionPath: [Int], identifier: T) async throws -> [MessagePart] {
        switch structure {
        case .singlepart(let part):
            // Determine the part number string for IMAP (e.g., "1.2.3")
            let partNumberString = sectionPath.isEmpty ? "1" : sectionPath.map { String($0) }.joined(separator: ".")
            
            // Fetch the part content
            let partData = try await fetchMessagePart(identifier: identifier, sectionPath: sectionPath.isEmpty ? [1] : sectionPath)
            
            // Extract content type and other metadata
            var contentType = ""
            var contentSubtype = ""
            
            switch part.kind {
            case .basic(let mediaType):
                contentType = String(mediaType.topLevel)
                contentSubtype = String(mediaType.sub)
            case .text(let text):
                contentType = "text"
                contentSubtype = String(text.mediaSubtype)
            case .message(let message):
                contentType = "message"
                contentSubtype = String(message.message)
            }
            
            // Extract disposition and filename if available
            var disposition: String? = nil
            var filename: String? = nil
            
            if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage {
                if let disp = dispAndLang.disposition {
                    disposition = String(describing: disp)
                    
                    for (key, value) in disp.parameters {
                        if key.lowercased() == "filename" {
                            filename = value
                        }
                    }
                }
            }
            
            // Set content ID if available
            let contentId = part.fields.id
            
            // Create a message part
            let messagePart = MessagePart(
                partNumber: partNumberString,
                contentType: contentType,
                contentSubtype: contentSubtype,
                disposition: disposition,
                filename: filename,
                contentId: contentId,
                data: partData
            )
            
            // Return a single-element array with this part
            return [messagePart]
            
        case .multipart(let multipart):
            // For multipart messages, process each child part and collect results
            var allParts: [MessagePart] = []
            
            for (index, childPart) in multipart.parts.enumerated() {
                // Create a new section path array by appending the current index + 1
                let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]
                let childParts = try await recursivelyFetchParts(childPart, sectionPath: childSectionPath, identifier: identifier)
                allParts.append(contentsOf: childParts)
            }
            
            return allParts
        }
    }
    
    /**
     Fetch a complete email with all parts from an email header
     - Parameter header: The email header to fetch the complete email for
     - Returns: A complete Email object with all parts
     - Throws: An error if the fetch operation fails
     */
    public func fetchEmail(from header: EmailHeader) async throws -> Email {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if header.uid > 0 {
            // Use UID for fetching
            let uid = UID(UInt32(header.uid))
            let parts = try await fetchAllMessageParts(identifier: uid)
            return Email(header: header, parts: parts)
        } else {
            // Fall back to sequence number
            let sequenceNumber = SequenceNumber(UInt32(header.sequenceNumber))
            let parts = try await fetchAllMessageParts(identifier: sequenceNumber)
            return Email(header: header, parts: parts)
        }
    }
    
    /**
     Fetch complete emails with all parts using a message identifier set
     - Parameters:
       - identifierSet: The set of message identifiers to fetch
       - limit: Optional limit on the number of emails to fetch
     - Returns: An array of Email objects with all parts
     - Throws: An error if the fetch operation fails
     */
    public func fetchEmails<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) async throws -> [Email] {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
        
        // First fetch the headers
        let headers = try await fetchHeaders(using: identifierSet, limit: limit)
        
        // Then fetch the complete email for each header
        var emails: [Email] = []
        for header in headers {
            let email = try await fetchEmail(from: header)
            emails.append(email)
        }
        
        return emails
    }
    
    /**
     Move messages from the current mailbox to another mailbox
     - Parameters:
       - identifierSet: The set of message identifiers to move
       - destinationMailbox: The name of the destination mailbox
     - Throws: An error if the move operation fails
     */
    public func moveMessages<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        let command = MoveCommand(identifierSet: identifierSet, destinationMailbox: destinationMailbox)
        try await executeCommand(command)
    }
    
    /**
     Move a single message from the current mailbox to another mailbox
     - Parameters:
       - identifier: The message identifier to move
       - destinationMailbox: The name of the destination mailbox
     - Throws: An error if the move operation fails
     */
    public func moveMessage<T: MessageIdentifier>(identifier: T, to destinationMailbox: String) async throws {
        let set = MessageIdentifierSet<T>(identifier)
        try await moveMessages(using: set, to: destinationMailbox)
    }
    
    /**
     Move an email identified by its header from the current mailbox to another mailbox
     - Parameters:
       - header: The email header of the message to move
       - destinationMailbox: The name of the destination mailbox
     - Throws: An error if the move operation fails
     */
    public func moveEmail(from header: EmailHeader, to destinationMailbox: String) async throws {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if header.uid > 0 {
            // Use UID for moving
            let uid = UID(UInt32(header.uid))
            try await moveMessage(identifier: uid, to: destinationMailbox)
        } else {
            // Fall back to sequence number
            let sequenceNumber = SequenceNumber(UInt32(header.sequenceNumber))
            try await moveMessage(identifier: sequenceNumber, to: destinationMailbox)
        }
    }
    
    // MARK: - Helpers
    
    /**
     Execute an IMAP command
     - Parameter command: The command to execute
     - Returns: The result of executing the command
     - Throws: An error if the command execution fails
     */
	private func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        // Validate the command before execution
        try command.validate()

        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }

        // Generate a unique command tag
        let tag = generateCommandTag()

        // Convert the command into a TaggedCommand
        let taggedCommand = command.toTaggedCommand(tag: tag)

        // Create a promise for the command's result
        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)

        // Instantiate the appropriate handler for the command
        let handler = command.handlerType.createHandler(
            commandTag: tag,
            promise: resultPromise,
            timeoutSeconds: command.timeoutSeconds,
            logger: inboundLogger
        )

        // Add the handler to the channel pipeline
        try await channel.pipeline.addHandler(handler).get()

        // Write the command to the channel wrapped as CommandStreamPart
        try await channel.writeAndFlush(CommandStreamPart.tagged(taggedCommand)).get()

        // Await the result from the promise
        do {
            let result = try await resultPromise.futureResult.get()
            handler.cancelTimeout()
            return result
        } catch {
            handler.cancelTimeout()
            throw error
        }
    }
    
    /**
     Execute a handler without sending a command (for server-initiated responses like greeting)
     - Parameters:
       - handlerType: The type of handler to use
       - timeoutSeconds: The timeout in seconds
     - Returns: The result from the handler
     - Throws: An error if the operation fails
     */
    private func executeHandlerOnly<T, HandlerType: IMAPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        // Create a promise for the result
        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        
        // Create the handler
        let handler = HandlerType.createHandler(
            commandTag: "",  // No command tag needed for server-initiated responses
            promise: resultPromise,
            timeoutSeconds: timeoutSeconds,
            logger: inboundLogger
        )
        
        // Add the handler to the pipeline
        try await channel.pipeline.addHandler(handler).get()
        
        // Wait for the result
        do {
            let result = try await resultPromise.futureResult.get()
            handler.cancelTimeout()
            return result
        } catch {
            handler.cancelTimeout()
            throw error
        }
    }
    
    /**
     Generate a unique command tag
     - Returns: A unique command tag string
     */
    private func generateCommandTag() -> String {
        // Simple implementation with a consistent prefix
        let tagPrefix = "A"
        
        // Increment the counter directly - actor isolation ensures thread safety
        commandTagCounter += 1
        
        return "\(tagPrefix)\(String(format: "%03d", commandTagCounter))"
    }
}
