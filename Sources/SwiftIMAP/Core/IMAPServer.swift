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
	
	/** Server capabilities */
	private var capabilities: Set<NIOIMAPCore.Capability> = []
	
	/** The current folder configuration */
	private var folderConfig: FolderConfiguration = .default
	
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
	
	/// Error thrown when a standard folder is not defined
	public struct UndefinedFolderError: Error, CustomStringConvertible {
		public let folderType: String
		
		public var description: String {
			return "Standard folder '\(folderType)' is not defined. Call detectStandardFolders() first or set a custom folder configuration."
		}
	}
	
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
	
	// MARK: - Connection and Login Commands
	
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
		// The greeting handler now returns capabilities if they were in the greeting
		let greetingCapabilities: [Capability] = try await executeHandlerOnly(handlerType: GreetingHandler.self, timeoutSeconds: 5)
		
		// If we got capabilities from the greeting, use them
		if !greetingCapabilities.isEmpty {
			self.capabilities = Set(greetingCapabilities)
		} else {
			// Otherwise, fetch capabilities explicitly
			// _ = try await fetchCapabilities()
		}
	}
	
	/**
	 Fetch server capabilities
	 - Throws: An error if the capability command fails
	 - Returns: An array of server capabilities
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
	 Login to the IMAP server
	 - Parameters:
	 - username: The username for authentication
	 - password: The password for authentication
	 - Throws: An error if the login fails
	 */
	public func login(username: String, password: String) async throws {
		let command = LoginCommand(username: username, password: password)
		let loginCapabilities = try await executeCommand(command)
		
		// If we got capabilities from the login response, use them
		if !loginCapabilities.isEmpty {
			self.capabilities = Set(loginCapabilities)
		} else {
			// Otherwise, fetch capabilities explicitly
			// _ = try await fetchCapabilities()
		}
	}
	
	/**
	 Close the connection to the IMAP server
	 - Throws: An error if the close operation fails
	 */
	public func disconnect() async throws {
		guard let _ = self.channel else {
			throw IMAPError.connectionFailed("Channel not initialized")
		}
		
		// Use the same command execution pattern as other commands
		let command = DisconnectCommand()
		try await executeCommand(command)
		
		// After successful disconnect, set channel to nil
		self.channel = nil
	}
	
	// MARK: - Mailbox Commands
	
	/**
	 Select a mailbox
	 - Parameter mailboxName: The name of the mailbox to select
	 - Returns: Status information about the selected mailbox
	 - Throws: An error if the select operation fails
	 */
	public func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Status {
		let command = SelectMailboxCommand(mailboxName: mailboxName)
		return try await executeCommand(command)
	}
	
	/**
	 Close the currently selected mailbox
	 - Throws: An error if the close operation fails
	 */
	public func closeMailbox() async throws {
		let command = CloseCommand()
		try await executeCommand(command)
	}
	
	/**
	 Logout from the IMAP server
	 - Throws: An error if the logout fails
	 */
	public func logout() async throws {
		let command = LogoutCommand()
		try await executeCommand(command)
	}
	
	// MARK: - Message Commands
	
	/**
	 Fetch headers for messages in the selected mailbox
	 - Parameters:
	 - identifierSet: The set of message identifiers to fetch
	 - limit: Optional limit on the number of headers to return
	 - Returns: An array of email headers
	 - Throws: An error if the fetch operation fails
	 */
	public func fetchHeaders<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) async throws -> [Header] {
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
	 Fetch a complete email with all parts from an email header
	 - Parameter header: The email header to fetch the complete email for
	 - Returns: A complete Email object with all parts
	 - Throws: An error if the fetch operation fails
	 */
	public func fetchMessage(from header: Header) async throws -> Message {
		// Use the UID from the header if available (non-zero), otherwise fall back to sequence number
		if header.uid > 0 {
			// Use UID for fetching
			let uid = UID(UInt32(header.uid))
			let parts = try await fetchAllMessageParts(identifier: uid)
			return Message(header: header, parts: parts)
		} else {
			// Fall back to sequence number
			let sequenceNumber = SequenceNumber(UInt32(header.sequenceNumber))
			let parts = try await fetchAllMessageParts(identifier: sequenceNumber)
			return Message(header: header, parts: parts)
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
	public func fetchMessages<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>, limit: Int? = nil) async throws -> [Message] {
		guard !identifierSet.isEmpty else {
			throw IMAPError.emptyIdentifierSet
		}
		
		// First fetch the headers
		let headers = try await fetchHeaders(using: identifierSet, limit: limit)
		
		// Then fetch the complete email for each header
		var emails: [Message] = []
		for header in headers {
			let email = try await fetchMessage(from: header)
			emails.append(email)
		}
		
		return emails
	}
	
	/**
	 Copy messages from the current mailbox to another mailbox
	 - Parameters:
	 - messages: The set of message identifiers to copy
	 - destinationMailbox: The name of the destination mailbox
	 - Throws: An error if the copy operation fails
	 */
	public func copy<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
		let command = CopyCommand(identifierSet: identifierSet, destinationMailbox: destinationMailbox)
		try await executeCommand(command)
	}
	
	/**
	 Copy a single message from the current mailbox to another mailbox
	 - Parameters:
	 - message: The message identifier to copy
	 - destinationMailbox: The name of the destination mailbox
	 - Throws: An error if the copy operation fails
	 */
	public func copy<T: MessageIdentifier>(message identifier: T, to destinationMailbox: String) async throws {
		let set = MessageIdentifierSet<T>(identifier)
		try await copy(messages: set, to: destinationMailbox)
	}
	
	/**
	 Expunge deleted messages from the selected mailbox
	 - Throws: An error if the expunge operation fails
	 */
	public func expunge() async throws {
		let command = ExpungeCommand()
		try await executeCommand(command)
	}
	
	/**
	 Internal function to execute the MOVE command
	 - Parameters:
	 - messages: The set of message identifiers to move
	 - destinationMailbox: The name of the destination mailbox
	 - Throws: An error if the move operation fails
	 */
	private func executeMove<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
		let command = MoveCommand(identifierSet: identifierSet, destinationMailbox: destinationMailbox)
		try await executeCommand(command)
	}
	
	/**
	 Move messages from the current mailbox to another mailbox
	 If the server supports the MOVE command and UIDPLUS (when using UIDs), it will use that.
	 Otherwise, it will fall back to copy + delete + expunge.
	 - Parameters:
	 - messages: The set of message identifiers to move
	 - destinationMailbox: The name of the destination mailbox
	 - Throws: An error if the move operation fails
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
	public func move(header: Header, to destinationMailbox: String) async throws {
		// Use the UID from the header if available (non-zero), otherwise fall back to sequence number
		if header.uid > 0 {
			// Use UID for moving
			let uid = UID(UInt32(header.uid))
			try await move(message: uid, to: destinationMailbox)
		} else {
			// Fall back to sequence number
			let sequenceNumber = SequenceNumber(UInt32(header.sequenceNumber))
			try await move(message: sequenceNumber, to: destinationMailbox)
		}
	}
	
	/**
	 Store flags on messages
	 - Parameters:
	 - flags: The flags to store
	 - messages: The set of message identifiers to update
	 - operation: The store operation (.add or .remove)
	 - Throws: An error if the operation fails
	 */
	public func store<T: MessageIdentifier>(flags: [Flag], on identifierSet: MessageIdentifierSet<T>, operation: StoreOperation) async throws {
		let storeData = StoreData.flags(flags, operation == .add ? .add : .remove)
		let command = StoreCommand(identifierSet: identifierSet, data: storeData)
		try await executeCommand(command)
	}
	
	public enum StoreOperation {
		case add
		case remove
	}
	
	// MARK: - Sub-Commands
	
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
	
	// MARK: - Command Helpers
	
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

