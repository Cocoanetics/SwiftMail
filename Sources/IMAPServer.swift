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

// MARK: - ByteBuffer Extension

extension ByteBuffer {
    /// Get a String representation of the ByteBuffer
    var stringValue: String {
        getString(at: readerIndex, length: readableBytes) ?? ""
    }
}

// MARK: - MessageID Extension

extension MessageID {
    /// Get a String representation of the MessageID
    var stringValue: String {
        String(describing: self)
    }
}

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
    
    /// Fetch a specific part of a message
    /// - Parameters:
    ///   - sequenceNumber: The sequence number of the message
    ///   - partNumber: The part number to fetch (e.g., "1", "1.1", "2", etc.)
    /// - Returns: The content of the message part as Data
    /// - Throws: An error if the fetch operation fails
    public func fetchMessagePart(sequenceNumber: Int, partNumber: String) async throws -> Data {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send fetch command
        logger.debug("Sending FETCH for message #\(sequenceNumber), part \(partNumber)...")
        let fetchTag = "A005"
        responseHandler.fetchPartTag = fetchTag
        responseHandler.fetchPartPromise = channel.eventLoop.makePromise(of: Data.self)
        
        // Create the sequence set for a single message
        let seqNum = SequenceNumber(rawValue: UInt32(sequenceNumber))
        let sequenceSet = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<SequenceNumber>(seqNum))!
        
        // Create the FETCH command for the specific part
        // Convert the part number string to a section path
        let sectionPath = partNumber.split(separator: ".").map { Int($0)! }
        let part = SectionSpecifier.Part(sectionPath)
        let section = SectionSpecifier(part: part)
        
        let fetchCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: fetchTag, command: .fetch(
                .set(sequenceSet),
                [.bodySection(peek: true, section, nil)],
                []
            ))
        )
        try await channel.writeAndFlush(fetchCommand).get()
        
        // Set up a timeout for fetch
        logger.debug("Waiting for FETCH PART response...")
        let fetchTimeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { [responseHandler] in
            responseHandler.fetchPartPromise?.fail(IMAPError.timeout)
        }
        
        do {
            let partData = try await responseHandler.fetchPartPromise?.futureResult.get() ?? Data()
            fetchTimeout.cancel()
            logger.info("FETCH PART successful! Retrieved \(partData.count) bytes")
            
            return partData
        } catch {
            logger.error("FETCH PART failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    /// Fetch the structure of a message to determine its parts
    /// - Parameter sequenceNumber: The sequence number of the message
    /// - Returns: The body structure of the message
    /// - Throws: An error if the fetch operation fails
    public func fetchMessageStructure(sequenceNumber: Int) async throws -> BodyStructure {
        let (channel, responseHandler) = lock.withLock { () -> (Channel?, IMAPResponseHandler?) in
            return (self.channel, self.responseHandler)
        }
        
        guard let channel = channel, let responseHandler = responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Send fetch command
        logger.debug("Sending FETCH BODYSTRUCTURE for message #\(sequenceNumber)...")
        let fetchTag = "A006"
        responseHandler.fetchStructureTag = fetchTag
        responseHandler.fetchStructurePromise = channel.eventLoop.makePromise(of: BodyStructure.self)
        
        // Create the sequence set for a single message
        let seqNum = SequenceNumber(rawValue: UInt32(sequenceNumber))
        let sequenceSet = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<SequenceNumber>(seqNum))!
        
        // Create the FETCH command for the body structure
        let fetchCommand = CommandStreamPart.tagged(
            TaggedCommand(tag: fetchTag, command: .fetch(
                .set(sequenceSet),
                [.bodyStructure(extensions: true)],
                []
            ))
        )
        try await channel.writeAndFlush(fetchCommand).get()
        
        // Set up a timeout for fetch
        logger.debug("Waiting for FETCH BODYSTRUCTURE response...")
        let fetchTimeout = channel.eventLoop.scheduleTask(in: .seconds(10)) { [responseHandler] in
            responseHandler.fetchStructurePromise?.fail(IMAPError.timeout)
        }
        
        do {
            guard let structure = try await responseHandler.fetchStructurePromise?.futureResult.get() else {
                throw IMAPError.fetchFailed("No body structure returned")
            }
            fetchTimeout.cancel()
            logger.info("FETCH BODYSTRUCTURE successful!")
            
            return structure
        } catch {
            logger.error("FETCH BODYSTRUCTURE failed: \(error.localizedDescription, privacy: .public)")
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
    
    /// Fetch all parts of a message
    /// - Parameter sequenceNumber: The sequence number of the message
    /// - Returns: An array of message parts
    /// - Throws: An error if the fetch operation fails
    public func fetchAllMessageParts(sequenceNumber: Int) async throws -> [MessagePart] {
        // First, fetch the message structure to determine the parts
        let structure = try await fetchMessageStructure(sequenceNumber: sequenceNumber)
        
        // Parse the structure and fetch each part
        var parts: [MessagePart] = []
        
        // Process the structure recursively
        try await processStructure(structure, partNumber: "", sequenceNumber: sequenceNumber, parts: &parts)
        
        return parts
    }
    
    /// Process a body structure recursively to fetch all parts
    /// - Parameters:
    ///   - structure: The body structure to process
    ///   - partNumber: The current part number prefix
    ///   - sequenceNumber: The sequence number of the message
    ///   - parts: The array to store the parts in
    /// - Throws: An error if the fetch operation fails
    private func processStructure(_ structure: BodyStructure, partNumber: String, sequenceNumber: Int, parts: inout [MessagePart]) async throws {
        switch structure {
        case .singlepart(let part):
            // Determine the part number
            let currentPartNumber = partNumber.isEmpty ? "1" : partNumber
            
            // Fetch the part content
            let partData = try await fetchMessagePart(sequenceNumber: sequenceNumber, partNumber: currentPartNumber)
            
            // Extract content type and other metadata
            var contentType = ""
            var contentSubtype = ""
            
            switch part.kind {
            case .basic(let mediaType):
                contentType = String(describing: mediaType.topLevel)
                contentSubtype = String(describing: mediaType.sub)
            case .text(let text):
                contentType = "text"
                contentSubtype = String(describing: text.mediaSubtype)
            case .message(let message):
                contentType = "message"
                contentSubtype = String(describing: message.message)
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
                partNumber: currentPartNumber,
                contentType: contentType,
                contentSubtype: contentSubtype,
                disposition: disposition,
                filename: filename,
                contentId: contentId,
                data: partData
            )
            
            // Add the part to the array
            parts.append(messagePart)
            
        case .multipart(let multipart):
            // For multipart messages, process each child part
            for (index, childPart) in multipart.parts.enumerated() {
                let childPartNumber = partNumber.isEmpty ? "\(index + 1)" : "\(partNumber).\(index + 1)"
                try await processStructure(childPart, partNumber: childPartNumber, sequenceNumber: sequenceNumber, parts: &parts)
            }
            
            // If this is the root multipart, add an entry for the multipart itself
            if partNumber.isEmpty {
                // Create a message part for the multipart container (with empty data)
                let messagePart = MessagePart(
                    partNumber: "0",
                    contentType: "multipart",
                    contentSubtype: String(describing: multipart.mediaSubtype),
                    data: Data()
                )
                
                // Add the part to the array
                parts.append(messagePart)
            }
        }
    }
    
    /// Save decoded message parts to the desktop for debugging
    /// - Parameters:
    ///   - sequenceNumber: The sequence number of the message
    ///   - folderName: Optional folder name to organize the output (defaults to "IMAPParts")
    /// - Returns: The path to the saved files
    /// - Throws: An error if the save operation fails
    public func saveMessagePartsToDesktop(sequenceNumber: Int, folderName: String = "IMAPParts") async throws -> String {
        // Fetch all parts of the message
        let parts = try await fetchAllMessageParts(sequenceNumber: sequenceNumber)
        
        // Get the path to the desktop
        let fileManager = FileManager.default
        let desktopURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        
        // Create a folder for the message parts
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        let outputFolderName = "\(folderName)_\(sequenceNumber)_\(timestamp)"
        let outputFolderURL = desktopURL.appendingPathComponent(outputFolderName)
        
        try fileManager.createDirectory(at: outputFolderURL, withIntermediateDirectories: true, attributes: nil)
        
        // Create an index.html file with links to all parts
        var indexHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Message #\(sequenceNumber) Parts</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 20px; }
                table { border-collapse: collapse; width: 100%; }
                th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
                th { background-color: #f2f2f2; }
                tr:nth-child(even) { background-color: #f9f9f9; }
                .preview { max-height: 100px; overflow: auto; border: 1px solid #eee; padding: 5px; }
            </style>
        </head>
        <body>
            <h1>Message #\(sequenceNumber) Parts</h1>
            <p>Total parts: \(parts.count)</p>
            <table>
                <tr>
                    <th>Part #</th>
                    <th>Content Type</th>
                    <th>Filename</th>
                    <th>Size</th>
                    <th>Preview/Link</th>
                </tr>
        """
        
        // Save each part to a file
        for part in parts {
            // Create a filename for the part
            let partFileName: String
            if let filename = part.filename, !filename.isEmpty {
                // Use the original filename if available
                partFileName = sanitizeFileName(filename)
            } else {
                // Create a filename based on part number and content type
                let fileExtension = getFileExtension(for: part.contentType, subtype: part.contentSubtype)
                partFileName = "part_\(part.partNumber.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
            }
            
            // Save the part to a file
            let partFileURL = outputFolderURL.appendingPathComponent(partFileName)
            
            // Check if this is text content that might need decoding
            var dataToSave = part.data
            if part.contentType.lowercased() == "text" {
                if let textContent = String(data: part.data, encoding: .utf8) {
                    // Check for Content-Transfer-Encoding header in the part data
                    let isQuotedPrintable = textContent.contains("Content-Transfer-Encoding: quoted-printable") ||
                                           textContent.contains("Content-Transfer-Encoding:quoted-printable") ||
                                           textContent.contains("=3D") || // Common quoted-printable pattern
                                           textContent.contains("=\r\n") || // Soft line break
                                           textContent.contains("=\n")    // Soft line break
                    
                    if isQuotedPrintable {
                        logger.debug("Decoding quoted-printable content for part #\(part.partNumber)")
                        
                        // Extract charset from Content-Type header if available
                        var charset = "utf-8" // Default charset
                        let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
                        if let range = textContent.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
                           let charsetRange = textContent[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                            charset = String(textContent[charsetRange].replacingOccurrences(of: "charset=", with: ""))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\"", with: "")
                                .replacingOccurrences(of: "'", with: "")
                            logger.debug("Found charset in Content-Type: \(charset)")
                        }
                        
                        // Use the extracted charset for decoding
                        let encoding = String.encodingFromCharset(charset)
                        if let decodedContent = textContent.decodeQuotedPrintable(encoding: encoding) {
                            if let decodedData = decodedContent.data(using: .utf8) {
                                dataToSave = decodedData
                            }
                        } else {
                            // Fallback to the MIMEHeaderDecoder if specific charset decoding fails
                            let decodedContent = MIMEHeaderDecoder.decodeQuotedPrintableContent(textContent)
                            if let decodedData = decodedContent.data(using: .utf8) {
                                dataToSave = decodedData
                            }
                        }
                    }
                }
            }
            
            try dataToSave.write(to: partFileURL)
            
            // Add an entry to the index.html file
            let preview: String
            if part.contentType.lowercased() == "text" {
                // For text parts, show a preview
                if let textContent = String(data: dataToSave, encoding: .utf8) {
                    let truncatedContent = textContent.prefix(500)
                    preview = "<div class='preview'>\(truncatedContent.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</div>"
                } else {
                    preview = "<a href='\(partFileName)'>View</a>"
                }
            } else if part.contentType.lowercased() == "image" {
                // For images, show a thumbnail
                preview = "<a href='\(partFileName)'><img src='\(partFileName)' height='100'></a>"
            } else {
                // For other types, just provide a link
                preview = "<a href='\(partFileName)'>Download</a>"
            }
            
            indexHTML += """
                <tr>
                    <td>\(part.partNumber)</td>
                    <td>\(part.contentType)/\(part.contentSubtype)</td>
                    <td>\(part.filename ?? "")</td>
                    <td>\(formatFileSize(part.size))</td>
                    <td>\(preview)</td>
                </tr>
            """
        }
        
        // Close the HTML
        indexHTML += """
            </table>
        </body>
        </html>
        """
        
        // Write the index.html file
        let indexFileURL = outputFolderURL.appendingPathComponent("index.html")
        try indexHTML.write(to: indexFileURL, atomically: true, encoding: .utf8)
        
        // Return the path to the output folder
        return outputFolderURL.path
    }
    
    /// Sanitize a filename to ensure it's valid
    /// - Parameter filename: The original filename
    /// - Returns: A sanitized filename
    private func sanitizeFileName(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return filename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
    
    /// Get a file extension based on content type
    /// - Parameters:
    ///   - contentType: The content type
    ///   - subtype: The content subtype
    /// - Returns: An appropriate file extension
    private func getFileExtension(for contentType: String, subtype: String) -> String {
        let type = contentType.lowercased()
        let sub = subtype.lowercased()
        
        switch (type, sub) {
        case ("text", "plain"):
            return "txt"
        case ("text", "html"):
            return "html"
        case ("text", _):
            return "txt"
        case ("image", "jpeg"), ("image", "jpg"):
            return "jpg"
        case ("image", "png"):
            return "png"
        case ("image", "gif"):
            return "gif"
        case ("image", _):
            return "img"
        case ("application", "pdf"):
            return "pdf"
        case ("application", "json"):
            return "json"
        case ("application", "javascript"):
            return "js"
        case ("application", "zip"):
            return "zip"
        case ("application", _):
            return "bin"
        case ("audio", "mp3"):
            return "mp3"
        case ("audio", "wav"):
            return "wav"
        case ("audio", _):
            return "audio"
        case ("video", "mp4"):
            return "mp4"
        case ("video", _):
            return "video"
        default:
            return "dat"
        }
    }
    
    /// Format a file size in bytes to a human-readable string
    /// - Parameter bytes: The size in bytes
    /// - Returns: A formatted string (e.g., "1.2 KB")
    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
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
    var fetchPartPromise: EventLoopPromise<Data>?
    var fetchStructurePromise: EventLoopPromise<BodyStructure>?
    
    // Tags to identify commands
    var loginTag: String?
    var selectTag: String?
    var logoutTag: String?
    var fetchTag: String?
    var fetchPartTag: String?
    var fetchStructureTag: String?
    
    // Current mailbox being selected
    var currentMailboxName: String?
    var currentMailboxInfo: MailboxInfo?
    
    // Collected email headers
    private var emailHeaders: [EmailHeader] = []
    
    // Message part data
    private var partData: Data = Data()
    
    // Message body structure
    private var bodyStructure: BodyStructure?
    
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
        
        // Process FETCH responses for message parts
        if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchPartPromise != nil }) {
            switch fetchResponse {
            case .simpleAttribute(let attribute):
                if case .body(_, _) = attribute {
                    // This is a body structure response, not what we're looking for
                    logger.debug("Received body structure in part fetch")
                }
            case .streamingBegin(let kind, let size):
                if case .body(_, _) = kind {
                    logger.debug("Received streaming body data of size \(size)")
                    // We'll collect the data in the streamingBytes case
                }
            case .streamingBytes(let data):
                // Collect the streaming body data
                lock.withLock {
                    self.partData.append(Data(data.readableBytesView))
                }
            default:
                break
            }
        }
        
        // Process FETCH responses for message structure
        if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchStructurePromise != nil }) {
            switch fetchResponse {
            case .simpleAttribute(let attribute):
                if case .body(let bodyStructure, _) = attribute {
                    if case .valid(let structure) = bodyStructure {
                        // Store the body structure
                        lock.withLock {
                            self.bodyStructure = structure
                        }
                    }
                }
            default:
                break
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
                        self.selectPromise?.fail(IMAPError.selectFailed(String(describing: taggedResponse.state))) }
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
            
            // Handle fetch part response
            if taggedResponse.tag == lock.withLock({ self.fetchPartTag }) {
                if case .ok = taggedResponse.state {
                    let partData = lock.withLock { () -> Data in
                        let data = self.partData
                        self.partData = Data()
                        return data
                    }
                    lock.withLock { self.fetchPartPromise?.succeed(partData) }
                } else {
                    lock.withLock { 
                        self.fetchPartPromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
                        self.partData = Data()
                    }
                }
            }
            
            // Handle fetch structure response
            if taggedResponse.tag == lock.withLock({ self.fetchStructureTag }) {
                if case .ok = taggedResponse.state {
                    let structure = lock.withLock { () -> BodyStructure? in
                        let structure = self.bodyStructure
                        self.bodyStructure = nil
                        return structure
                    }
                    
                    if let structure = structure {
                        lock.withLock { self.fetchStructurePromise?.succeed(structure) }
                    } else {
                        lock.withLock { self.fetchStructurePromise?.fail(IMAPError.fetchFailed("No body structure found")) }
                    }
                } else {
                    lock.withLock { 
                        self.fetchStructurePromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
                        self.bodyStructure = nil
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
            self.fetchPartPromise?.fail(error)
            self.fetchStructurePromise?.fail(error)
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
            
            // Convert charset to String.Encoding
            let stringEncoding = String.encodingFromCharset(charset)
            
            // Decode based on encoding type
            if encoding == "B" {
                // Base64 encoding
                if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                   let decoded = String(data: data, encoding: stringEncoding) {
                    decodedText = decoded
                } else {
                    // Try with UTF-8 if the specified charset fails
                    if let data = Data(base64Encoded: encodedText, options: .ignoreUnknownCharacters),
                       let decoded = String(data: data, encoding: .utf8) {
                        decodedText = decoded
                    }
                }
            } else if encoding == "Q" {
                // Quoted-printable encoding
                if let decoded = encodedText.decodeQuotedPrintable(encoding: stringEncoding) {
                    decodedText = decoded
                } else if let decoded = encodedText.decodeQuotedPrintable() {
                    // Fallback to UTF-8 if the specified charset fails
                    decodedText = decoded
                }
            }
            
            if !decodedText.isEmpty {
                result = result.replacingCharacters(in: fullRange, with: decodedText)
            }
        }
        
        // Handle consecutive encoded words (they should be concatenated without spaces)
        result = result.replacingOccurrences(of: "?= =?", with: "")
        
        return result
    }
    
    /// Decode quoted-printable content in message bodies
    /// - Parameter content: The content to decode
    /// - Returns: The decoded content
    public static func decodeQuotedPrintableContent(_ content: String) -> String {
        // Split the content into lines
        let lines = content.components(separatedBy: .newlines)
        var inBody = false
        var bodyContent = ""
        var headerContent = ""
        var contentEncoding: String.Encoding = .utf8
        
        // Process each line
        for line in lines {
            if !inBody {
                // Check if we've reached the end of headers
                if line.isEmpty {
                    inBody = true
                    headerContent += line + "\n"
                    continue
                }
                
                // Add header line
                headerContent += line + "\n"
                
                // Check for Content-Type header with charset
                if line.lowercased().contains("content-type:") && line.lowercased().contains("charset=") {
                    if let range = line.range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                        let charsetString = line[range].replacingOccurrences(of: "charset=", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        contentEncoding = String.encodingFromCharset(charsetString)
                    }
                }
                
                // Check if this is a Content-Transfer-Encoding header
                if line.lowercased().contains("content-transfer-encoding:") && 
                   line.lowercased().contains("quoted-printable") {
                    // Found quoted-printable encoding
                    inBody = false
                }
            } else {
                // Add body line
                bodyContent += line + "\n"
            }
        }
        
        // If we found quoted-printable encoding, decode the body
        if !bodyContent.isEmpty {
            // Decode the body content with the detected encoding
            if let decodedBody = bodyContent.decodeQuotedPrintable(encoding: contentEncoding) {
                return headerContent + decodedBody
            } else if let decodedBody = bodyContent.decodeQuotedPrintable() {
                // Fallback to UTF-8 if the specified charset fails
                return headerContent + decodedBody
            }
        }
        
        // If we didn't find quoted-printable encoding or no body content,
        // try to decode the entire content with the detected charset
        if let decodedContent = content.decodeQuotedPrintable(encoding: contentEncoding) {
            return decodedContent
        }
        
        // Last resort: try with UTF-8
        return content.decodeQuotedPrintable() ?? content
    }
}

// MARK: - Message Part

/// Structure to hold information about a message part
public struct MessagePart: Sendable {
    /// The part number (e.g., "1", "1.1", "2", etc.)
    public let partNumber: String
    
    /// The content type of the part
    public let contentType: String
    
    /// The content subtype of the part
    public let contentSubtype: String
    
    /// The content disposition of the part (e.g., "attachment", "inline")
    public let disposition: String?
    
    /// The filename of the part (if available)
    public let filename: String?
    
    /// The content ID of the part (if available)
    public let contentId: String?
    
    /// The content of the part
    public let data: Data
    
    /// The size of the part in bytes
    public var size: Int {
        return data.count
    }
    
    /// Initialize a new message part
    /// - Parameters:
    ///   - partNumber: The part number
    ///   - contentType: The content type
    ///   - contentSubtype: The content subtype
    ///   - disposition: The content disposition
    ///   - filename: The filename
    ///   - contentId: The content ID
    ///   - data: The content data
    public init(partNumber: String, contentType: String, contentSubtype: String, disposition: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data) {
        self.partNumber = partNumber
        self.contentType = contentType
        self.contentSubtype = contentSubtype
        self.disposition = disposition
        self.filename = filename
        self.contentId = contentId
        self.data = data
    }
    
    /// A string representation of the message part
    public var description: String {
        return """
        Part #\(partNumber)
        Content-Type: \(contentType)/\(contentSubtype)
        \(disposition != nil ? "Content-Disposition: \(disposition!)" : "")
        \(filename != nil ? "Filename: \(filename!)" : "")
        \(contentId != nil ? "Content-ID: \(contentId!)" : "")
        Size: \(size) bytes
        """
    }
} 

