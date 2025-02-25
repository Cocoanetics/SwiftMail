// IMAPServer.swift
// A Swift IMAP client that encapsulates connection logic

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL
import NIOConcurrencyHelpers

// Add a file-level extension to make NIOSSLClientHandler conform to Sendable
// Note: This will generate a warning about conforming an imported type to an imported protocol,
// but it's necessary to suppress the Sendable warnings in the code
extension NIOSSLClientHandler: @unchecked @retroactive Sendable {}

/// A class that represents an IMAP server connection
public final class IMAPServer: @unchecked Sendable {
    // MARK: - Properties
    
    /// The hostname of the IMAP server
    private let host: String
    
    /// The port number of the IMAP server
    private let port: Int
    
    /// The event loop group for handling asynchronous operations
    private let group: EventLoopGroup
    
    /// The channel for communication with the server
    private var channel: Channel?
    
    /// The response handler for processing IMAP responses
    private var responseHandler: IMAPResponseHandler?
    
    /// Lock for thread-safe access to mutable properties
    private let lock = NIOLock()
    
    /// Logger for IMAP operations
    /// To view these logs in Console.app:
    /// 1. Open Console.app
    /// 2. In the search field, type "subsystem:com.example.SwiftIMAP"
    /// 3. You may need to adjust the "Action" menu to show "Include Debug Messages" and "Include Info Messages"
    private let logger = Logger(subsystem: "com.example.SwiftIMAP", category: "IMAPServer")
    
    // MARK: - Initialization
    
    /// Initialize a new IMAP server connection
    /// - Parameters:
    ///   - host: The hostname of the IMAP server
    ///   - port: The port number of the IMAP server
    ///   - numberOfThreads: The number of threads to use for the event loop group
    public init(host: String, port: Int, numberOfThreads: Int = 1) {
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
    }
    
    deinit {
        try? group.syncShutdownGracefully()
    }
    
    // MARK: - Connection Methods
    
