import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL
import NIOConcurrencyHelpers
import OrderedCollections

/**
 An actor that represents a connection to an IMAP server.
 
 Use this class to establish and manage connections to IMAP servers, perform authentication,
 and execute IMAP commands. The class handles connection lifecycle, command execution,
 and maintains server state.
 
 Example:
 ```swift
 let server = IMAPServer(host: "imap.example.com", port: 993)
 try await server.connect()
 try await server.login(username: "user@example.com", password: "password")
 ```
 
 - Note: All operations are logged using the Swift Logging package. To view logs in Console.app:
 1. Open Console.app
 2. Search for "process:com.cocoanetics.SwiftMail"
 3. Adjust the "Action" menu to show Debug and Info messages
 */
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
    
    /** Server capabilities */
    private var capabilities: Set<NIOIMAPCore.Capability> = []
    
    /** The list of all mailboxes with their attributes */
    public private(set) var mailboxes: [Mailbox.Info] = []
    
    /** Special folders - mailboxes with SPECIAL-USE attributes */
    public private(set) var specialMailboxes: [Mailbox.Info] = []
    
    /// Namespaces discovered from the server
    public private(set) var namespaces: Namespace.Response?
    
    /// Active handler managing an IDLE session, if any
    private var idleHandler: IdleHandler?
    
    /// Flag to prevent concurrent IDLE termination operations
    private var idleTerminationInProgress: Bool = false
    
    /**
     Logger for IMAP operations
     To view these logs in Console.app:
     1. Open Console.app
     2. In the search field, type "process:com.cocoanetics.SwiftIMAP"
     3. You may need to adjust the "Action" menu to show "Include Debug Messages" and "Include Info Messages"
     */
    private let logger: Logging.Logger
    
    // A logger on the channel that watches both directions
    private let duplexLogger: IMAPLogger
    
    // MARK: - Initialization
    
    /**
     Initialize a new IMAP server connection
     
     - Parameters:
     - host: The hostname of the IMAP server
     - port: The port number of the IMAP server (typically 993 for SSL)
     - numberOfThreads: The number of threads to use for the event loop group
     
     - Note: The connection is configured with a 1MB buffer limit to handle large SEARCH responses
     that may contain thousands of message IDs. This prevents PayloadTooLargeError when
     searching large mailboxes.
     */
    public init(host: String, port: Int, numberOfThreads: Int = 1) {
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
        
        // Initialize loggers
        self.logger = Logging.Logger(label: "com.cocoanetics.SwiftMail.IMAPServer")
        
        let outboundLogger = Logging.Logger(label: "com.cocoanetics.SwiftMail.IMAP_OUT")
        let inboundLogger = Logging.Logger(label: "com.cocoanetics.SwiftMail.IMAP_IN")
        
        self.duplexLogger = IMAPLogger(outboundLogger: outboundLogger, inboundLogger: inboundLogger)
    }
    
    deinit {
        // Schedule shutdown on a background thread to avoid EventLoop issues
        Task {  @MainActor [group] in
            try? await group.shutdownGracefully()
        }
    }
    
    // MARK: - Connection and Login Commands
    
    /**
     Connect to the IMAP server using SSL/TLS
     
     This method establishes a secure connection to the IMAP server and retrieves
     its capabilities. The connection is made using SSL/TLS and includes setting up
     the necessary handlers for IMAP protocol communication.
     
     - Throws:
     - `IMAPError.connectionFailed` if the connection cannot be established
     - `NIOSSLError` if SSL/TLS negotiation fails
     - Note: Logs connection attempts and capability retrieval at info level
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
                
                // Create the IMAP client pipeline with increased buffer limits for large responses
                let parserOptions = ResponseParser.Options(
                    bufferLimit: 1024 * 1024, // 1MB buffer limit for large SEARCH responses
                    messageAttributeLimit: .max,
                    bodySizeLimit: .max,
                    literalSizeLimit: IMAPDefaults.literalSizeLimit
                )
                
                try! channel.pipeline.syncOperations.addHandlers([
                    sslHandler,
                    IMAPClientHandler(parserOptions: parserOptions),
                    self.duplexLogger
                ])
                
                return channel.eventLoop.makeSucceededFuture(())
            }
        
        // Connect to the server
        let channel = try await bootstrap.connect(host: host, port: port).get()
        
        // Store the channel
        self.channel = channel
        
        logger.info("Connected to IMAP server with 1MB buffer limit for large responses")
        
        // Wait for the server greeting using our generic handler execution pattern
        // The greeting handler now returns capabilities if they were in the greeting
        let greetingCapabilities: [Capability] = try await executeHandlerOnly(handlerType: IMAPGreetingHandler.self, timeoutSeconds: 5)
        
        // If we got capabilities from the greeting, use them
        if !greetingCapabilities.isEmpty {
            self.capabilities = Set(greetingCapabilities)
        } else {
            // Otherwise, fetch capabilities explicitly
            try await fetchCapabilities()
        }
    }
    
    /**
     Fetch server capabilities
     
     This method explicitly requests the server's capabilities. It's called automatically
     after connection and login, but can be called manually if needed.
     
     - Throws: An error if the capability command fails
     - Returns: An array of server capabilities
     - Note: Updates the internal capabilities set with the server's response
     */
    @discardableResult public func fetchCapabilities() async throws -> [Capability] {
        let command = CapabilityCommand()
        let serverCapabilities = try await executeCommand(command)
        self.capabilities = Set(serverCapabilities)
        return serverCapabilities
    }
    
    /**
     Check if the server supports a specific capability
     - Parameter capability: The capability to check for
     - Returns: True if the server supports the capability
     */
    private func supportsCapability(_ check: (Capability) -> Bool) -> Bool {
        return capabilities.contains(where: check)
    }
    
    /**
     Check if the connection to the IMAP server is currently active
     - Returns: True if the connection is active and ready for commands
     */
    public var isConnected: Bool {
        guard let channel = self.channel else {
            return false
        }
        return channel.isActive
    }
    
    /**
     Login to the IMAP server
     
     This method authenticates with the IMAP server using the provided credentials.
     After successful login, it updates the server capabilities as they may change
     after authentication.
     
     - Parameters:
     - username: The username for authentication
     - password: The password for authentication
     - Throws:
     - `IMAPError.loginFailed` if authentication fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs login attempts at info level (without credentials)
     */
    public func login(username: String, password: String) async throws {
        let command = LoginCommand(username: username, password: password)
        let loginCapabilities = try await executeCommand(command)
        
        // If we got capabilities from the login response, use them
        if !loginCapabilities.isEmpty {
            self.capabilities = Set(loginCapabilities)
        } else {
            // Otherwise, fetch capabilities explicitly
            try await fetchCapabilities()
        }
    }
    
    /// Identify the client to the server using the `ID` command.
    /// - Parameter identification: Information describing the client. Pass the default value to send no information.
    /// - Returns: Information returned by the server.
    /// - Throws: ``IMAPError.commandNotSupported`` if the server does not support the command or ``IMAPError.commandFailed`` on failure.
    public func id(_ identification: Identification = Identification()) async throws -> Identification {
        guard capabilities.contains(.id) else {
            throw IMAPError.commandNotSupported("ID command not supported by server")
        }
        
        let command = IDCommand(identification: identification)
        return try await executeCommand(command)
    }
    
    /**
     Disconnect from the server without sending a command
     
     This method immediately closes the connection to the server without sending
     a LOGOUT command. For a graceful disconnect, use logout() instead.
     
     - Throws: An error if the disconnection fails
     - Note: Logs disconnection at debug level
     */
    public func disconnect() async throws
    {
        guard let channel = self.channel else {
            logger.warning("Attempted to disconnect when channel was already nil")
            return
        }
        
        channel.close(promise: nil)
        self.channel = nil
    }
    
    // MARK: - Mailbox Commands
    
    /**
     Select a mailbox
     
     This method selects a mailbox and makes it the current mailbox for subsequent
     operations. Only one mailbox can be selected at a time.
     
     - Parameter mailboxName: The name of the mailbox to select
     - Returns: Status information about the selected mailbox
     - Throws:
     - `IMAPError.selectFailed` if the mailbox cannot be selected
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox selection at debug level
     - Important: The returned status does not include an unseen count, as this is not provided by the IMAP SELECT command.
     To get the count of unseen messages, use `mailboxStatus("INBOX").unseenCount` instead.
     */
    @discardableResult public func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Status {
        let command = SelectMailboxCommand(mailboxName: mailboxName)
        return try await executeCommand(command)
    }
    
    /**
     Close the currently selected mailbox
     
     This method closes the currently selected mailbox and expunges any messages
     marked for deletion. To close without expunging, use unselectMailbox() instead.
     
     - Throws:
     - `IMAPError.closeFailed` if the close operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox closure at debug level
     */
    public func closeMailbox() async throws {
        let command = CloseCommand()
        try await executeCommand(command)
    }
    
    /**
     Unselect the currently selected mailbox without expunging deleted messages
     
     This is an IMAP extension command (RFC 3691) that might not be supported by all servers.
     If the server does not support UNSELECT, an IMAPError will be thrown.
     
     - Throws:
     - `IMAPError.commandNotSupported` if UNSELECT is not supported
     - `IMAPError.unselectFailed` if the unselect operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox unselection at debug level
     */
    public func unselectMailbox() async throws {
        // Check if the server supports UNSELECT capability
        if !capabilities.contains(.unselect) {
            throw IMAPError.commandNotSupported("UNSELECT command not supported by server")
        }
        
        let command = UnselectCommand()
        try await executeCommand(command)
    }
    
    // MARK: - Idle
    
    /// Begin an IDLE session and receive server events
    ///
    /// **Manual Cleanup**: When cancelling IDLE tasks, call `done()` in your cancellation
    ///   handlers to properly terminate the IDLE session. The actor ensures all calls
    ///   are serialized, preventing race conditions.
    ///
    /// - Important: If you receive a `.bye` event, the server is terminating the entire
    ///   connection, not just the IDLE session. You should stop processing the stream
    ///   immediately, as the connection will be closed by the server.
    ///
    /// - Returns: An AsyncStream of server events during the IDLE session
    /// - Throws: IMAPError if IDLE is not supported or already active
    public func idle() async throws -> AsyncStream<IMAPServerEvent> {
        // Ensure the server advertises IDLE support
        if !capabilities.contains(.idle) {
            throw IMAPError.commandNotSupported("IDLE command not supported by server")
        }
        
        guard idleHandler == nil else {
            throw IMAPError.commandFailed("IDLE session already active")
        }
        
        // Ensure clean state for new IDLE session
        idleTerminationInProgress = false
        
        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        var continuationRef: AsyncStream<IMAPServerEvent>.Continuation!
        let stream = AsyncStream<IMAPServerEvent> { continuation in
            continuationRef = continuation
            
            // Note: No automatic cleanup on termination to avoid actor isolation issues
            // Users should call done() in their cancellation handlers or rely on disconnect() cleanup
        }
        
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let tag = generateCommandTag()
        let handler = IdleHandler(commandTag: tag, promise: promise, continuation: continuationRef)
        idleHandler = handler
        
        try await channel.pipeline.addHandler(handler).get()
        let command = IdleCommand()
        let tagged = command.toTaggedCommand(tag: tag)
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped).get()
        
        return stream
    }
    
    /// Terminate the current IDLE session
    ///
    /// **Note**: Call this method in cancellation handlers to properly clean up IDLE sessions.
    ///   The actor ensures this is safe to call even during rapid cancellation/restart cycles.
    ///
    /// This method is safe to call even if the server has already terminated the IDLE session
    /// (e.g., by sending a BYE response) or if automatic cleanup has already occurred.
    public func done() async throws {
        // Only send DONE if there's an active IDLE handler
        guard let handler = idleHandler else {
            logger.debug("No active IDLE session, skipping DONE command")
            return
        }
        
        guard let channel = self.channel else { return }
        
        // Prevent concurrent termination attempts
        guard !idleTerminationInProgress else {
            // Another termination is already in progress - wait for it to complete
            try await handler.promise.futureResult.get()
            return
        }
        
        idleTerminationInProgress = true
        
        defer {
            // Always clear the termination flag and handler when done
            idleTerminationInProgress = false
            idleHandler = nil
        }
        
        do {
            try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone)).get()
        } catch {
            // If writing fails (e.g., connection closed by server BYE), that's acceptable
            // since the IDLE session is already terminated
        }
        
        // Wait for server confirmation
        // If the server already terminated the session (e.g., via BYE),
        // the promise will already be fulfilled and this will return immediately
        try await handler.promise.futureResult.get()
    }
    
    /// Send a NOOP command and collect unsolicited responses.
    public func noop() async throws -> [IMAPServerEvent] {
        let command = NoopCommand()
        return try await executeCommand(command)
    }
    
    /**
     Logout from the IMAP server
     
     This method performs a clean logout from the server by sending the LOGOUT command
     and closing the connection. For an immediate disconnect, use disconnect() instead.
     
     - Throws:
     - `IMAPError.logoutFailed` if the logout fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs logout at info level
     */
    public func logout() async throws {
        let command = LogoutCommand()
        try await executeCommand(command)
    }
    
    // MARK: - Message Commands
    
    /**
     Fetches the structure of a message.
     
     The message structure includes information about MIME parts, attachments,
     and the overall organization of the message content.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - identifier: The identifier of the message to fetch
     - Returns: The message's body parts
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     - Note: Logs structure fetch at debug level
     */
    public func fetchStructure<T: MessageIdentifier>(_ identifier: T) async throws -> [MessagePart] {
        let command = FetchStructureCommand(identifier: identifier)
        return try await executeCommand(command)
    }
    
    /**
     Fetches a specific part of a message.
     
     Use this method to retrieve specific MIME parts of a message, such as
     the text body, HTML content, or attachments.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - section: The part number to fetch (e.g., "1", "1.1", "2")
     - identifier: The identifier of the message
     - Returns: The content of the requested message part
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     - Note: Logs part fetch at debug level with part number
     */
    public func fetchPart<T: MessageIdentifier>(section: Section, of identifier: T) async throws -> Data {
        let command = FetchMessagePartCommand(identifier: identifier, section: section)
        return try await executeCommand(command)
    }
    
    /**
     Fetch all message parts and their data for a message
     - Parameter identifier: The message identifier (UID or sequence number)
     - Returns: An array of message parts with their data populated
     - Throws: IMAPError if any fetch operation fails
     */
    public func fetchAllMessageParts<T: MessageIdentifier>(identifier: T) async throws -> [MessagePart] {
        
        var parts = try await fetchStructure(identifier)
        
        for (index, part) in parts.enumerated() {
            parts[index].data = try await self.fetchPart(section: part.section, of: identifier)
        }
        
        return parts
    }
    
    /**
     Fetches and decodes the data for a specific message part.
     
     This method will:
     1. Use the message's UID if available, falling back to sequence number if not
     2. Fetch the raw data for the specified part
     3. Automatically decode the data based on the part's content encoding
     
     - Parameters:
     - header: The message header containing the part
     - part: The message part to fetch, containing section and encoding information
     - Returns: The decoded data for the message part
     - Throws:
     - `IMAPError.fetchFailed` if the fetch operation fails
     - Decoding errors if the part's encoding cannot be processed
     */
    public func fetchAndDecodeMessagePartData(messageInfo: MessageInfo, part: MessagePart) async throws -> Data {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if let uid = messageInfo.uid {
            // Use UID for fetching
            return try await fetchPart(section: part.section, of: uid).decoded(for: part)
        } else {
            // Fall back to sequence number
            let sequenceNumber = messageInfo.sequenceNumber
            return try await fetchPart(section: part.section, of: sequenceNumber).decoded(for: part)
        }
    }
    
    /**
     Fetch a complete email with all parts from an email header
     
     - Parameter header: The email header to fetch the complete email for
     - Returns: A complete Email object with all parts
     - Throws: An error if the fetch operation fails
     - Note: This method will use UID if available in the header, falling back to sequence number if not
     */
    public func fetchMessage(from header: MessageInfo) async throws -> Message {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if let uid = header.uid {
            // Use UID for fetching
            let parts = try await fetchAllMessageParts(identifier: uid)
            return Message(header: header, parts: parts)
        } else {
            // Fall back to sequence number
            let sequenceNumber = header.sequenceNumber
            let parts = try await fetchAllMessageParts(identifier: sequenceNumber)
            return Message(header: header, parts: parts)
        }
    }
    
    /// Fetch message info for a single identifier
    /// - Parameter identifier: The message identifier to fetch
    /// - Returns: The message info if available
    public func fetchMessageInfo<T: MessageIdentifier>(for identifier: T) async throws -> MessageInfo? {
        let singleSet = MessageIdentifierSet<T>(identifier)
        let command = FetchMessageInfoCommand(identifierSet: singleSet)
        return try await executeCommand(command).first
    }
    
    /// Stream message headers for a set of identifiers
    /// - Parameter identifierSet: The set of message identifiers to fetch
    /// - Returns: An AsyncThrowingStream yielding MessageInfo one at a time
    public nonisolated func fetchMessageInfos<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>) -> AsyncThrowingStream<MessageInfo, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !identifierSet.isEmpty else {
                        throw IMAPError.emptyIdentifierSet
                    }
                    
                    for identifier in identifierSet.toArray() {
                        try Task.checkCancellation()
                        let singleSet = MessageIdentifierSet<T>(identifier)
                        let command = FetchMessageInfoCommand(identifierSet: singleSet)
                        let result = try await executeCommand(command)
                        for header in result {
                            continuation.yield(header)
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Fetch complete messages with all parts using a message identifier set as a stream
    ///
    /// This method returns an `AsyncThrowingStream` that yields complete `Message` objects one at a time.
    /// It uses `fetchMessageInfos` to get headers and then fetches all body parts for each message.
    /// The sequence supports cancellation, allowing the caller to stop fetching early
    /// without waiting for all messages to be downloaded.
    ///
    /// - Parameter identifierSet: The set of message identifiers to fetch
    /// - Returns: An `AsyncThrowingStream` yielding `Message` instances with all parts
    public nonisolated func fetchMessages<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>) -> AsyncThrowingStream<Message, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !identifierSet.isEmpty else {
                        throw IMAPError.emptyIdentifierSet
                    }

                    for try await header in fetchMessageInfos(using: identifierSet) {
                        try Task.checkCancellation()
                        let email = try await fetchMessage(from: header)
                        continuation.yield(email)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    
    
    /**
     Moves messages to another mailbox.
     
     This method attempts to use the MOVE extension if available, falling back to
     COPY+EXPUNGE if necessary.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - identifierSet: The set of messages to move
     - destinationMailbox: The name of the destination mailbox
     - Throws:
     - `IMAPError.moveFailed` if the move operation fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs move operations at info level with message count and destination
     */
    public func move<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        if capabilities.contains(.move) && (T.self != UID.self || capabilities.contains(.uidPlus)) {
            try await executeMove(messages: identifierSet, to: destinationMailbox)
        } else {
            // Fall back to COPY + DELETE + EXPUNGE
            try await copy(messages: identifierSet, to: destinationMailbox)
            try await store(flags: [.deleted], on: identifierSet, operation: .add)
            try await expunge()
        }
    }
    
    /**
     Move a single message from the current mailbox to another mailbox
     - Parameters:
     - message: The message identifier to move
     - destinationMailbox: The name of the destination mailbox
     - Throws: An error if the move operation fails
     */
    public func move<T: MessageIdentifier>(message identifier: T, to destinationMailbox: String) async throws {
        let set = MessageIdentifierSet<T>(identifier)
        try await move(messages: set, to: destinationMailbox)
    }
    
    /**
     Move an email identified by its header from the current mailbox to another mailbox
     - Parameters:
     - header: The email header of the message to move
     - destinationMailbox: The name of the destination mailbox
     - Throws: An error if the move operation fails
     */
    public func move(header: MessageInfo, to destinationMailbox: String) async throws {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if let uid = header.uid {
            // Use UID for moving
            try await move(message: uid, to: destinationMailbox)
        } else {
            // Fall back to sequence number
            let sequenceNumber = header.sequenceNumber
            try await move(message: sequenceNumber, to: destinationMailbox)
        }
    }
    
    /**
     Searches for messages matching the given criteria.
     
     This method performs a search in the selected mailbox using the provided criteria.
     Common search criteria include:
     - Text content (in subject, body, etc.)
     - Date ranges (before, on, since)
     - Flags (seen, answered, flagged, etc.)
     - Size ranges
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - identifierSet: Optional set of message identifiers to search within. If nil, searches all messages.
     - criteria: The search criteria to apply. Multiple criteria are combined with AND logic.
     - Returns: A set of message identifiers matching all the search criteria
     - Throws:
     - `IMAPError.searchFailed` if the search operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs search operations at debug level with criteria count and results count
     */
    public func search<T: MessageIdentifier>(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria]) async throws -> MessageIdentifierSet<T> {
        let command = SearchCommand(identifierSet: identifierSet, criteria: criteria)
        return try await executeCommand(command)
    }
    
    
    
    /**
     Get status information about a mailbox without selecting it
     
     This method uses the IMAP STATUS command to retrieve standard attributes of a mailbox
     without having to select it. It automatically requests standard attributes (MESSAGES,
     RECENT, UNSEEN) and optional attributes based on server capabilities.
     
     - Parameter mailboxName: The name of the mailbox to get status for
     - Returns: Status information about the mailbox
     - Throws:
     - `IMAPError.commandFailed` if the status operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs status retrieval at debug level
     - Important: Many servers emit a warning (e.g. `OK [CLIENTBUG] Status on selected mailbox`) when
     `STATUS` is issued for the currently selected mailbox. Call this method when no mailbox is selected
     (before `selectMailbox(_)`) or after `unselectMailbox()`/`closeMailbox()` to avoid the warning.
     */
    public func mailboxStatus(_ mailboxName: String) async throws -> NIOIMAPCore.MailboxStatus {
        // Always request standard attributes
        var attributes: [NIOIMAPCore.MailboxAttribute] = [
            .messageCount,
            .recentCount,
            .unseenCount
        ]
        
        // Add optional attributes based on server capabilities
        if capabilities.contains(.uidPlus) {
            attributes.append(.uidNext)
            attributes.append(.uidValidity)
        }
        if capabilities.contains(.condStore) {
            attributes.append(.highestModificationSequence)
        }
        if capabilities.contains(.objectID) {
            attributes.append(.mailboxID)
        }
        if capabilities.contains(.status(.size)) {
            attributes.append(.size)
        }
        if capabilities.contains(.mailboxSpecificAppendLimit) {
            attributes.append(.appendLimit)
        }
        
        let command = StatusCommand(mailboxName: mailboxName, attributes: attributes)
        return try await executeCommand(command)
    }
    
    /**
     Searches for messages matching the given criteria
     
     - Parameters:
     - identifierSet: The set of messages to copy
     - destinationMailbox: The name of the destination mailbox
     - Throws:
     - `IMAPError.copyFailed` if the copy operation fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs copy operations at info level with message count and destination
     */
    public func copy<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        let command = CopyCommand(identifierSet: identifierSet, destinationMailbox: destinationMailbox)
        try await executeCommand(command)
    }
    
    /**
     Updates flags on messages.
     
     This method can add, remove, or replace flags on messages. Common flags include:
     - \Seen (message has been read)
     - \Answered (message has been replied to)
     - \Flagged (message is marked important)
     - \Deleted (message is marked for deletion)
     - \Draft (message is a draft)
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - flags: The flags to modify
     - identifierSet: The set of messages to update
     - operation: The type of update operation (add, remove, or set)
     - Throws:
     - `IMAPError.storeFailed` if the flag update fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs flag updates at debug level with operation type and message count
     */
    public func store<T: MessageIdentifier>(flags: [Flag], on identifierSet: MessageIdentifierSet<T>, operation: StoreOperation) async throws {
        let storeData = StoreData.flags(flags, operation == .add ? .add : .remove)
        let command = StoreCommand(identifierSet: identifierSet, data: storeData)
        try await executeCommand(command)
    }
    
    /**
     Permanently removes messages marked for deletion.
     
     This method removes all messages with the \Deleted flag from the selected mailbox.
     The operation cannot be undone.
     
     - Throws: `IMAPError.expungeFailed` if the expunge operation fails
     - Note: Logs expunge operations at info level with number of messages removed
     */
    public func expunge() async throws {
        let command = ExpungeCommand()
        try await executeCommand(command)
    }
    
    /**
     Retrieve storage quota information for a quota root.
     
     - Parameter quotaRoot: The quota root to query. Defaults to the empty string.
     - Returns: The quota details for the specified root.
     - Throws:
     - `IMAPError.commandNotSupported` if the server does not advertise QUOTA support.
     - `IMAPError.commandFailed` if the command fails.
     */
    public func getQuota(quotaRoot: String = "") async throws -> Quota {
        guard supportsCapability({ $0 == .quota }) else {
            throw IMAPError.commandNotSupported("QUOTA command not supported by server")
        }
        
        let command = GetQuotaCommand(quotaRoot: quotaRoot)
        return try await executeCommand(command)
    }
    
    /// Retrieve quota information for a mailbox using GETQUOTAROOT.
    /// - Parameter mailboxName: The mailbox name to query. Uses "INBOX" if nil.
    /// - Returns: The quota details for the mailbox's quota root.
    /// - Throws: ``IMAPError.commandNotSupported`` if QUOTA is not supported or ``IMAPError.commandFailed`` on failure.
    public func getQuotaRoot(mailboxName: String? = nil) async throws -> Quota {
        guard supportsCapability({ $0 == .quota }) else {
            throw IMAPError.commandNotSupported("QUOTA command not supported by server")
        }
        
        let command = GetQuotaRootCommand(mailboxName: mailboxName)
        return try await executeCommand(command)
    }
    
    // MARK: - Sub-Commands
    
    /**
     Process a body structure recursively to fetch all parts
     - Parameters:
     - structure: The body structure to process
     - section: The section to process
     - identifier: The message identifier (SequenceNumber or UID)
     - Returns: An array of message parts
     - Throws: An error if the fetch operation fails
     */
    private func recursivelyFetchParts<T: MessageIdentifier>(_ structure: BodyStructure, section: Section, identifier: T) async throws -> [MessagePart] {
        switch structure {
            case .singlepart(let part):
                // Fetch the part content
                let partData = try await fetchPart(section: section, of: identifier)
                
                // Extract content type
                var contentType = ""
                
                switch part.kind {
                    case .basic(let mediaType):
                        contentType = "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
                    case .text(let text):
                        contentType = "text/\(String(text.mediaSubtype))"
                    case .message(let message):
                        contentType = "message/\(String(message.message))"
                }
                
                // Add charset parameter if present
                if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
                    contentType += "; charset=\(charset)"
                }
                
                // Extract disposition and filename if available
                var disposition: String? = nil
                var filename: String? = nil
                let encoding: String? = part.fields.encoding?.debugDescription
                
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
                    section: section,
                    contentType: contentType,
                    disposition: disposition,
                    encoding: encoding,
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
                    // Create a new section by appending the current index + 1
                    let childSection = Section(section.components + [index + 1])
                    let childParts = try await recursivelyFetchParts(childPart, section: childSection, identifier: identifier)
                    allParts.append(contentsOf: childParts)
                }
                
                return allParts
        }
    }
    
    // MARK: - Command Helpers
    
    /// Check untagged responses for BYE/FATAL and auto-disconnect if found
    /// - Parameter untaggedResponses: Array of untagged responses to check
    fileprivate func handleConnectionTerminationInResponses(_ untaggedResponses: [Response]) async {
        for response in untaggedResponses {
            if case .untagged(let payload) = response,
               case .conditionalState(let status) = payload,
               case .bye = status {
                // Server sent BYE - disconnect automatically
                try? await self.disconnect()
                break
            }
            if case .fatal = response {
                // Server sent FATAL - disconnect automatically
                try? await self.disconnect()
                break
            }
        }
    }
    
    /**
     Execute an IMAP command
     - Parameter command: The command to execute
     - Returns: The result of executing the command
     - Throws: An error if the command execution fails
     */
    private func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        // Validate the command before execution
        try command.validate()
        
        // Check if channel is invalid and clear it
        clearInvalidChannel()
        
        // Check if channel is nil and re-establish connection if needed
        if self.channel == nil {
            logger.info("Channel is nil, re-establishing connection before sending command")
            try await connect()
        }
        
        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        // Create a promise for the command result
        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        
        // Generate a unique tag for the command
        let tag = generateCommandTag()
        
        // Create the handler for this command
        let handler = CommandType.HandlerType.init(commandTag: tag, promise: resultPromise)

        // Configure handler with expected identifiers when possible
        if let partHandler = handler as? FetchPartHandler {
            if let fetchCommand = command as? FetchMessagePartCommand<UID> {
                partHandler.expectedUID = fetchCommand.identifier
            } else if let fetchCommand = command as? FetchMessagePartCommand<SequenceNumber> {
                partHandler.expectedSequence = fetchCommand.identifier
            }
        }
        
        // Get timeout value for this command
        let timeoutSeconds = command.timeoutSeconds
        
        // Create a timeout for the command
        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            self.logger.warning("Command timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }
        
        do {
            // Add the handler to the channel pipeline
            try await channel.pipeline.addHandler(handler).get()
            
            // Write the command to the channel wrapped as CommandStreamPart
            let taggedCommand = command.toTaggedCommand(tag: tag)
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(taggedCommand))
            try await channel.writeAndFlush(wrapped).get()
            
            // Wait for the result
            let result = try await resultPromise.futureResult.get()
            
            // Cancel the timeout
            scheduledTask.cancel()
            
            // Check for BYE responses in untagged responses and auto-disconnect
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            
            // Flush the DuplexLogger's buffer after command execution
            duplexLogger.flushInboundBuffer()
            
            return result
        } catch {
            // Cancel the timeout
            scheduledTask.cancel()
            
            // Check for BYE responses even when command failed and auto-disconnect
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            
            // Flush the DuplexLogger's buffer even if there was an error
            duplexLogger.flushInboundBuffer()
            
            resultPromise.fail(error)
            
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
    private func executeHandlerOnly<T: Sendable, HandlerType: IMAPCommandHandler>(
        handlerType: HandlerType.Type,
        timeoutSeconds: Int = 5
    ) async throws -> T where HandlerType.ResultType == T {
        // Check if channel is invalid and clear it
        clearInvalidChannel()
        
        // Check if channel is nil and re-establish connection if needed
        if self.channel == nil {
            logger.info("Channel is nil, re-establishing connection before executing handler")
            try await connect()
        }
        
        guard let channel = self.channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        // Create the handler promise
        let resultPromise = channel.eventLoop.makePromise(of: T.self)
        
        // Create the handler directly
        let handler = HandlerType.init(commandTag: "", promise: resultPromise)
        
        // Create a timeout for the handler
        let scheduledTask = group.next().scheduleTask(in: .seconds(Int64(timeoutSeconds))) {
            self.logger.warning("Handler execution timed out after \(timeoutSeconds) seconds")
            resultPromise.fail(IMAPError.timeout)
        }
        
        do {
            // Add the handler to the pipeline
            try await channel.pipeline.addHandler(handler).get()
            
            // Wait for the result
            let result = try await resultPromise.futureResult.get()
            
            // Cancel the timeout
            scheduledTask.cancel()
            
            // Check for BYE responses in untagged responses and auto-disconnect
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            
            // Flush the DuplexLogger's buffer after command execution
            duplexLogger.flushInboundBuffer()
            
            return result
        } catch {
            // Cancel the timeout
            scheduledTask.cancel()
            
            // Check for BYE responses even when handler failed and auto-disconnect
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            
            // Flush the DuplexLogger's buffer even if there was an error
            duplexLogger.flushInboundBuffer()
            
            resultPromise.fail(error)
            
            throw error
        }
    }
    
    /**
     Clear the channel when it becomes invalid
     This method should be called when the channel becomes inactive or encounters errors
     */
    private func clearInvalidChannel() {
        if let channel = self.channel, !channel.isActive {
            logger.info("Channel is no longer active, clearing channel reference")
            self.channel = nil
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
    
    /**
     Execute a move command
     
     This method executes a move command using the MOVE extension.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameters:
     - identifierSet: The set of messages to move
     - destinationMailbox: The name of the destination mailbox
     - Throws:
     - `IMAPError.moveFailed` if the move operation fails
     - `IMAPError.emptyIdentifierSet` if the identifier set is empty
     - Note: Logs move operations at debug level
     */
    private func executeMove<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        let command = MoveCommand(identifierSet: identifierSet, destinationMailbox: destinationMailbox)
        try await executeCommand(command)
    }
}

// MARK: - Common Mail Operations
extension IMAPServer {
    /// Retrieve namespace information from the server.
    /// - Returns: The namespace response describing personal, other user and shared namespaces.
    /// - Throws: `IMAPError.commandFailed` if the command fails.
    public func fetchNamespaces() async throws -> Namespace.Response {
        let command = NamespaceCommand()
        let response = try await executeCommand(command)
        self.namespaces = response
        return response
    }
    
    /**
     Lists mailboxes with special-use attributes.
     
     Special-use mailboxes are those designated for specific purposes like
     Sent, Drafts, Trash, etc., as defined in RFC 6154.
     
     - Returns: An array of special-use mailbox information
     - Throws:
     - `IMAPError.commandNotSupported` if SPECIAL-USE is not supported
     - `IMAPError.commandFailed` if the list operation fails
     - Note: Logs special mailbox detection at info level
     */
    public func listSpecialUseMailboxes() async throws -> [Mailbox.Info] {
        // Check if the server supports SPECIAL-USE capability
        let supportsSpecialUse = capabilities.contains(NIOIMAPCore.Capability("SPECIAL-USE"))
        
        // Get all mailboxes and store them
        self.mailboxes = try await listMailboxes()
        var specialFolders: [Mailbox.Info] = []
        
        // Flag to track if we've found an explicit inbox
        var foundExplicitInbox = false
        
        if supportsSpecialUse {
            // Create a ListCommand with SPECIAL-USE return option
            let command = ListCommand(returnOptions: [.specialUse])
            let mailboxesWithAttributes = try await executeCommand(command)
            
            // Keep only mailboxes with special-use attributes
            for mailbox in mailboxesWithAttributes {
                let hasSpecialUse = mailbox.attributes.contains(.inbox) ||
                mailbox.attributes.contains(.trash) ||
                mailbox.attributes.contains(.archive) ||
                mailbox.attributes.contains(.sent) ||
                mailbox.attributes.contains(.drafts) ||
                mailbox.attributes.contains(.junk) ||
                mailbox.attributes.contains(.flagged)
                
                if hasSpecialUse {
                    specialFolders.append(mailbox)
                    if mailbox.attributes.contains(.inbox) {
                        foundExplicitInbox = true
                    }
                }
            }
        } else {
            // Detect special folders by name when SPECIAL-USE is not supported
            for mailbox in mailboxes {
                var attributes = mailbox.attributes
                var hasSpecialUse = false
                
                // Check name patterns for common special folders
                let nameLower = mailbox.name.lowercased()
                
                if mailbox.attributes.contains(.inbox) {
                    foundExplicitInbox = true
                    hasSpecialUse = true
                } else if nameLower.contains("trash") || nameLower.contains("deleted") {
                    attributes.insert(.trash)
                    hasSpecialUse = true
                } else if nameLower.contains("sent") {
                    attributes.insert(.sent)
                    hasSpecialUse = true
                } else if nameLower.contains("draft") {
                    attributes.insert(.drafts)
                    hasSpecialUse = true
                } else if nameLower.contains("junk") || nameLower.contains("spam") {
                    attributes.insert(.junk)
                    hasSpecialUse = true
                } else if nameLower.contains("archive") || (nameLower.contains("all") && nameLower.contains("mail")) {
                    attributes.insert(.archive)
                    hasSpecialUse = true
                } else if nameLower.contains("starred") || nameLower.contains("flagged") {
                    attributes.insert(.flagged)
                    hasSpecialUse = true
                }
                
                // Special case for Gmail's folders
                if mailbox.name == "[Gmail]/Trash" {
                    attributes.insert(.trash)
                    hasSpecialUse = true
                } else if mailbox.name == "[Gmail]/Sent Mail" {
                    attributes.insert(.sent)
                    hasSpecialUse = true
                } else if mailbox.name == "[Gmail]/Drafts" {
                    attributes.insert(.drafts)
                    hasSpecialUse = true
                } else if mailbox.name == "[Gmail]/Spam" {
                    attributes.insert(.junk)
                    hasSpecialUse = true
                } else if mailbox.name == "[Gmail]/All Mail" {
                    attributes.insert(.archive)
                    hasSpecialUse = true
                } else if mailbox.name == "[Gmail]/Starred" {
                    attributes.insert(.flagged)
                    hasSpecialUse = true
                }
                
                if hasSpecialUse {
                    // Create a new mailbox info with the enhanced attributes
                    let specialMailbox = Mailbox.Info(
                        name: mailbox.name,
                        attributes: attributes,
                        hierarchyDelimiter: mailbox.hierarchyDelimiter
                    )
                    specialFolders.append(specialMailbox)
                }
            }
        }
        
        // Per IMAP spec, INBOX always exists - if no explicit inbox was found, add it
        if !foundExplicitInbox {
            // Find the INBOX in the mailboxes list
            if let inboxMailbox = mailboxes.first(where: { $0.name.caseInsensitiveCompare("INBOX") == .orderedSame }) {
                // Create a copy with the inbox attribute added
                var inboxAttributes = inboxMailbox.attributes
                inboxAttributes.insert(.inbox)
                
                let inboxWithAttribute = Mailbox.Info(
                    name: inboxMailbox.name,
                    attributes: inboxAttributes,
                    hierarchyDelimiter: inboxMailbox.hierarchyDelimiter
                )
                
                specialFolders.append(inboxWithAttribute)
            }
        }
        
        // Update the specialMailboxes property
        self.specialMailboxes = specialFolders
        
        return specialFolders
    }
}

// MARK: - Mailbox Listing and Special Folders
extension IMAPServer {
    /**
     Lists all available mailboxes on the server.
     
     This method retrieves a list of all mailboxes (folders) available on the server,
     including their attributes and hierarchy information.
     
     - Parameter wildcard: The wildcard pattern used when listing mailboxes. Defaults to "*".
     - Returns: An array of mailbox information
     - Throws: `IMAPError.commandFailed` if the list operation fails
     - Note: Logs mailbox listing at info level with count
     */
    public func listMailboxes(wildcard: String = "*") async throws -> [Mailbox.Info] {
        let command = ListCommand(wildcard: wildcard)
        return try await executeCommand(command)
    }
    
    /**
     Get the inbox folder or throw if not found
     
     - Returns: The inbox folder information
     - Throws: `UndefinedFolderError.inbox` if the inbox folder is not found
     */
    public var inboxFolder: Mailbox.Info {
        get throws {
            guard let inbox = specialMailboxes.inbox ?? mailboxes.inbox else {
                throw UndefinedFolderError.inbox
            }
            return inbox
        }
    }
    
    /**
     Get the trash folder or throw if not found
     
     - Returns: The trash folder information
     - Throws: `UndefinedFolderError.trash` if the trash folder is not found
     */
    public var trashFolder: Mailbox.Info {
        get throws {
            guard let trash = specialMailboxes.trash else {
                throw UndefinedFolderError.trash
            }
            return trash
        }
    }
    
    /**
     Get the archive folder or throw if not found
     
     - Returns: The archive folder information
     - Throws: `UndefinedFolderError.archive` if the archive folder is not found
     */
    public var archiveFolder: Mailbox.Info {
        get throws {
            guard let archive = specialMailboxes.archive else {
                throw UndefinedFolderError.archive
            }
            return archive
        }
    }
    
    /**
     Get the sent folder or throw if not found
     
     - Returns: The sent folder information
     - Throws: `UndefinedFolderError.sent` if the sent folder is not found
     */
    public var sentFolder: Mailbox.Info {
        get throws {
            guard let sent = specialMailboxes.sent else {
                throw UndefinedFolderError.sent
            }
            return sent
        }
    }
    
    /**
     Get the drafts folder or throw if not found
     
     - Returns: The drafts folder information
     - Throws: `UndefinedFolderError.drafts` if the drafts folder is not found
     */
    public var draftsFolder: Mailbox.Info {
        get throws {
            guard let drafts = specialMailboxes.drafts else {
                throw UndefinedFolderError.drafts
            }
            return drafts
        }
    }
    
    /**
     Get the junk folder or throw if not found
     
     - Returns: The junk folder information
     - Throws: `UndefinedFolderError.junk` if the junk folder is not found
     */
    public var junkFolder: Mailbox.Info {
        get throws {
            guard let junk = specialMailboxes.junk else {
                throw UndefinedFolderError.junk
            }
            return junk
        }
    }
}

// Update the existing folder operations to use the throwing getters
extension IMAPServer {
    /**
     Move messages to the trash folder
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to move
     - Throws: An error if the move operation fails or trash folder is not found
     */
    public func moveToTrash<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await move(messages: identifierSet, to: try trashFolder.name)
    }
    
    /**
     Archive messages by marking them as seen and moving them to the archive folder
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to archive
     - Throws: An error if the archive operation fails or archive folder is not found
     */
    public func archive<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await store(flags: [.seen], on: identifierSet, operation: .add)
        try await move(messages: identifierSet, to: try archiveFolder.name)
    }
    
    /**
     Mark messages as junk by moving them to the junk folder
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to mark as junk
     - Throws: An error if the operation fails or junk folder is not found
     */
    public func markAsJunk<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await move(messages: identifierSet, to: try junkFolder.name)
    }
    
    /**
     Save messages as drafts by adding the draft flag and moving them to the drafts folder
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to save as drafts
     - Throws: An error if the operation fails or drafts folder is not found
     */
    public func saveAsDraft<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await store(flags: [.draft], on: identifierSet, operation: .add)
        try await move(messages: identifierSet, to: try draftsFolder.name)
    }
}