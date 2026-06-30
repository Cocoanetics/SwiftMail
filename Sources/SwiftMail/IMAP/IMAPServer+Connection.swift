import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

// MARK: - Connection and Login

extension IMAPServer {
    /**
     Connect to the IMAP server using SSL/TLS

     This method establishes the IMAP transport connection and retrieves
     its capabilities. Port `993` defaults to implicit TLS, port `143` defaults to
     plain text with opportunistic STARTTLS.

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
    func supportsCapability(_ check: (Capability) -> Bool) -> Bool {
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

    /// Authenticate using AUTHENTICATE PLAIN (RFC 4616) with optional SASL-IR (RFC 4959).
    ///
    /// When the server advertises `SASL-IR`, credentials are sent inline with the
    /// AUTHENTICATE command (saving a round trip). Otherwise falls back to the standard
    /// continuation-based exchange.
    ///
    /// - Parameters:
    ///   - username: The username (authcid) for authentication.
    ///   - password: The password for authentication.
    /// - Throws: ``IMAPError.unsupportedAuthMechanism`` if the server does not advertise AUTH=PLAIN,
    ///   or ``IMAPError.authFailed`` when authentication fails.
    public func authenticatePlain(username: String, password: String) async throws {
        try await primaryConnection.authenticatePlain(username: username, password: password)
        authentication = .plain(username: username, password: password)
        namespaces = primaryConnection.namespacesSnapshot
    }

    /// Performs XOAUTH2 authentication for the current IMAP connection.
    /// - Parameters:
    ///   - email: The full mailbox address to authenticate as.
    ///   - accessToken: The OAuth 2.0 access token.
    /// - Throws: ``IMAPError.unsupportedAuthMechanism`` if the server does not advertise XOAUTH2 or
    ///   ``IMAPError.authFailed`` when authentication fails.
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
    /// - Throws: ``IMAPError.commandNotSupported`` if the server does not support the command or
    ///   ``IMAPError.commandFailed`` on failure.
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
    public func disconnect() async throws {
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

        if pendingNamedConnectionWaiters[normalizedName] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                pendingNamedConnectionWaiters[normalizedName]?.append(continuation)
            }
        }

        guard let authentication else {
            throw IMAPError.commandFailed("Authentication required before creating a named connection")
        }

        // Concurrent callers share the leader's result. Success returns the same
        // handle; failure clears this sentinel so a later call can retry normally.
        pendingNamedConnectionWaiters[normalizedName] = []
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
            completePendingNamedConnection(named: normalizedName, with: .success(handle))
            return handle
        } catch {
            try? await connection.disconnect()
            completePendingNamedConnection(named: normalizedName, with: .failure(error))
            throw error
        }
    }

    private func completePendingNamedConnection(
        named name: String,
        with result: Result<IMAPNamedConnection, any Error>
    ) {
        let waiters = pendingNamedConnectionWaiters.removeValue(forKey: name) ?? []

        for waiter in waiters {
            switch result {
                case .success(let handle):
                    waiter.resume(returning: handle)
                case .failure(let error):
                    waiter.resume(throwing: error)
            }
        }
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

    // MARK: - Connection Management Helpers

    func makeIdleConnection(sessionID: UUID, mailbox: String, group: EventLoopGroup) -> IMAPConnection {
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
            transportSecurity: transportSecurity,
            certificateVerificationPolicy: certificateVerificationPolicy,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: shortID,
            connectionRole: "idle:\(sanitizedMailbox)",
            responseBufferLimit: responseBufferLimit
        )
    }

    func makeNamedConnection(name: String) -> IMAPConnection {
        let sanitizedName = sanitizedConnectionName(name)
        let suffix = "named-\(sanitizedName)"
        let shortID = String(sanitizedName.prefix(24))

        let loggerLabel = "com.cocoanetics.SwiftMail.IMAPServer.\(suffix)"
        let outboundLabel = "com.cocoanetics.SwiftMail.IMAP_OUT.\(suffix)"
        let inboundLabel = "com.cocoanetics.SwiftMail.IMAP_IN.\(suffix)"

        return IMAPConnection(
            host: host,
            port: port,
            transportSecurity: transportSecurity,
            certificateVerificationPolicy: certificateVerificationPolicy,
            group: group,
            loggerLabel: loggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: "named-\(shortID)",
            connectionRole: "named:\(sanitizedName)",
            responseBufferLimit: responseBufferLimit
        )
    }

    func sanitizedConnectionName(_ name: String) -> String {
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

    func endIdleSession(id: UUID) async throws {
        guard let entry = idleConnections.removeValue(forKey: id) else { return }

        try? await entry.connection.done()
        try? await entry.connection.disconnect()
    }

    func closeAllConnections() async throws {
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

        clearMailboxState()
    }
}
