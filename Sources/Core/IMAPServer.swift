// IMAPServer.swift
// A Swift IMAP client that encapsulates connection logic

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL
import NIOConcurrencyHelpers

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
    private let logger = Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "IMAPServer")
    
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

