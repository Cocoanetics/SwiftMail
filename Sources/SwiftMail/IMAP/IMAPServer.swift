import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
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

    /// Primary connection used for non-IDLE commands.
    private let primaryConnection: IMAPConnection

    /// Spawned IDLE connections keyed by session ID.
    private var idleConnections: [UUID: IdleConnection] = [:]

    /// User-managed named connections keyed by requested name.
    private var namedConnections: [String: NamedConnection] = [:]

    /// Authentication configuration for spawning new connections.
    private var authentication: Authentication?
    
    /** The list of all mailboxes with their attributes */
    public private(set) var mailboxes: [Mailbox.Info] = []
    
    /** Special folders - mailboxes with SPECIAL-USE attributes */
    public private(set) var specialMailboxes: [Mailbox.Info] = []
    
    /// Namespaces discovered from the server
    public private(set) var namespaces: NamespaceResponse?
    
    /// Capabilities reported by the primary connection.
    private var capabilities: Set<NIOIMAPCore.Capability> {
        primaryConnection.capabilitiesSnapshot
    }
    
    /**
     Logger for IMAP operations
     To view these logs in Console.app:
     1. Open Console.app
     2. In the search field, type "process:com.cocoanetics.SwiftIMAP"
     3. You may need to adjust the "Action" menu to show "Include Debug Messages" and "Include Info Messages"
     */
    private let logger: Logging.Logger
    
    private struct IdleConnection {
        let mailbox: String
        let connection: IMAPConnection
    }

    private struct NamedConnection {
        let connection: IMAPConnection
        let handle: IMAPNamedConnection
    }

    private enum Authentication {
        case login(username: String, password: String)
        case xoauth2(email: String, accessTokenProvider: @Sendable () async throws -> String)

        func authenticate(on connection: IMAPConnection) async throws {
            switch self {
            case .login(let username, let password):
                try await connection.login(username: username, password: password)
            case .xoauth2(let email, let accessTokenProvider):
                let accessToken = try await accessTokenProvider()
                try await connection.authenticateXOAUTH2(email: email, accessToken: accessToken)
            }
        }
    }
    
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

        let primaryLoggerLabel = "com.cocoanetics.SwiftMail.IMAPServer"
        let outboundLabel = "com.cocoanetics.SwiftMail.IMAP_OUT"
        let inboundLabel = "com.cocoanetics.SwiftMail.IMAP_IN"
        self.primaryConnection = IMAPConnection(
            host: host,
            port: port,
            group: group,
            loggerLabel: primaryLoggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: "primary",
            connectionRole: "primary"
        )
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
        try await primaryConnection.connect()
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
        try await primaryConnection.fetchCapabilities()
    }
    
    /**
     Check if the server supports a specific capability
     - Parameter capability: The capability to check for
     - Returns: True if the server supports the capability
     */
    private func supportsCapability(_ check: (Capability) -> Bool) -> Bool {
        return primaryConnection.supportsCapability(check)
    }
    
    /**
     Check if the connection to the IMAP server is currently active
     - Returns: True if the connection is active and ready for commands
     */
    public var isConnected: Bool {
        primaryConnection.isConnected
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
        try await primaryConnection.login(username: username, password: password)
        authentication = .login(username: username, password: password)
        namespaces = primaryConnection.namespacesSnapshot
    }

    /// Performs XOAUTH2 authentication for the current IMAP connection.
    /// - Parameters:
    ///   - email: The full mailbox address to authenticate as.
    ///   - accessToken: The OAuth 2.0 access token.
    /// - Throws: ``IMAPError.unsupportedAuthMechanism`` if the server does not advertise XOAUTH2 or ``IMAPError.authFailed`` when authentication fails.
    public func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        try await primaryConnection.authenticateXOAUTH2(email: email, accessToken: accessToken)
        authentication = .xoauth2(email: email, accessTokenProvider: { accessToken })
        namespaces = primaryConnection.namespacesSnapshot
    }

    /// Configures XOAUTH2 re-authentication to resolve the access token dynamically.
    /// Use this after a successful OAuth-backed login so automatic reconnects do not reuse a stale token.
    public func setXOAUTH2AccessTokenProvider(
        email: String,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        authentication = .xoauth2(email: email, accessTokenProvider: accessTokenProvider)
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
        try await closeAllConnections()
    }

    /// Retrieve (or create) a reusable named connection.
    ///
    /// Calling this method multiple times with the same `name` returns the same
    /// underlying authenticated connection handle.
    ///
    /// - Parameter name: Stable user-defined name for this connection.
    /// - Returns: A user-controlled named connection.
    /// - Throws: ``IMAPError/invalidArgument(_:)`` when `name` is empty or
    ///   ``IMAPError/commandFailed(_:)`` if authentication is not configured.
    public func connection(named name: String) async throws -> IMAPNamedConnection {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw IMAPError.invalidArgument("Connection name must not be empty")
        }

        if let existing = namedConnections[normalizedName] {
            return existing.handle
        }

        guard let authentication else {
            throw IMAPError.commandFailed("Authentication required before creating a named connection")
        }

        let connection = makeNamedConnection(name: normalizedName)

        do {
            try await connection.connect()
            try await authentication.authenticate(on: connection)

            let handle = IMAPNamedConnection(
                name: normalizedName,
                connection: connection,
                authenticateOnConnection: { connection in
                    try await authentication.authenticate(on: connection)
                }
            )

            namedConnections[normalizedName] = NamedConnection(connection: connection, handle: handle)
            return handle
        } catch {
            try? await connection.disconnect()
            throw error
        }
    }

    // MARK: - Connection Management

    private func makeIdleConnection(sessionID: UUID, mailbox: String) -> IMAPConnection {
        let shortID = String(sessionID.uuidString.prefix(8))
        let suffix = "idle-\(shortID)"
        let sanitizedMailbox = mailbox
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")

        let loggerLabel = "com.cocoanetics.SwiftMail.IMAPServer.\(suffix)"
        let outboundLabel = "com.cocoanetics.SwiftMail.IMAP_OUT.\(suffix)"
        let inboundLabel = "com.cocoanetics.SwiftMail.IMAP_IN.\(suffix)"

        return IMAPConnection(
            host: host,
            port: port,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: shortID,
            connectionRole: "idle:\(sanitizedMailbox)"
        )
    }

    private func makeNamedConnection(name: String) -> IMAPConnection {
        let sanitizedName = sanitizedConnectionName(name)
        let suffix = "named-\(sanitizedName)"
        let shortID = String(sanitizedName.prefix(24))

        let loggerLabel = "com.cocoanetics.SwiftMail.IMAPServer.\(suffix)"
        let outboundLabel = "com.cocoanetics.SwiftMail.IMAP_OUT.\(suffix)"
        let inboundLabel = "com.cocoanetics.SwiftMail.IMAP_IN.\(suffix)"

        return IMAPConnection(
            host: host,
            port: port,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: "named-\(shortID)",
            connectionRole: "named:\(sanitizedName)"
        )
    }

    private func sanitizedConnectionName(_ name: String) -> String {
        let mapped = name.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if collapsed.isEmpty {
            return "connection"
        }
        return String(collapsed.prefix(48))
    }

    private func endIdleSession(id: UUID) async throws {
        guard let entry = idleConnections.removeValue(forKey: id) else { return }

        try? await entry.connection.done()
        try? await entry.connection.disconnect()
    }

    private func closeAllConnections() async throws {
        let idleEntries = idleConnections
        idleConnections.removeAll()

        for entry in idleEntries.values {
            try? await entry.connection.done()
            try? await entry.connection.disconnect()
        }

        let namedEntries = namedConnections
        namedConnections.removeAll()

        for entry in namedEntries.values {
            try? await entry.connection.done()
            try? await entry.connection.disconnect()
        }

        try? await primaryConnection.done()
        try await primaryConnection.disconnect()

        namespaces = nil
        mailboxes = []
        specialMailboxes = []
    }
    
    // MARK: - Mailbox Commands

    /**
     Create a new mailbox on the server

     This method creates a new mailbox (folder) with the specified name.
     Use forward slashes to create hierarchical mailboxes (e.g., "Work/Projects").

     - Parameter mailboxName: The name of the mailbox to create
     - Throws:
     - `IMAPError.commandFailed` if the mailbox cannot be created
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs mailbox creation at debug level
     */
    public func createMailbox(_ mailboxName: String) async throws {
        let command = CreateMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        try await executeCommand(command)
    }

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
    @discardableResult public func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Selection {
        let command = SelectMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
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
    /// - Important: If you have multiple connections looking at the same mailbox, refresh
    ///   their state (for example by issuing `noop()`) when an IDLE event indicates changes
    ///   like new messages or expunges. This keeps counts and sequence numbers in sync.
    ///
    /// - Returns: An AsyncStream of server events during the IDLE session
    /// - Throws: IMAPError if IDLE is not supported or already active
    public func idle() async throws -> AsyncStream<IMAPServerEvent> {
        try await primaryConnection.idle()
    }

    /// Begin a resilient IDLE session for a specific mailbox on a dedicated connection.
    /// The returned session must be ended by calling `done()` on the session,
    /// or by calling `disconnect()` on the server.
    ///
    /// This stream is self-healing:
    /// - IDLE is renewed every `configuration.renewalInterval` (default 285 seconds)
    /// - optional DONE → NOOP → re-IDLE probes run every `configuration.noopInterval`
    ///   when `configuration.postIdleNoopEnabled` is true
    /// - dropped connections are automatically reconnected and re-selected
    ///
    /// - Important: If other connections have the same mailbox selected, refresh them
    ///   (for example by issuing `noop()`) when this session reports changes, to keep
    ///   counts and sequence numbers accurate across connections.
    /// - Parameter mailbox: The mailbox to watch for changes.
    /// - Parameter configuration: Reliability tuning for IDLE renewal/heartbeat/reconnect.
    public func idle(on mailbox: String, configuration: IMAPIdleConfiguration = .default) async throws -> IMAPIdleSession {
        let idleConfiguration = try configuration.validated()

        guard let authentication = authentication else {
            throw IMAPError.commandFailed("Authentication required before starting IDLE on a mailbox")
        }

        let sessionID = UUID()
        let resolvedMailbox = resolveMailboxPath(mailbox)
        let connection = makeIdleConnection(sessionID: sessionID, mailbox: resolvedMailbox)
        idleConnections[sessionID] = IdleConnection(mailbox: resolvedMailbox, connection: connection)

        do {
            try await connection.connect()
            try await authentication.authenticate(on: connection)
            _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

            var continuationRef: AsyncStream<IMAPServerEvent>.Continuation!
            let wrappedEvents = AsyncStream<IMAPServerEvent> { continuation in
                continuationRef = continuation
            }

            let continuation = continuationRef!
            let serverHost = self.host
            let serverPort = self.port

            let cycleTask = Task.detached {
                enum CycleTrigger: String {
                    case noop
                    case renewal
                }

                enum CycleResult {
                    case timer(CycleTrigger)
                    case streamEnded(sawBye: Bool, byeMessage: String?)
                }

                let cycleLoggerLabel = "com.cocoanetics.SwiftMail.IdleCycle.\(connection.identifier)"
                var cycleLogger = Logger(label: cycleLoggerLabel)
                cycleLogger[metadataKey: "imap.host"] = .string(serverHost)
                cycleLogger[metadataKey: "imap.port"] = .stringConvertible(serverPort)
                cycleLogger[metadataKey: "imap.mailbox"] = .string(resolvedMailbox)
                cycleLogger[metadataKey: "imap.connection_id"] = .string(connection.identifier)
                cycleLogger[metadataKey: "imap.connection_role"] = .string(connection.role)

                let reconnectDelay: (Int) -> TimeInterval = { attempt in
                    let exponent = min(max(attempt - 1, 0), 10)
                    let multiplier = Double(1 << exponent)
                    let baseDelay = min(idleConfiguration.reconnectBaseDelay * multiplier, idleConfiguration.reconnectMaxDelay)
                    let jitterFactor = idleConfiguration.reconnectJitterFactor
                    guard jitterFactor > 0 else { return baseDelay }
                    let jittered = baseDelay * (1 + Double.random(in: -jitterFactor...jitterFactor))
                    return max(0, jittered)
                }

                var cycleCount = 0
                var reconnectAttempt = 0
                var nextNoopAt: Date? = idleConfiguration.postIdleNoopEnabled
                    ? Date().addingTimeInterval(idleConfiguration.noopInterval)
                    : nil
                var nextRenewalAt = Date().addingTimeInterval(idleConfiguration.renewalInterval)

                cycleLogger.info(
                    "Idle reliability task started for mailbox '\(mailbox)' (postIdleNoop=\(idleConfiguration.postIdleNoopEnabled) noopInterval=\(idleConfiguration.noopInterval)s renewal=\(idleConfiguration.renewalInterval)s)"
                )

                while !Task.isCancelled {
                    do {
                        cycleCount += 1
                        cycleLogger.debug("Cycle \(cycleCount): starting IDLE")

                        let idleStream = try await connection.idle()

                        let now = Date()
                        let secondsToNoop = nextNoopAt.map { max($0.timeIntervalSince(now), 0) } ?? .infinity
                        let secondsToRenewal = max(nextRenewalAt.timeIntervalSince(now), 0)
                        let trigger: CycleTrigger = secondsToRenewal <= secondsToNoop ? .renewal : .noop
                        let waitSeconds = trigger == .renewal ? secondsToRenewal : secondsToNoop

                        let cycleResult = await withTaskGroup(of: CycleResult.self) { group -> CycleResult in
                            group.addTask {
                                var sawBye = false
                                var byeMessage: String?
                                for await event in idleStream {
                                    continuation.yield(event)
                                    if case .bye(let message) = event {
                                        sawBye = true
                                        byeMessage = message
                                        break
                                    }
                                }
                                return .streamEnded(sawBye: sawBye, byeMessage: byeMessage)
                            }

                            group.addTask {
                                if waitSeconds > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                                }
                                return .timer(trigger)
                            }

                            let first = await group.next() ?? .streamEnded(sawBye: false, byeMessage: nil)
                            group.cancelAll()
                            return first
                        }

                        if Task.isCancelled { break }

                        switch cycleResult {
                        case .streamEnded(let sawBye, let byeMessage):
                            if sawBye {
                                let message = byeMessage ?? "<no message>"
                                cycleLogger.info("Cycle \(cycleCount): Server closed connection: \(message)")

                                do {
                                    try? await connection.disconnect()

                                    try await connection.connect()
                                    try await authentication.authenticate(on: connection)
                                    _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

                                    let reconnectedAt = Date()
                                    nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                        ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                        : nil
                                    nextRenewalAt = reconnectedAt.addingTimeInterval(idleConfiguration.renewalInterval)
                                    reconnectAttempt = 0

                                    cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                                    continue
                                } catch {
                                    reconnectAttempt += 1
                                    let delay = reconnectDelay(reconnectAttempt)
                                    cycleLogger.info(
                                        "Cycle \(cycleCount): routine reconnect failed after server close '\(String(describing: error))'; retry \(reconnectAttempt) in \(delay)s"
                                    )

                                    if delay > 0 {
                                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                    }
                                    continue
                                }
                            } else {
                                cycleLogger.warning("Cycle \(cycleCount): IDLE stream ended unexpectedly; reconnecting")
                            }
                            throw IMAPConnectionError.disconnected

                        case .timer(let checkpoint):
                            cycleLogger.debug("Cycle \(cycleCount): checkpoint=\(checkpoint.rawValue), sending DONE")
                            try await connection.done(timeoutSeconds: idleConfiguration.doneTimeout)

                            var noopEvents: [IMAPServerEvent] = []
                            if idleConfiguration.postIdleNoopEnabled {
                                if idleConfiguration.postIdleNoopDelay > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(idleConfiguration.postIdleNoopDelay * 1_000_000_000))
                                }
                                cycleLogger.debug("Cycle \(cycleCount): sending NOOP")
                                noopEvents = try await connection.noop()
                                if !noopEvents.isEmpty {
                                    cycleLogger.debug("Cycle \(cycleCount): NOOP returned \(noopEvents.count) event(s)")
                                }
                            } else {
                                cycleLogger.debug("Cycle \(cycleCount): post-IDLE NOOP probe disabled")
                            }
                            for event in noopEvents {
                                continuation.yield(event)
                            }

                            let bufferedEvents = connection.drainBufferedEvents()
                            if !bufferedEvents.isEmpty {
                                cycleLogger.debug("Cycle \(cycleCount): drained \(bufferedEvents.count) buffered event(s)")
                            }
                            for event in bufferedEvents {
                                continuation.yield(event)
                            }

                            let sawByeEvent = (noopEvents + bufferedEvents).contains { event in
                                if case .bye = event { return true }
                                return false
                            }
                            if sawByeEvent {
                                let byeMessage = (noopEvents + bufferedEvents).compactMap { event -> String? in
                                    guard case .bye(let message) = event else { return nil }
                                    return message ?? "<no message>"
                                }.first ?? "<no message>"
                                cycleLogger.info("Cycle \(cycleCount): Server closed connection: \(byeMessage)")

                                do {
                                    try? await connection.disconnect()

                                    try await connection.connect()
                                    try await authentication.authenticate(on: connection)
                                    _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

                                    let reconnectedAt = Date()
                                    nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                        ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                        : nil
                                    nextRenewalAt = reconnectedAt.addingTimeInterval(idleConfiguration.renewalInterval)
                                    reconnectAttempt = 0

                                    cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                                    continue
                                } catch {
                                    reconnectAttempt += 1
                                    let delay = reconnectDelay(reconnectAttempt)
                                    cycleLogger.info(
                                        "Cycle \(cycleCount): routine reconnect failed after server close '\(String(describing: error))'; retry \(reconnectAttempt) in \(delay)s"
                                    )

                                    if delay > 0 {
                                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                                    }
                                    continue
                                }
                            }

                            let resumedAt = Date()
                            nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                ? resumedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                : nil
                            if checkpoint == .renewal || resumedAt >= nextRenewalAt {
                                nextRenewalAt = resumedAt.addingTimeInterval(idleConfiguration.renewalInterval)
                                cycleLogger.debug("Cycle \(cycleCount): renewed IDLE window")
                            }

                            reconnectAttempt = 0
                        }
                    } catch {
                        if Task.isCancelled { break }

                        reconnectAttempt += 1
                        let delay = reconnectDelay(reconnectAttempt)
                        cycleLogger.warning(
                            "Cycle \(cycleCount): encountered error '\(String(describing: error))'; reconnect attempt \(reconnectAttempt) in \(delay)s"
                        )

                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }

                        if Task.isCancelled { break }

                        do {
                            try? await connection.done(timeoutSeconds: idleConfiguration.doneTimeout)
                            try? await connection.disconnect()

                            try await connection.connect()
                            try await authentication.authenticate(on: connection)
                            _ = try await connection.executeCommand(SelectMailboxCommand(mailboxName: resolvedMailbox))

                            let reconnectedAt = Date()
                            nextNoopAt = idleConfiguration.postIdleNoopEnabled
                                ? reconnectedAt.addingTimeInterval(idleConfiguration.noopInterval)
                                : nil
                            nextRenewalAt = reconnectedAt.addingTimeInterval(idleConfiguration.renewalInterval)

                            cycleLogger.info("Reconnected IDLE session for mailbox '\(mailbox)'")
                        } catch {
                            cycleLogger.error(
                                "Reconnect attempt \(reconnectAttempt) failed for mailbox '\(mailbox)': \(String(describing: error))"
                            )
                        }
                    }
                }

                continuation.finish()
            }

            let session = IMAPIdleSession(events: wrappedEvents) { [weak self] in
                cycleTask.cancel()
                guard let self else { return }
                try await self.endIdleSession(id: sessionID)
            }

            return session
        } catch {
            idleConnections[sessionID] = nil
            try? await connection.disconnect()
            throw error
        }
    }

    /// Compatibility wrapper for the previous IDLE API.
    ///
    /// The provided interval maps to heartbeat NOOP checkpoints.
    /// Renewal remains at the default strategy interval unless overridden via
    /// `idle(on:configuration:)`.
    @available(*, deprecated, message: "Use idle(on:configuration:) for full reliability configuration.")
    public func idle(on mailbox: String, cycleInterval: TimeInterval) async throws -> IMAPIdleSession {
        var configuration = IMAPIdleConfiguration.default
        configuration.noopInterval = cycleInterval
        configuration.postIdleNoopEnabled = true
        return try await idle(on: mailbox, configuration: configuration)
    }
    
    /// Terminate the current IDLE session
    ///
    /// **Note**: Call this method in cancellation handlers to properly clean up IDLE sessions.
    ///   The actor ensures this is safe to call even during rapid cancellation/restart cycles.
    ///
    /// This method is safe to call even if the server has already terminated the IDLE session
    /// (e.g., by sending a BYE response) or if automatic cleanup has already occurred.
    public func done() async throws {
        try await primaryConnection.done()
    }
    
    /// Send a NOOP command and collect unsolicited responses.
    public func noop() async throws -> [IMAPServerEvent] {
        try await primaryConnection.noop()
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
        try await closeAllConnections()
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
     Fetches the complete raw RFC822 message (headers + body) without setting the \Seen flag.

     - Parameter identifier: The identifier of the message
     - Returns: The complete raw message data
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     */
    public func fetchRawMessage<T: MessageIdentifier>(identifier: T) async throws -> Data {
        let command = FetchRawMessageCommand(identifier: identifier)
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

    /// Fetch message infos for an identifier set in a **single IMAP FETCH**.
    /// This is important for UID ranges like `123:*` which must not be expanded into individual UIDs.
    public func fetchMessageInfosBulk<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>) async throws -> [MessageInfo] {
        let command = FetchMessageInfoCommand(identifierSet: identifierSet)
        return try await executeCommand(command)
    }

    // MARK: - Convenience overloads for ranges

    /// Fetch message infos for a UID range in a **single UID FETCH** (e.g. `11971:*`).
    public func fetchMessageInfos(uidRange: PartialRangeFrom<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message infos for a UID range in a **single UID FETCH**.
    public func fetchMessageInfos(uidRange: ClosedRange<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(sequenceRange: PartialRangeFrom<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(sequenceRange: ClosedRange<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
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
    /// It retrieves each message's headers and body sequentially, ensuring IMAP commands
    /// are executed in strict order. The sequence supports cancellation, allowing the
    /// caller to stop fetching early without waiting for all messages to be downloaded.
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

                    for identifier in identifierSet.toArray() {
                        try Task.checkCancellation()
                        if let header = try await fetchMessageInfo(for: identifier) {
                            let email = try await fetchMessage(from: header)
                            continuation.yield(email)
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
    public func search<T: MessageIdentifier>(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria], calendar: Calendar = Calendar(identifier: .gregorian)) async throws -> MessageIdentifierSet<T> {
        let command = SearchCommand(identifierSet: identifierSet, criteria: criteria, calendar: calendar)
        return try await executeCommand(command)
    }

    /**
     Search the selected mailbox and return structured ESEARCH results (RFC 4731).

     Uses the ESEARCH extension when the server advertises it, and falls back
     to a plain SEARCH response otherwise.  The returned ``ExtendedSearchResult``
     always contains at minimum the `count` and `all` fields when matches exist.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
       - identifierSet: Optional set of message identifiers to search within. If nil, searches all messages.
       - criteria: The search criteria to apply. Multiple criteria are combined with AND logic.
       - calendar: The calendar used for date-to-day conversions.
       - partialRange: Optional window for paged results (PARTIAL, RFC 5267). When provided and ESEARCH
         is available, `PARTIAL` is requested instead of `ALL`, and results appear in
         ``ExtendedSearchResult/partial`` rather than ``ExtendedSearchResult/all``. Ignored when the
         server does not advertise ESEARCH.
     - Returns: An ``ExtendedSearchResult`` containing COUNT, MIN, MAX and either ALL or PARTIAL when available.
     - Throws:
       - `IMAPError.commandFailed` if the search operation fails
       - `IMAPError.connectionFailed` if not connected
     */
    public func extendedSearch<T: MessageIdentifier>(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria], calendar: Calendar = Calendar(identifier: .gregorian), partialRange: PartialRange? = nil) async throws -> ExtendedSearchResult<T> {
        let useEsearch = capabilities.contains(.extendedSearch)
        let command = ExtendedSearchCommand<T>(identifierSet: identifierSet, criteria: criteria, calendar: calendar, useEsearch: useEsearch, partialRange: partialRange)
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
    public func mailboxStatus(_ mailboxName: String) async throws -> Mailbox.Status {
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
        
        let command = StatusCommand(mailboxName: resolveMailboxPath(mailboxName), attributes: attributes)
        let status: NIOIMAPCore.MailboxStatus = try await executeCommand(command)
        return Mailbox.Status(nio: status)
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
        let command = CopyCommand(identifierSet: identifierSet, destinationMailbox: resolveMailboxPath(destinationMailbox))
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
    public func store<T: MessageIdentifier>(flags: [Flag], on identifierSet: MessageIdentifierSet<T>, operation: StoreData.StoreType) async throws {
        let storeData = StoreData.flags(flags, operation)
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
        
        let command = GetQuotaRootCommand(mailboxName: mailboxName.map(resolveMailboxPath))
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
    
    /**
     Execute an IMAP command
     - Parameter command: The command to execute
     - Returns: The result of executing the command
     - Throws: An error if the command execution fails
     */
    private func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        if let authentication, !primaryConnection.isAuthenticated {
            logger.info("Primary connection not authenticated; re-authenticating before command")
            try await authentication.authenticate(on: primaryConnection)
            namespaces = primaryConnection.namespacesSnapshot
        }

        return try await primaryConnection.executeCommand(command)
    }

    private func append(rawMessage: String, to mailbox: String, flags: [Flag], internalDate: Date?) async throws -> AppendResult {
        if let limit = capabilities.globalAppendLimit {
            let payloadSize = rawMessage.utf8.count
            if payloadSize > limit {
                throw IMAPError.appendLimitExceeded(payloadSize, limit)
            }
        }
        let serverDate = internalDate.flatMap(makeInternalDate(from:))
        let command = AppendCommand(
            mailboxName: resolveMailboxPath(mailbox),
            message: rawMessage,
            flags: flags,
            internalDate: serverDate
        )
        return try await executeCommand(command)
    }

    private func makeInternalDate(from date: Date) -> ServerMessageDate? {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone.current
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute
        else {
            return nil
        }

        let second = components.second ?? 0
        let zoneMinutes = timeZone.secondsFromGMT(for: date) / 60

        guard let serverComponents = ServerMessageDate.Components(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            timeZoneMinutes: zoneMinutes
        ) else {
            return nil
        }

        return ServerMessageDate(serverComponents)
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
        let command = MoveCommand(identifierSet: identifierSet, destinationMailbox: resolveMailboxPath(destinationMailbox))
        try await executeCommand(command)
    }
}

// MARK: - Common Mail Operations
extension IMAPServer {
    /// Retrieve namespace information from the server.
    /// - Returns: The namespace response describing personal, other user and shared namespaces.
    /// - Throws: `IMAPError.commandFailed` if the command fails.
    public func fetchNamespaces() async throws -> NamespaceResponse {
        // Route through executeCommand so auto-reauthentication fires if the
        // primary session has dropped, matching the recovery behaviour of all
        // other IMAPServer command methods.
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
    @discardableResult
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
                let nameLower = normalizedMailboxName(mailbox.name).lowercased()
                
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
                if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/Trash") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("Trash") == .orderedSame {
                    attributes.insert(.trash)
                    hasSpecialUse = true
                } else if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/Sent Mail") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("Sent Mail") == .orderedSame {
                    attributes.insert(.sent)
                    hasSpecialUse = true
                } else if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/Drafts") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("Drafts") == .orderedSame {
                    attributes.insert(.drafts)
                    hasSpecialUse = true
                } else if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/Spam") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("Spam") == .orderedSame {
                    attributes.insert(.junk)
                    hasSpecialUse = true
                } else if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/All Mail") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("All Mail") == .orderedSame {
                    attributes.insert(.archive)
                    hasSpecialUse = true
                } else if normalizedMailboxName(mailbox.name).caseInsensitiveCompare("[Gmail]/Starred") == .orderedSame || normalizedMailboxName(mailbox.name).caseInsensitiveCompare("Starred") == .orderedSame {
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
        if let namespaces {
            let patterns = namespaces.listingPatterns(for: wildcard)
            var allMailboxes: [Mailbox.Info] = []
            var seenNames: Set<String> = []

            for pattern in patterns {
                let command = ListCommand(wildcard: pattern)
                let listed = try await executeCommand(command)
                for mailbox in listed where seenNames.insert(mailbox.name).inserted {
                    allMailboxes.append(mailbox)
                }
            }

            if !allMailboxes.isEmpty {
                self.mailboxes = allMailboxes
                return allMailboxes
            }
        }

        let command = ListCommand(wildcard: wildcard)
        let listed = try await executeCommand(command)
        self.mailboxes = listed
        return listed
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
     
     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Trash").
     
     - Returns: The trash folder information
     - Throws: `UndefinedFolderError.trash` if the trash folder is not found
     */
    public var trashFolder: Mailbox.Info {
        get throws {
            if let trash = specialMailboxes.trash ?? mailboxes.trash {
                return trash
            }
            throw UndefinedFolderError.trash
        }
    }
    
    /**
     Get the archive folder or throw if not found
     
     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Archive").
     
     - Returns: The archive folder information
     - Throws: `UndefinedFolderError.archive` if the archive folder is not found
     */
    public var archiveFolder: Mailbox.Info {
        get throws {
            if let archive = specialMailboxes.archive ?? mailboxes.archive {
                return archive
            }
            throw UndefinedFolderError.archive
        }
    }
    
    /**
     Get the sent folder or throw if not found
     
     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Sent").
     
     - Returns: The sent folder information
     - Throws: `UndefinedFolderError.sent` if the sent folder is not found
     */
    public var sentFolder: Mailbox.Info {
        get throws {
            if let sent = specialMailboxes.sent ?? mailboxes.sent {
                return sent
            }
            throw UndefinedFolderError.sent
        }
    }
    
    /**
     Get the drafts folder or throw if not found
     
     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Drafts").
     
     - Returns: The drafts folder information
     - Throws: `UndefinedFolderError.drafts` if the drafts folder is not found
     */
    public var draftsFolder: Mailbox.Info {
        get throws {
            if let drafts = specialMailboxes.drafts ?? mailboxes.drafts {
                return drafts
            }
            throw UndefinedFolderError.drafts
        }
    }
    
    /**
     Get the junk folder or throw if not found
     
     Checks special-use mailboxes first, then falls back to the general mailbox list
     (which includes name-based matching for common folder names like "Junk" or "Spam").
     
     - Returns: The junk folder information
     - Throws: `UndefinedFolderError.junk` if the junk folder is not found
     */
    public var junkFolder: Mailbox.Info {
        get throws {
            if let junk = specialMailboxes.junk ?? mailboxes.junk {
                return junk
            }
            throw UndefinedFolderError.junk
        }
    }
}

// Update the existing folder operations to use the throwing getters
extension IMAPServer {
    
    /// Ensures special-use mailboxes and the general mailbox list have been fetched.
    /// Called automatically by convenience folder operations so callers don't need
    /// to manually call `listSpecialUseMailboxes()` first.
    private func ensureMailboxesLoaded() async throws {
        if mailboxes.isEmpty {
            // listSpecialUseMailboxes also populates self.mailboxes internally
            try await listSpecialUseMailboxes()
        } else if specialMailboxes.isEmpty {
            try await listSpecialUseMailboxes()
        }
    }
    
    /**
     Move messages to the trash folder
     
     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Trash" if the server doesn't advertise SPECIAL-USE.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to move
     - Throws: An error if the move operation fails or trash folder is not found
     */
    public func moveToTrash<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await ensureMailboxesLoaded()
        try await move(messages: identifierSet, to: try trashFolder.name)
    }
    
    /**
     Archive messages by marking them as seen and moving them to the archive folder
     
     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Archive" if the server doesn't advertise SPECIAL-USE.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to archive
     - Throws: An error if the archive operation fails or archive folder is not found
     */
    public func archive<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await ensureMailboxesLoaded()
        try await store(flags: [.seen], on: identifierSet, operation: .add)
        try await move(messages: identifierSet, to: try archiveFolder.name)
    }
    
    /**
     Mark messages as junk by moving them to the junk folder
     
     Automatically fetches special-use mailboxes if they haven't been loaded yet.
     Falls back to a mailbox named "Junk" or "Spam" if the server doesn't advertise SPECIAL-USE.
     
     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable
     
     - Parameter identifierSet: The set of messages to mark as junk
     - Throws: An error if the operation fails or junk folder is not found
     */
    public func markAsJunk<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        try await ensureMailboxesLoaded()
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

    /**
     Append a fully composed email to a mailbox.
     
     This helper builds the MIME body using ``Email/constructContent(use8BitMIME:)``
     and streams it to the server using the IMAP `APPEND` command.
     
     - Parameters:
        - email: The email to append.
        - mailbox: The destination mailbox path (e.g. "Drafts").
        - flags: Optional message flags to set during append.
        - internalDate: Optional internal date to store on the server. Defaults to the server-provided date.
     - Returns: ``AppendResult`` describing server-assigned identifiers.
     */
    @discardableResult
    public func append(email: Email, to mailbox: String, flags: [Flag] = [], internalDate: Date? = nil) async throws -> AppendResult {
        guard !mailbox.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name must not be empty")
        }

        var content = canonicalizeCRLF(email.constructContent(use8BitMIME: true))
        if !content.hasSuffix("\r\n") {
            content.append("\r\n")
        }

        return try await append(rawMessage: content, to: mailbox, flags: flags, internalDate: internalDate)
    }

    /**
     Create a brand-new draft message by appending the provided email to the drafts mailbox.
     
     The method automatically sets the `\\Draft` flag and relies on the server's drafts mailbox if no custom mailbox is supplied.
     
     - Parameters:
        - email: The email content to store as a draft.
        - mailbox: Optional custom mailbox path. Defaults to the detected drafts mailbox.
        - date: Optional internal date to stamp on the message.
        - additionalFlags: Extra flags to include alongside `\\Draft`.
     - Returns: ``AppendResult`` describing server-assigned identifiers.
     */
    @discardableResult
    public func createDraft(from email: Email, in mailbox: String? = nil, date: Date? = nil, additionalFlags: [Flag] = []) async throws -> AppendResult {
        var flags: [Flag] = [.draft]
        flags.append(contentsOf: additionalFlags)

        let targetMailbox: String
        if let mailbox {
            targetMailbox = mailbox
        } else {
            targetMailbox = try draftsFolder.name
        }

        // Mark as a draft so mail clients (e.g. Apple Mail) recognize ownership
        // and remove the message from Drafts after sending.
        var draft = email
        var headers = draft.additionalHeaders ?? [:]
        if headers["X-Uniform-Type-Identifier"] == nil {
            headers["X-Uniform-Type-Identifier"] = "com.apple.mail-draft"
        }
        draft.additionalHeaders = headers

        return try await append(email: draft, to: targetMailbox, flags: flags, internalDate: date)
    }
}

private extension IMAPServer {
    func resolveMailboxPath(_ mailbox: String) -> String {
        guard let namespaces else {
            return mailbox
        }
        return namespaces.resolveMailboxPath(mailbox)
    }

    func normalizedMailboxName(_ mailbox: String) -> String {
        guard let namespaces else {
            return mailbox
        }
        return namespaces.relativeMailboxName(from: mailbox)
    }

    func canonicalizeCRLF(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.replacingOccurrences(of: "\n", with: "\r\n")
    }
}
