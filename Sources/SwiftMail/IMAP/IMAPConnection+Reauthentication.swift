import Foundation
import NIO
import NIOIMAPCore

extension IMAPConnection {
    // MARK: - Queue-taking authentication entry points

    func login(username: String, password: String) async throws {
        try await withOperation { [self] in
            try await self.loginBody(username: username, password: password)
        }
    }

    func authenticatePlain(username: String, password: String) async throws {
        try await withOperation { [self] in
            try await self.authenticatePlainBody(username: username, password: password)
        }
    }

    func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        try await withOperation { [self] in
            try await self.authenticateXOAUTH2Body(email: email, accessToken: accessToken)
        }
    }

    // MARK: - Recovery inside the command queue

    /// Re-authenticates on the transport the caller just reopened, when the session it
    /// replaced had been authenticated and the server installed a way to do so.
    ///
    /// Runs inside the command queue: the caller is `executeCommandBody` or
    /// `startIdleSession`, right after `connectBody()`. Without this the first command
    /// after a peer reset went out on the fresh socket before any AUTHENTICATE (Gmail
    /// answers `BAD Unknown command`), and every caller that had checked
    /// `isAuthenticated` a moment earlier was already wrong by the time its command ran.
    /// Recovering here makes the check and the command atomic and single-flight, because
    /// the queue serializes them, and it covers IDLE, which never consulted the server's
    /// re-authentication path.
    func reauthenticateIfSessionWasLost(before operation: String) async throws {
        try validateOperation()
        guard lostAuthenticatedSession, !authenticationInProgress else { return }
        guard let reauthenticate = reauthenticateAfterReconnect else {
            let warning = "\(connectionContext) Lost an authenticated session with no re-authentication "
                + "configured; \(operation) runs unauthenticated"
            logger.warning("\(warning)")
            return
        }
        logger.info("\(connectionContext) Re-authenticating the reopened transport before \(operation)")
        try await reauthenticate(self)
        try validateOperation()
    }

    /// LOGIN for a caller that already holds the command queue.
    func loginBody(username: String, password: String) async throws {
        try await authenticateUntilTransportIsStable(operation: "LOGIN") { [self] in
            let command = LoginCommand(username: username, password: password)
            let loginCapabilities = try await executeCommandBody(command)
            guard let authenticatedChannel = channel, authenticatedChannel.isActive else {
                throw IMAPError.connectionFailed("LOGIN completed after its transport closed")
            }
            return (authenticatedChannel, loginCapabilities)
        }
    }

    /// ID for a caller that already holds the command queue.
    func idBody(_ identification: Identification) async throws -> Identification {
        try validateOperation()
        guard capabilities.contains(.id) else {
            throw IMAPError.commandNotSupported("ID command not supported by server")
        }
        return try await executeCommandBody(IDCommand(identification: identification))
    }

    /// Every successful authentication lands here: the session is live again and no
    /// longer counts as lost.
    func markSessionAuthenticated() {
        guard let context = try? capturedTransport() else { return }
        try? commit(on: context) {
            context.authenticated = true
            sessionWasLost = false
        }
    }

    /// Authentication is not complete until its post-authentication discovery ran on
    /// the transport that accepted the credentials. A dead authenticated channel can
    /// be replaced by CAPABILITY or NAMESPACE while `authenticationInProgress` blocks
    /// nested re-authentication. In that case the discovery command may succeed on the
    /// replacement even though it is unauthenticated, so repeat the entire flow there.
    func authenticateUntilTransportIsStable(
        operation: String,
        authenticate: () async throws -> (channel: Channel, capabilities: [Capability])
    ) async throws {
        let generation = try beginAuthentication()
        defer {
            lifetime.gate.withLock {
                if authenticatingGeneration == generation { authenticatingGeneration = nil }
            }
        }

        let maximumAttempts = 2
        for attempt in 1...maximumAttempts {
            let result = try await authenticate()
            try await lifecycleCheckpoint("authenticated")

            guard channel === result.channel, result.channel.isActive else {
                if attempt < maximumAttempts {
                    logger.info(
                        "\(connectionContext) \(operation) transport closed after authentication; retrying"
                    )
                    continue
                }
                throw IMAPError.connectionFailed(
                    "\(operation) transport repeatedly closed after authentication"
                )
            }

            let authenticatedContext = try capturedTransport()
            try commit(on: authenticatedContext) {
                authenticatedContext.authenticated = true
                sessionWasLost = false
            }
            try await authenticationFollowUpOverrideForTesting?()
            try validateOperation()
            try await refreshCapabilities(using: result.capabilities, useCommandBody: true)
            try await lifecycleCheckpoint("authCapabilities")
            try await fetchNamespacesIfSupported(useCommandBody: true)
            try await lifecycleCheckpoint("authNamespaces")
            clearInvalidChannel()

            if channel === result.channel, result.channel.isActive, !lostAuthenticatedSession {
                return
            }

            if attempt < maximumAttempts {
                logger.info(
                    "\(connectionContext) \(operation) follow-up replaced the authenticated transport; retrying"
                )
                continue
            }
            throw IMAPError.connectionFailed(
                "\(operation) follow-up repeatedly replaced the authenticated transport"
            )
        }
    }

    private func beginAuthentication() throws -> ConnectionGeneration {
        let generation = operationToken?.generation ?? lifetime.currentGeneration
        return try lifetime.gate.withLock {
            if let token = operationToken { try lifetime.validateLocked(token) }
            try lifetime.validateGenerationLocked(generation)
            authenticatingGeneration = generation
            return generation
        }
    }
}