    /// Connect to the IMAP server
    /// - Returns: A boolean indicating whether the connection was successful
    /// - Throws: An error if the connection fails
    public func connect() async throws {
        // Create SSL context for secure connection
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        
        // Create our response handler
        let responseHandler = IMAPResponseHandler()
        lock.withLock {
            self.responseHandler = responseHandler
        }
        
        // Capture the host as a local variable to avoid capturing self
        let host = self.host
        
        // Set up the channel handlers
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                // Create the SSL handler
                let sslHandler = try! NIOSSLClientHandler(context: sslContext, serverHostname: host)
                
                // Add handlers to the pipeline
                return channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.addHandler(IMAPClientHandler()).flatMap {
                        channel.pipeline.addHandler(responseHandler)
                    }
                }
            }
        
        // Connect to the server
        logger.info("Connecting to \(self.host):\(self.port)...")
        let channel = try await bootstrap.connect(host: host, port: port).get()
        lock.withLock {
            self.channel = channel
        }
        logger.info("Connected to server")
        
        // Wait for the server greeting
        logger.debug("Waiting for server greeting...")
        try await waitForGreeting()
        logger.info("Server greeting received!")
    }
    
    /// Wait for the server greeting
    /// - Throws: An error if the greeting times out or fails
    private func waitForGreeting() async throws {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Create a promise for the greeting
        responseHandler.greetingPromise = channel.eventLoop.makePromise(of: Void.self)
        
        // Set up a timeout for the greeting
        let greetingTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { [responseHandler] in
            responseHandler.greetingPromise?.fail(IMAPError.timeout)
        }
        
        // Wait for the greeting
        do {
            try await responseHandler.greetingPromise?.futureResult.get()
            greetingTimeout.cancel()
        } catch {
            logger.error("Failed to receive server greeting: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    /// Login to the IMAP server
    /// - Parameters:
    ///   - username: The username for authentication
    ///   - password: The password for authentication
    /// - Throws: An error if the login fails
    public func login(username: String, password: String) async throws {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send login command
        logger.debug("Sending login command...")
        let loginTag = "A001"
        responseHandler.loginTag = loginTag
        responseHandler.loginPromise = channel.eventLoop.makePromise(of: Void.self)
        
        let loginCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: loginTag, command: .login(username: username, password: password))
        )
        try await channel.writeAndFlush(loginCommand).get()
        
        // Set up a timeout for login
        logger.debug("Waiting for login response...")
        let loginTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { [responseHandler] in
            responseHandler.loginPromise?.fail(IMAPError.timeout)
        }
        
        do {
            try await responseHandler.loginPromise?.futureResult.get()
            loginTimeout.cancel()
            logger.info("Login successful!")
        } catch {
            logger.error("Login failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    /// Select a mailbox
    /// - Parameter mailboxName: The name of the mailbox to select
    /// - Returns: Information about the selected mailbox
    /// - Throws: An error if the select operation fails
    public func selectMailbox(_ mailboxName: String) async throws -> MailboxInfo {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send select inbox command
        logger.debug("Sending SELECT \(mailboxName) command...")
        let selectTag = "A002"
        responseHandler.selectTag = selectTag
        responseHandler.currentMailboxName = mailboxName
        responseHandler.selectPromise = channel.eventLoop.makePromise(of: MailboxInfo.self)
        
        let mailbox = MailboxName(Array(mailboxName.utf8))
        let selectCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: selectTag, command: .select(mailbox, []))
        )
        try await channel.writeAndFlush(selectCommand).get()
        
        // Set up a timeout for select
        logger.debug("Waiting for SELECT response...")
        let selectTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { [responseHandler] in
            responseHandler.selectPromise?.fail(IMAPError.timeout)
        }
        
        do {
            let mailboxInfo = try await responseHandler.selectPromise?.futureResult.get()
            selectTimeout.cancel()
            logger.info("SELECT successful!")
            
            if let mailboxInfo = mailboxInfo {
                logger.info("Mailbox information: \(mailboxInfo.description)")
                return mailboxInfo
            } else {
                logger.warning("No mailbox information available")
                throw IMAPError.selectFailed("No mailbox information available")
            }
        } catch {
            logger.error("SELECT failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    /// Logout from the IMAP server
    /// - Throws: An error if the logout fails
    public func logout() async throws {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send logout command
        logger.debug("Sending LOGOUT command...")
        let logoutTag = "A003"
        responseHandler.logoutTag = logoutTag
        responseHandler.logoutPromise = channel.eventLoop.makePromise(of: Void.self)
        
        let logoutCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: logoutTag, command: .logout)
        )
        try await channel.writeAndFlush(logoutCommand).get()
        
        // Set up a timeout for logout
        logger.debug("Waiting for LOGOUT response...")
        let logoutTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { [responseHandler] in
            responseHandler.logoutPromise?.fail(IMAPError.timeout)
        }
        
        do {
            try await responseHandler.logoutPromise?.futureResult.get()
            logoutTimeout.cancel()
            logger.info("LOGOUT successful!")
        } catch {
            logger.error("LOGOUT failed: \(error.localizedDescription, privacy: .public)")
            // Continue with closing even if logout fails
            throw error
        }
    }
    
    /// Close the connection to the IMAP server
    /// - Throws: An error if the close operation fails
    public func close() async throws {
        let channel = lock.withLock { () -> Channel? in
            return self.channel
        }
        
        guard let channel = channel else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        
        // Close the connection
        logger.debug("Closing connection...")
        do {
            try await channel.close().get()
            logger.info("Connection closed")
        } catch let error as NIOCore.ChannelError where error == .alreadyClosed {
            // Channel is already closed, which is fine
            logger.info("Connection already closed by server")
        }
    }
    
    /// Fetch headers for messages in the selected mailbox
    /// - Parameters:
    ///   - range: The range of message sequence numbers to fetch (e.g., "1:10" for first 10 messages)
    ///   - limit: Optional limit on the number of headers to return
    /// - Returns: An array of email headers
    /// - Throws: An error if the fetch operation fails
    public func fetchHeaders(range: String, limit: Int? = nil) async throws -> [EmailHeader] {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send fetch command
        logger.debug("Sending FETCH \(range) command...")
        let fetchTag = "A004"
        responseHandler.fetchTag = fetchTag
        responseHandler.fetchPromise = channel.eventLoop.makePromise(of: [EmailHeader].self)
        
        // Parse the range string into a sequence set
        let sequenceSet = try parseSequenceSet(range)
        
        // Create the FETCH command for headers
        let fetchCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: fetchTag, command: .fetch(
                .set(sequenceSet),
                [.envelope, .bodyStructure(extensions: false), .bodySection(peek: true, .header, nil)],
                []
            ))
        )
        try await channel.writeAndFlush(fetchCommand).get()
        
        // Set up a timeout for fetch
        logger.debug("Waiting for FETCH response...")
        let fetchTimeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { [responseHandler] in
            responseHandler.fetchPromise?.fail(IMAPError.timeout)
        }
        
        do {
            var headers = try await responseHandler.fetchPromise?.futureResult.get() ?? []
            fetchTimeout.cancel()
            logger.info("FETCH successful! Retrieved \(headers.count) headers")
            
            // Apply limit if specified
            if let limit = limit, headers.count > limit {
                headers = Array(headers.prefix(limit))
            }
            
            return headers
        } catch {
            logger.error("FETCH failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    /// Parse a string range (e.g., "1:10") into a SequenceSet
    /// - Parameter range: The range string to parse
    /// - Returns: A SequenceSet object
    /// - Throws: An error if the range string is invalid
    private func parseSequenceSet(_ range: String) throws -> MessageIdentifierSetNonEmpty<SequenceNumber> {
        // Split the range by colon
        let parts = range.split(separator: ":")
        
        if parts.count == 1, let number = UInt32(parts[0]) {
            // Single number
            let sequenceNumber = SequenceNumber(rawValue: number)
            let set = MessageIdentifierSet<SequenceNumber>(sequenceNumber)
            return MessageIdentifierSetNonEmpty(set: set)!
        } else if parts.count == 2, let start = UInt32(parts[0]), let end = UInt32(parts[1]) {
            // Range
            let startSeq = SequenceNumber(rawValue: start)
            let endSeq = SequenceNumber(rawValue: end)
            let range = MessageIdentifierRange(startSeq...endSeq)
            return MessageIdentifierSetNonEmpty(range: range)
        } else {
            throw IMAPError.invalidArgument("Invalid sequence range: \(range)")
        }
    }
}

// MARK: - Response Handler

/// A custom handler to process IMAP responses
final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response
    
    // Promises for different command responses
    var greetingPromise: EventLoopPromise<Void>?
    var loginPromise: EventLoopPromise<Void>?
    var selectPromise: EventLoopPromise<MailboxInfo>?
    var logoutPromise: EventLoopPromise<Void>?
    var fetchPromise: EventLoopPromise<[EmailHeader]>?
    
    // Tags to identify commands
    var loginTag: String?
    var selectTag: String?
    var logoutTag: String?
    var fetchTag: String?
    
    // Current mailbox being selected
    var currentMailboxName: String?
    var currentMailboxInfo: MailboxInfo?
    
    // Collected email headers
    private var emailHeaders: [EmailHeader] = []
    
    // Lock for thread-safe access to mutable properties
    private let lock = NIOLock()
    
    // Logger for IMAP responses
    private let logger = Logger(subsystem: "com.example.SwiftIMAP", category: "IMAPResponseHandler")
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        logger.debug("Received: \(String(describing: response), privacy: .public)")
        
        // Log all responses for better visibility
        logger.debug("IMAP RESPONSE: \(String(describing: response), privacy: .public)")
        
        // Check if this is an untagged response (server greeting)
        if case .untagged(_) = response, let greetingPromise = lock.withLock({ self.greetingPromise }) {
            // Server greeting is typically an untagged OK response
            // The first response from the server is the greeting
            greetingPromise.succeed(())
        }
        
        // Process untagged responses for mailbox information during SELECT
        if case .untagged(let untaggedResponse) = response, 
           lock.withLock({ self.selectPromise != nil }), 
           let mailboxName = lock.withLock({ self.currentMailboxName }) {
            
            lock.withLock {
                if self.currentMailboxInfo == nil {
                    self.currentMailboxInfo = MailboxInfo(name: mailboxName)
                }
            }
            
            // Extract mailbox information from untagged responses
            switch untaggedResponse {
            case .conditionalState(let status):
                // Handle OK responses with response text
                if case .ok(let responseText) = status {
                    // Check for response codes in the response text
                    if let responseCode = responseText.code {
                        switch responseCode {
                        case .unseen(let firstUnseen):
                            lock.withLock {
                                self.currentMailboxInfo?.firstUnseen = Int(firstUnseen)
                            }
                            logger.debug("First unseen message: \(Int(firstUnseen))")
                            
                        case .uidValidity(let validity):
                            // Use the BinaryInteger extension to convert UIDValidity to UInt32
                            lock.withLock {
                                self.currentMailboxInfo?.uidValidity = UInt32(validity)
                            }
                            logger.debug("UID validity value: \(UInt32(validity), privacy: .public)")
                            
                        case .uidNext(let next):
                            // Use the BinaryInteger extension to convert UID to UInt32
                            lock.withLock {
                                self.currentMailboxInfo?.uidNext = UInt32(next)
                            }
                            logger.debug("Next UID: \(UInt32(next), format: .decimal, privacy: .public)")
                            
                        case .permanentFlags(let flags):
                            lock.withLock {
                                self.currentMailboxInfo?.permanentFlags = flags.map { String(describing: $0) }
                            }
                            logger.debug("Permanent flags: \(flags.map { String(describing: $0) }.joined(separator: ", "), privacy: .public)")
                            
                        case .readOnly:
                            lock.withLock {
                                self.currentMailboxInfo?.isReadOnly = true
                            }
                            logger.debug("Mailbox is read-only")
                            
                        case .readWrite:
                            lock.withLock {
                                self.currentMailboxInfo?.isReadOnly = false
                            }
                            logger.debug("Mailbox is read-write")
                            
                        default:
                            logger.debug("Unhandled response code: \(String(describing: responseCode))")
                            break
                        }
                    }
                }
                
            case .mailboxData(let mailboxData):
                // Extract mailbox information from mailbox data
                switch mailboxData {
                case .exists(let count):
                    lock.withLock {
                        self.currentMailboxInfo?.messageCount = Int(count)
                    }
                    logger.debug("Mailbox has \(count, format: .decimal, privacy: .public) messages")
                    
                case .recent(let count):
                    lock.withLock {
                        self.currentMailboxInfo?.recentCount = Int(count)
                    }
                    logger.debug("Mailbox has \(count) recent messages - RECENT FLAG DETAILS")
                    
                case .flags(let flags):
                    lock.withLock {
                        self.currentMailboxInfo?.availableFlags = flags.map { String(describing: $0) }
                    }
                    logger.debug("Available flags: \(flags.map { String(describing: $0) }.joined(separator: ", "), privacy: .public)")
                    
                default:
                    logger.debug("Unhandled mailbox data: \(String(describing: mailboxData), privacy: .public)")
                    break
                }
                
            case .messageData(let messageData):
                // Handle message data if needed
                logger.debug("Received message data: \(String(describing: messageData), privacy: .public)")
                
            default:
                logger.debug("Unhandled untagged response: \(String(describing: untaggedResponse), privacy: .public)")
                break
            }
        }
        
        // Process FETCH responses for email headers
        if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchPromise != nil }) {
            switch fetchResponse {
            case .simpleAttribute(let attribute):
                // Process the attribute directly
                processMessageAttribute(attribute, sequenceNumber: nil)
                
            case .start(let sequenceNumber):
                // Create a new email header for this sequence number
                let header = EmailHeader(sequenceNumber: Int(sequenceNumber))
                lock.withLock {
                    self.emailHeaders.append(header)
                }
                
            default:
                break
            }
        } else if case .untagged(let untaggedResponse) = response, lock.withLock({ self.fetchPromise != nil }) {
            if case .messageData(let messageData) = untaggedResponse {
                // Handle other message data if needed
                logger.debug("Received message data: \(String(describing: messageData), privacy: .public)")
            }
        }
        
        // Check if this is a tagged response that matches one of our commands
        if case .tagged(let taggedResponse) = response {
            // Handle login response
            if taggedResponse.tag == lock.withLock({ self.loginTag }) {
                if case .ok = taggedResponse.state {
                    lock.withLock { self.loginPromise?.succeed(()) }
                } else {
                    lock.withLock { self.loginPromise?.fail(IMAPError.loginFailed(String(describing: taggedResponse.state))) }
                }
            }
            
            // Handle select response
            if taggedResponse.tag == lock.withLock({ self.selectTag }) {
                if case .ok = taggedResponse.state {
                    let (mailboxInfo, mailboxName, selectPromise) = lock.withLock { () -> (MailboxInfo?, String?, EventLoopPromise<MailboxInfo>?) in
                        return (self.currentMailboxInfo, self.currentMailboxName, self.selectPromise)
                    }
                    
                    if var mailboxInfo = mailboxInfo {
                        // If we have a first unseen message but unseen count is 0,
                        // calculate the unseen count as (total messages - first unseen + 1)
                        if mailboxInfo.firstUnseen > 0 && mailboxInfo.unseenCount == 0 {
                            mailboxInfo.unseenCount = mailboxInfo.messageCount - mailboxInfo.firstUnseen + 1
                            logger.debug("Calculated unseen count: \(mailboxInfo.unseenCount)")
                            // Update the current mailbox info with the modified copy
                            lock.withLock {
                                self.currentMailboxInfo = mailboxInfo
                            }
                        }
                        
                        selectPromise?.succeed(mailboxInfo)
                    } else if let mailboxName = mailboxName {
                        // If we didn't get any untagged responses with mailbox info, create a basic one
                        selectPromise?.succeed(MailboxInfo(name: mailboxName))
                    } else {
                        selectPromise?.fail(IMAPError.selectFailed("No mailbox information available"))
                    }
                    
                    // Reset for next select
                    lock.withLock {
                        self.currentMailboxName = nil
                        self.currentMailboxInfo = nil
                    }
                } else {
                    lock.withLock {
                        self.selectPromise?.fail(IMAPError.selectFailed(String(describing: taggedResponse.state)))
                    }
                }
            }
            
            // Handle logout response
            if taggedResponse.tag == lock.withLock({ self.logoutTag }) {
                if case .ok = taggedResponse.state {
                    lock.withLock { self.logoutPromise?.succeed(()) }
                } else {
                    lock.withLock { self.logoutPromise?.fail(IMAPError.logoutFailed(String(describing: taggedResponse.state))) }
                }
            }
            
            // Handle fetch response
            if taggedResponse.tag == lock.withLock({ self.fetchTag }) {
                if case .ok = taggedResponse.state {
                    let headers = lock.withLock { () -> [EmailHeader] in
                        let headers = self.emailHeaders
                        self.emailHeaders.removeAll()
                        return headers
                    }
                    lock.withLock { self.fetchPromise?.succeed(headers) }
                } else {
                    lock.withLock { 
                        self.fetchPromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
                        self.emailHeaders.removeAll()
                    }
                }
            }
        }
    }
    
    /// Format an address for display
    /// - Parameter address: The address to format
    /// - Returns: A formatted string representation of the address
    private func formatAddress(_ address: EmailAddressListElement) -> String {
        switch address {
        case .singleAddress(let emailAddress):
            let name = emailAddress.personName?.stringValue ?? ""
            let mailbox = emailAddress.mailbox?.stringValue ?? ""
            let host = emailAddress.host?.stringValue ?? ""
            
            if !name.isEmpty {
                return "\"\(name)\" <\(mailbox)@\(host)>"
            } else {
                return "\(mailbox)@\(host)"
            }
            
        case .group(let group):
            let groupName = group.groupName.stringValue
            let members = group.children.map { formatAddress($0) }.joined(separator: ", ")
            return "\(groupName): \(members)"
        }
    }
    
    /// Parse header data into an EmailHeader object
    /// - Parameters:
    ///   - data: The raw header data
    ///   - header: The EmailHeader object to update
    private func parseHeaderData(_ data: ByteBuffer, into header: inout EmailHeader) {
        // Only parse if we don't already have this information from the envelope
        if header.subject.isEmpty || header.from.isEmpty || header.date.isEmpty {
            guard let headerString = data.getString(at: 0, length: data.readableBytes) else {
                return
            }
            
            // Parse header fields
            let lines = headerString.split(separator: "\r\n")
            var currentField = ""
            var currentValue = ""
            
            for line in lines {
                let trimmedLine = String(line).trimmingCharacters(in: .whitespaces)
                
                // Check if this is a continuation of the previous field
                if trimmedLine.first?.isWhitespace == true {
                    currentValue += " " + trimmedLine.trimmingCharacters(in: .whitespaces)
                } else if let colonIndex = trimmedLine.firstIndex(of: ":") {
                    // Process the previous field if there was one
                    if !currentField.isEmpty {
                        processHeaderField(field: currentField, value: currentValue, header: &header)
                    }
                    
                    // Start a new field
                    currentField = String(trimmedLine[..<colonIndex]).lowercased()
                    currentValue = String(trimmedLine[trimmedLine.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            
            // Process the last field
            if !currentField.isEmpty {
                processHeaderField(field: currentField, value: currentValue, header: &header)
            }
        }
    }
    
    /// Process a header field and update the EmailHeader object
    /// - Parameters:
    ///   - field: The field name
    ///   - value: The field value
    ///   - header: The EmailHeader object to update
    private func processHeaderField(field: String, value: String, header: inout EmailHeader) {
        // Decode the MIME-encoded value
        let decodedValue = MIMEHeaderDecoder.decode(value)
        
        switch field {
        case "subject":
            header.subject = decodedValue
        case "from":
            header.from = decodedValue
        case "to":
            header.to = decodedValue
        case "cc":
            header.cc = decodedValue
        case "date":
            header.date = decodedValue
        case "message-id":
            header.messageId = decodedValue
        default:
            // Store other fields in the additionalFields dictionary
            header.additionalFields[field] = decodedValue
        }
    }
    
    /// Process a message attribute and update the corresponding email header
    /// - Parameters:
    ///   - attribute: The message attribute to process
    ///   - sequenceNumber: The sequence number of the message (if known)
    private func processMessageAttribute(_ attribute: MessageAttribute, sequenceNumber: SequenceNumber?) {
        // If we don't have a sequence number, we can't update a header
        guard let sequenceNumber = sequenceNumber else {
            // For attributes that come without a sequence number, we assume they belong to the last header
            lock.withLock {
                if let lastIndex = self.emailHeaders.indices.last {
                    var header = self.emailHeaders[lastIndex]
                    updateHeader(&header, with: attribute)
                    self.emailHeaders[lastIndex] = header
                }
            }
            return
        }
        
        // Find or create a header for this sequence number
        let seqNum = Int(sequenceNumber)
        lock.withLock {
            if let index = self.emailHeaders.firstIndex(where: { $0.sequenceNumber == seqNum }) {
                var header = self.emailHeaders[index]
                updateHeader(&header, with: attribute)
                self.emailHeaders[index] = header
            } else {
                var header = EmailHeader(sequenceNumber: seqNum)
                updateHeader(&header, with: attribute)
                self.emailHeaders.append(header)
            }
        }
    }
    
    /// Update an email header with information from a message attribute
    /// - Parameters:
    ///   - header: The header to update
    ///   - attribute: The attribute containing the information
    private func updateHeader(_ header: inout EmailHeader, with attribute: MessageAttribute) {
        switch attribute {
        case .envelope(let envelope):
            // Extract information from envelope
            if let subject = envelope.subject?.stringValue {
                header.subject = MIMEHeaderDecoder.decode(subject)
            }
            
            if let from = envelope.from.first {
                let fromAddress = formatAddress(from)
                header.from = MIMEHeaderDecoder.decode(fromAddress)
            }
            
            if let to = envelope.to.first {
                let toAddress = formatAddress(to)
                header.to = MIMEHeaderDecoder.decode(toAddress)
            }
            
            if let date = envelope.date {
                header.date = formatDate(date)
            }
            
            if let messageID = envelope.messageID {
                header.messageId = messageID.stringValue
            }
            
        case .body(let bodyStructure, _):
            // Extract information from body structure if needed
            logger.debug("Received body structure: \(String(describing: bodyStructure), privacy: .public)")
            
        case .uid(let uid):
            header.uid = Int(uid)
            
        case .flags(let flags):
            header.flags = flags.map { String(describing: $0) }
            
        case .internalDate(let date):
            if header.date.isEmpty {
                header.date = String(describing: date)
            }
            
        default:
            break
        }
        
        // Only keep headers that have at least some basic information
        if !header.subject.isEmpty || !header.from.isEmpty {
            let seqNum = header.sequenceNumber // Create a copy to use in the autoclosure
            logger.debug("Processed header for message #\(seqNum, format: .decimal, privacy: .public)")
        }
    }
    
    /// Format an InternetMessageDate for display
    /// - Parameter date: The InternetMessageDate to format
    /// - Returns: A formatted string representation of the date
    private func formatDate(_ date: InternetMessageDate) -> String {
        return String(date)
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error.localizedDescription, privacy: .public)")
        
        // Fail all pending promises
        lock.withLock {
            self.greetingPromise?.fail(error)
            self.loginPromise?.fail(error)
            self.selectPromise?.fail(error)
            self.logoutPromise?.fail(error)
            self.fetchPromise?.fail(error)
        }
        
        context.close(promise: nil)
    }
}

// MARK: - IMAP Errors

/// Custom IMAP errors
public enum IMAPError: Error, CustomStringConvertible {
    case greetingFailed(String)
    case loginFailed(String)
    case selectFailed(String)
    case logoutFailed(String)
    case connectionFailed(String)
    case fetchFailed(String)
    case invalidArgument(String)
    case timeout
    
    public var description: String {
        switch self {
        case .greetingFailed(let reason):
            return "Server greeting failed: \(reason)"
        case .loginFailed(let reason):
            return "Login failed: \(reason)"
        case .selectFailed(let reason):
            return "Select mailbox failed: \(reason)"
        case .logoutFailed(let reason):
            return "Logout failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .fetchFailed(let reason):
            return "Fetch failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .timeout:
            return "Operation timed out"
        }
    }
}

// MARK: - Email Header

/// Structure to hold email header information
public struct EmailHeader: Sendable {
    /// The sequence number of the message
    public let sequenceNumber: Int
    
    /// The UID of the message
    public var uid: Int = 0
    
    /// The subject of the email
    public var subject: String = ""
    
    /// The sender of the email
    public var from: String = ""
    
    /// The recipients of the email
    public var to: String = ""
    
    /// The CC recipients of the email
    public var cc: String = ""
    
    /// The date the email was sent
    public var date: String = ""
    
    /// The message ID
    public var messageId: String = ""
    
    /// The flags set on the message
    public var flags: [String] = []
    
    /// Additional header fields
    public var additionalFields: [String: String] = [:]
    
    /// Initialize a new email header
    /// - Parameter sequenceNumber: The sequence number of the message
    public init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }
    
    /// A string representation of the email header
    public var description: String {
        return """
        Message #\(sequenceNumber) (UID: \(uid > 0 ? String(uid) : "N/A"))
        Subject: \(subject)
        From: \(from)
        Date: \(date)
        Flags: \(flags.joined(separator: ", "))
        """
    }
}

// MARK: - Mailbox Information

/// Structure to hold information about a mailbox
public struct MailboxInfo: Sendable {
    /// The name of the mailbox
    public let name: String
    
    /// The number of messages in the mailbox
    public var messageCount: Int = 0
    
    /// The number of recent messages in the mailbox
    /// Note: In IMAP, "recent" messages are those that have been delivered since the last time
    /// any client selected this mailbox. This is different from "unseen" messages.
    /// A value of 0 is normal if you've accessed this mailbox recently with another client,
    /// or if no new messages have arrived since the last time the mailbox was selected.
    public var recentCount: Int = 0
    
    /// The number of unseen messages in the mailbox
    public var unseenCount: Int = 0
    
    /// The first unseen message sequence number
    public var firstUnseen: Int = 0
    
    /// The UID validity value
    /// Note: This is a number that changes when the mailbox's UID numbering is reset.
    /// It's used by clients to determine if their cached UIDs are still valid.
    /// A value of 1 is perfectly valid - it just means this is the first UID numbering scheme for this mailbox.
    public var uidValidity: UInt32 = 0
    
    /// The next UID value
    public var uidNext: UInt32 = 0
    
    /// Whether the mailbox is read-only
    public var isReadOnly: Bool = false
    
    /// Flags available in the mailbox
    public var availableFlags: [String] = []
    
    /// Permanent flags that can be set
    public var permanentFlags: [String] = []
    
    /// Initialize a new mailbox info structure
    /// - Parameter name: The name of the mailbox
    public init(name: String) {
        self.name = name
    }
    
    /// A string representation of the mailbox information
    public var description: String {
        return """
        Mailbox: \(name)
        Messages: \(messageCount)
        Recent: \(recentCount)
        Unseen: \(unseenCount)
        First Unseen: \(firstUnseen > 0 ? String(firstUnseen) : "N/A")
        UID Validity: \(uidValidity)
        UID Next: \(uidNext)
        Read-Only: \(isReadOnly ? "Yes" : "No")
        Available Flags: \(availableFlags.joined(separator: ", "))
        Permanent Flags: \(permanentFlags.joined(separator: ", "))
        """
    }
}

// MARK: - ByteBuffer Extension

extension ByteBuffer {
    /// Get a String representation of the ByteBuffer
    var stringValue: String {
        getString(at: readerIndex, length: readableBytes) ?? ""
    }
}

// MARK: - MIME Header Decoding

/// Utility functions for decoding MIME-encoded email headers
enum MIMEHeaderDecoder {
    /// Decode a MIME-encoded header string
    /// - Parameter encodedString: The MIME-encoded string to decode
    /// - Returns: The decoded string
    static func decode(_ encodedString: String) -> String {
        // Regular expression to match MIME encoded-word syntax: =?charset?encoding?encoded-text?=
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return encodedString
        }
        
        var result = encodedString
        
        // Find all matches and process them in reverse order to avoid index issues
        let matches = regex.matches(in: encodedString, options: [], range: NSRange(encodedString.startIndex..., in: encodedString))
        
        for match in matches.reversed() {
            guard let charsetRange = Range(match.range(at: 1), in: encodedString),
                  let encodingRange = Range(match.range(at: 2), in: encodedString),
                  let textRange = Range(match.range(at: 3), in: encodedString),
                  let fullRange = Range(match.range, in: encodedString) else {
                continue
            }
            
            let charset = String(encodedString[charsetRange])
            let encoding = String(encodedString[encodingRange]).uppercased()
            let encodedText = String(encodedString[textRange])
            
            var decodedText = ""
            
            // Decode based on encoding type
            if encoding == "B" {
                // Base64 encoding
                if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                   let decoded = String(data: data, encoding: .utf8) {
                    decodedText = decoded
                } else {
                    // Try with the specified charset if UTF-8 fails
                    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                    if cfEncoding != kCFStringEncodingInvalidId {
                        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                        let encoding = String.Encoding(rawValue: nsEncoding)
                        if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                           let decoded = String(data: data, encoding: encoding) {
                            decodedText = decoded
                        }
                    }
                }
            } else if encoding == "Q" {
                // Quoted-printable encoding
                decodedText = decodeQuotedPrintable(encodedText)
            }
            
            if !decodedText.isEmpty {
                result = result.replacingCharacters(in: fullRange, with: decodedText)
            }
        }
        
        // Handle consecutive encoded words (they should be concatenated without spaces)
        result = result.replacingOccurrences(of: "?= =?", with: "")
        
        return result
    }
    
    /// Decode a quoted-printable encoded string
    /// - Parameter encodedString: The quoted-printable encoded string
    /// - Returns: The decoded string
    private static func decodeQuotedPrintable(_ encodedString: String) -> String {
        var result = ""
        var i = encodedString.startIndex
        
        while i < encodedString.endIndex {
            if encodedString[i] == "=" && i < encodedString.index(encodedString.endIndex, offsetBy: -2) {
                let hexStart = encodedString.index(after: i)
                let hexEnd = encodedString.index(hexStart, offsetBy: 2)
                let hexString = String(encodedString[hexStart..<hexEnd])
                
                if let hexValue = UInt8(hexString, radix: 16) {
                    result.append(Character(UnicodeScalar(hexValue)))
                } else {
                    result.append(encodedString[i])
                }
                
                i = hexEnd
            } else if encodedString[i] == "_" {
                // In Q encoding, underscore represents a space
                result.append(" ")
                i = encodedString.index(after: i)
            } else {
                result.append(encodedString[i])
                i = encodedString.index(after: i)
            }
        }
        
        return result
    }
}

// MARK: - MessageID Extension

extension MessageID {
    /// Get a String representation of the MessageID
    var stringValue: String {
        String(describing: self)
    }
} 
