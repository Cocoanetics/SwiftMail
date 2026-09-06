import Foundation
import NIO
import NIOIMAPCore

extension IMAPConnection {
    // MARK: - Queue-taking authentication entry points

    func login(username: String, password: String) async throws {
        try await commandQueue.run { [self] in
            try await self.loginBody(username: username, password: password)
        }
    }

    func authenticatePlain(username: String, password: String) async throws {
        try await commandQueue.run { [self] in
            try await self.authenticatePlainBody(username: username, password: password)
        }
    }

    func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        try await commandQueue.run { [self] in
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
        guard lostAuthenticatedSession, !authenticationInProgress else { return }
        guard let reauthenticate = reauthenticateAfterReconnect else {
            let warning = "\(connectionContext) Lost an authenticated session with no re-authentication "
                + "configured; \(operation) runs unauthenticated"
            logger.warning("\(warning)")
            return
        }
        logger.info("\(connectionContext) Re-authenticating the reopened transport before \(operation)")
        try await reauthenticate(self)
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
        guard capabilities.contains(.id) else {
            throw IMAPError.commandNotSupported("ID command not supported by server")
        }
        return try await executeCommandBody(IDCommand(identification: identification))
    }

    /// Every successful authentication lands here: the session is live again and no
    /// longer counts as lost.
    func markSessionAuthenticated() {
        isSessionAuthenticated = true
        lostAuthenticatedSession = false
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
        authenticationInProgress = true
        defer { authenticationInProgress = false }

        let maximumAttempts = 2
        for attempt in 1...maximumAttempts {
            let result = try await authenticate()

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

            markSessionAuthenticated()
            try await authenticationFollowUpOverrideForTesting?()
            try await refreshCapabilities(using: result.capabilities, useCommandBody: true)
            await fetchNamespacesIfSupported(useCommandBody: true)
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
}