// MARK: - Common Mail Operations
extension IMAPServer {
	/// Configuration for standard IMAP folders
	public struct FolderConfiguration {
		/// The name of the trash folder
		public var trash: String
		/// The name of the archive folder
		public var archive: String
		/// The name of the sent folder
		public var sent: String
		/// The name of the drafts folder
		public var drafts: String
		/// The name of the junk/spam folder
		public var junk: String
		
		/// Default folder configuration
		public static let `default` = FolderConfiguration(
			trash: "Trash",
			archive: "Archive",
			sent: "Sent",
			drafts: "Drafts",
			junk: "Junk"
		)
		
		/// Gmail-style folder configuration
		public static let gmail = FolderConfiguration(
			trash: "[Gmail]/Trash",
			archive: "[Gmail]/All Mail",
			sent: "[Gmail]/Sent Mail",
			drafts: "[Gmail]/Drafts",
			junk: "[Gmail]/Spam"
		)
		
		/// Apple Mail-style folder configuration
		public static let apple = FolderConfiguration(
			trash: "Deleted Messages",
			archive: "Archive",
			sent: "Sent Messages",
			drafts: "Drafts",
			junk: "Junk"
		)
		
		/// Outlook-style folder configuration
		public static let outlook = FolderConfiguration(
			trash: "Deleted Items",
			archive: "Archive",
			sent: "Sent Items",
			drafts: "Drafts",
			junk: "Junk Email"
		)
	}
	
