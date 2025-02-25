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
public class IMAPServer {
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
        self.responseHandler = responseHandler
        
        // Set up the channel handlers
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                // Add SSL handler first for secure connection
                let sslHandler = try! NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
                
                return channel.pipeline.addHandler(sslHandler).flatMap {
                    // Add the IMAP client handler to the pipeline
                    channel.pipeline.addHandler(IMAPClientHandler()).flatMap {
                        channel.pipeline.addHandler(responseHandler)
                    }
                }
            }
        
        // Connect to the server
        logger.info("Connecting to \(self.host):\(self.port)...")
        self.channel = try await bootstrap.connect(host: host, port: port).get()
        logger.info("Connected to server")
        
        // Wait for the server greeting
        logger.debug("Waiting for server greeting...")
        try await waitForGreeting()
        logger.info("Server greeting received!")
    }
    
    /// Wait for the server greeting
    /// - Throws: An error if the greeting times out or fails
    private func waitForGreeting() async throws {
        guard let channel = self.channel, let responseHandler = self.responseHandler else {
            throw IMAPError.connectionFailed("Channel or response handler not initialized")
        }
        
        // Create a promise for the greeting
        responseHandler.greetingPromise = channel.eventLoop.makePromise(of: Void.self)
        
        // Set up a timeout for the greeting
        let greetingTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            responseHandler.greetingPromise?.fail(IMAPError.timeout)
        }
        
        // Wait for the greeting
        do {
            try await responseHandler.greetingPromise?.futureResult.get()
            greetingTimeout.cancel()
        } catch {
            logger.error("Failed to receive server greeting: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Login to the IMAP server
    /// - Parameters:
    ///   - username: The username for authentication
    ///   - password: The password for authentication
    /// - Throws: An error if the login fails
    public func login(username: String, password: String) async throws {
        guard let channel = self.channel, let responseHandler = self.responseHandler else {
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
        let loginTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            responseHandler.loginPromise?.fail(IMAPError.timeout)
        }
        
        do {
            try await responseHandler.loginPromise?.futureResult.get()
            loginTimeout.cancel()
            logger.info("Login successful!")
        } catch {
            logger.error("Login failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Select a mailbox
    /// - Parameter mailboxName: The name of the mailbox to select
    /// - Returns: Information about the selected mailbox
    /// - Throws: An error if the select operation fails
    public func selectMailbox(_ mailboxName: String) async throws -> MailboxInfo {
        guard let channel = self.channel, let responseHandler = self.responseHandler else {
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
        let selectTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
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
            logger.error("SELECT failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Logout from the IMAP server
    /// - Throws: An error if the logout fails
    public func logout() async throws {
        guard let channel = self.channel, let responseHandler = self.responseHandler else {
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
        let logoutTimeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            responseHandler.logoutPromise?.fail(IMAPError.timeout)
        }
        
        do {
            try await responseHandler.logoutPromise?.futureResult.get()
            logoutTimeout.cancel()
            logger.info("LOGOUT successful!")
        } catch {
            logger.error("LOGOUT failed: \(error.localizedDescription)")
            // Continue with closing even if logout fails
            throw error
        }
    }
    
    /// Close the connection to the IMAP server
    /// - Throws: An error if the close operation fails
    public func close() async throws {
        guard let channel = self.channel else {
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
}

// MARK: - Response Handler

/// A custom handler to process IMAP responses
final class IMAPResponseHandler: ChannelInboundHandler {
    typealias InboundIn = Response
    
    // Promises for different command responses
    var greetingPromise: EventLoopPromise<Void>?
    var loginPromise: EventLoopPromise<Void>?
    var selectPromise: EventLoopPromise<MailboxInfo>?
    var logoutPromise: EventLoopPromise<Void>?
    
    // Tags to identify commands
    var loginTag: String?
    var selectTag: String?
    var logoutTag: String?
    
    // Current mailbox being selected
    var currentMailboxName: String?
    var currentMailboxInfo: MailboxInfo?
    
    // Logger for IMAP responses
    private let logger = Logger(subsystem: "com.example.SwiftIMAP", category: "IMAPResponseHandler")
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        logger.debug("Received: \(String(describing: response))")
        
        // Print all responses to console for better visibility
        print("IMAP RESPONSE: \(response)")
        
        // Check if this is an untagged response (server greeting)
        if case .untagged(_) = response, greetingPromise != nil {
            // Server greeting is typically an untagged OK response
            // The first response from the server is the greeting
            greetingPromise?.succeed(())
        }
        
        // Process untagged responses for mailbox information during SELECT
        if case .untagged(let untaggedResponse) = response, selectPromise != nil, let mailboxName = currentMailboxName {
            if currentMailboxInfo == nil {
                currentMailboxInfo = MailboxInfo(name: mailboxName)
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
                            currentMailboxInfo?.firstUnseen = Int(firstUnseen)
                            logger.debug("First unseen message: \(String(describing: firstUnseen))")
                            
                        case .uidValidity(let validity):
                            // Use the BinaryInteger extension to convert UIDValidity to UInt32
                            currentMailboxInfo?.uidValidity = UInt32(validity)
                            print("DEBUG: UID validity value: \(UInt32(validity))")
                            
                        case .uidNext(let next):
                            // Use the BinaryInteger extension to convert UID to UInt32
                            currentMailboxInfo?.uidNext = UInt32(next)
                            logger.debug("Next UID: \(UInt32(next))")
                            
                        case .permanentFlags(let flags):
                            currentMailboxInfo?.permanentFlags = flags.map { String(describing: $0) }
                            logger.debug("Permanent flags: \(flags.map { String(describing: $0) }.joined(separator: ", "))")
                            
                        case .readOnly:
                            currentMailboxInfo?.isReadOnly = true
                            logger.debug("Mailbox is read-only")
                            
                        case .readWrite:
                            currentMailboxInfo?.isReadOnly = false
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
                    currentMailboxInfo?.messageCount = Int(count)
                    logger.debug("Mailbox has \(count) messages")
                    
                case .recent(let count):
                    currentMailboxInfo?.recentCount = Int(count)
                    logger.debug("Mailbox has \(count) recent messages - RECENT FLAG DETAILS")
                    print("DEBUG: Mailbox has \(count) recent messages - RECENT FLAG DETAILS")
                    
                case .flags(let flags):
                    currentMailboxInfo?.availableFlags = flags.map { String(describing: $0) }
                    logger.debug("Available flags: \(flags.map { String(describing: $0) }.joined(separator: ", "))")
                    
                default:
                    logger.debug("Unhandled mailbox data: \(String(describing: mailboxData))")
                    break
                }
                
            case .messageData(let messageData):
                // Handle message data if needed
                logger.debug("Received message data: \(String(describing: messageData))")
                
            default:
                logger.debug("Unhandled untagged response: \(String(describing: untaggedResponse))")
                break
            }
        }
        
        // Check if this is a tagged response that matches one of our commands
        if case .tagged(let taggedResponse) = response {
            // Handle login response
            if taggedResponse.tag == loginTag {
                if case .ok = taggedResponse.state {
                    loginPromise?.succeed(())
                } else {
                    loginPromise?.fail(IMAPError.loginFailed(String(describing: taggedResponse.state)))
                }
            }
            
            // Handle select response
            if taggedResponse.tag == selectTag {
                if case .ok = taggedResponse.state {
                    if var mailboxInfo = currentMailboxInfo {
                        // If we have a first unseen message but unseen count is 0,
                        // calculate the unseen count as (total messages - first unseen + 1)
                        if mailboxInfo.firstUnseen > 0 && mailboxInfo.unseenCount == 0 {
                            mailboxInfo.unseenCount = mailboxInfo.messageCount - mailboxInfo.firstUnseen + 1
                            logger.debug("Calculated unseen count: \(mailboxInfo.unseenCount)")
                            // Update the current mailbox info with the modified copy
                            currentMailboxInfo = mailboxInfo
                        }
                        
                        selectPromise?.succeed(mailboxInfo)
                    } else if let mailboxName = currentMailboxName {
                        // If we didn't get any untagged responses with mailbox info, create a basic one
                        selectPromise?.succeed(MailboxInfo(name: mailboxName))
                    } else {
                        selectPromise?.fail(IMAPError.selectFailed("No mailbox information available"))
                    }
                    
                    // Reset for next select
                    currentMailboxName = nil
                    currentMailboxInfo = nil
                } else {
                    selectPromise?.fail(IMAPError.selectFailed(String(describing: taggedResponse.state)))
                }
            }
            
            // Handle logout response
            if taggedResponse.tag == logoutTag {
                if case .ok = taggedResponse.state {
                    logoutPromise?.succeed(())
                } else {
                    logoutPromise?.fail(IMAPError.logoutFailed(String(describing: taggedResponse.state)))
                }
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error: \(error.localizedDescription)")
        
        // Fail all pending promises
        greetingPromise?.fail(error)
        loginPromise?.fail(error)
        selectPromise?.fail(error)
        logoutPromise?.fail(error)
        
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
        case .timeout:
            return "Operation timed out"
        }
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