	/// Get the current folder configuration
	public func getFolderConfiguration() -> FolderConfiguration {
		return folderConfig
	}
	
	/// Set a custom folder configuration
	public func setFolderConfiguration(_ config: FolderConfiguration) {
		self.folderConfig = config
	}
	
	/// List all available mailboxes
	/// - Returns: Array of mailbox information
	/// - Throws: An error if the operation fails
	public func listMailboxes() async throws -> [Mailbox.Info] {
		let command = ListCommand()
		return try await executeCommand(command)
	}
	
	/**
	 Attempt to detect the server's standard folder names by checking common variations
	 This method will update the folder configuration automatically if standard folders are found
	 - Returns: The detected folder configuration
	 - Throws: An error if the operation fails
	 */
	public func detectStandardFolders() async throws -> FolderConfiguration {
		// Common variations of standard folder names
		let trashVariations = ["Trash", "[Gmail]/Trash", "Deleted Messages", "Deleted Items", "Deleted", "Papierkorb"]
		let archiveVariations = ["Archive", "[Gmail]/All Mail", "Archives", "Archived", "Archiv"]
		let sentVariations = ["Sent", "[Gmail]/Sent Mail", "Sent Messages", "Sent Items", "Gesendet"]
		let draftsVariations = ["Drafts", "[Gmail]/Drafts", "Draft", "Entwürfe"]
		let junkVariations = ["Junk", "[Gmail]/Spam", "Spam", "Junk Email", "Junk Mail", "Spam-E-Mail"]
		
		// Get list of available mailboxes
		let mailboxInfos = try await listMailboxes()
		let mailboxNames = mailboxInfos.map { $0.name }
		var config = FolderConfiguration.default
		
		// Helper function to find first matching folder
		func findFolder(variations: [String], type: String) -> String? {
			let found = variations.first { variation in
				mailboxNames.contains { $0.caseInsensitiveCompare(variation) == .orderedSame }
			}
			if found == nil {
				logger.warning("Could not detect standard folder: \(type). Available variations: \(variations.joined(separator: ", "))")
			}
			return found
		}
		
		// Try to detect each standard folder
		if let trash = findFolder(variations: trashVariations, type: "Trash") {
			config.trash = trash
		}
		
		if let archive = findFolder(variations: archiveVariations, type: "Archive") {
			config.archive = archive
		}
		
		if let sent = findFolder(variations: sentVariations, type: "Sent") {
			config.sent = sent
		}
		
		if let drafts = findFolder(variations: draftsVariations, type: "Drafts") {
			config.drafts = drafts
		}
		
		if let junk = findFolder(variations: junkVariations, type: "Junk") {
			config.junk = junk
		}
		
		// Update the configuration
		self.folderConfig = config
		return config
	}
	
	/// Get the current trash folder name or throw if undefined
	public var trashFolder: String {
		get throws {
			guard !folderConfig.trash.isEmpty else {
				throw UndefinedFolderError(folderType: "Trash")
			}
			return folderConfig.trash
		}
	}
	
	/// Get the current archive folder name or throw if undefined
	public var archiveFolder: String {
		get throws {
			guard !folderConfig.archive.isEmpty else {
				throw UndefinedFolderError(folderType: "Archive")
			}
			return folderConfig.archive
		}
	}
	
	/// Get the current sent folder name or throw if undefined
	public var sentFolder: String {
		get throws {
			guard !folderConfig.sent.isEmpty else {
				throw UndefinedFolderError(folderType: "Sent")
			}
			return folderConfig.sent
		}
	}
	
	/// Get the current drafts folder name or throw if undefined
	public var draftsFolder: String {
		get throws {
			guard !folderConfig.drafts.isEmpty else {
				throw UndefinedFolderError(folderType: "Drafts")
			}
			return folderConfig.drafts
		}
	}
	
	/// Get the current junk folder name or throw if undefined
	public var junkFolder: String {
		get throws {
			guard !folderConfig.junk.isEmpty else {
				throw UndefinedFolderError(folderType: "Junk")
			}
			return folderConfig.junk
		}
	}
}

// Update the existing methods to use the throwing getters
extension IMAPServer {
	public func moveToTrash<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
		try await move(messages: identifierSet, to: try trashFolder)
	}
	
	public func archive<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
		try await store(flags: [.seen], on: identifierSet, operation: .add)
		try await move(messages: identifierSet, to: try archiveFolder)
	}
	
	public func markAsJunk<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
		try await move(messages: identifierSet, to: try junkFolder)
	}
	
	public func saveAsDraft<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
		try await store(flags: [.draft], on: identifierSet, operation: .add)
		try await move(messages: identifierSet, to: try draftsFolder)
	}
}
