import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Command Helpers & Path Resolution

extension IMAPServer {
    /**
     Execute an IMAP command
     - Parameter command: The command to execute
     - Returns: The result of executing the command
     - Throws: An error if the command execution fails
     */
    func executeCommand<CommandType: IMAPCommand>(
        _ command: CommandType
    ) async throws -> CommandType.ResultType {
        try await withAuthenticatedPrimaryOperation { [self] in
            try await primaryConnection.executeCommand(command)
        }
    }

    func withAuthenticatedPrimaryOperation<Value>(
        _ body: @escaping () async throws -> Value
    ) async throws -> Value {
        try await primaryConnection.withOperationScope { [self] in
            try await ensurePrimaryConnectionAuthenticated()
            return try await body()
        }
    }

    /// Refreshes session-scoped state before a capability-dependent command decision.
    ///
    /// One recovery at a time: concurrent primary callers that all found the session
    /// gone share the same authentication instead of each sending LOGIN or
    /// AUTHENTICATE, which failed the later ones on an already-authenticated session
    /// and could invoke an OAuth token provider twice.
    func ensurePrimaryConnectionAuthenticated() async throws {
        if primaryConnection.operationToken == nil {
            return try await primaryConnection.withOperationScope { [self] in
                try await ensurePrimaryConnectionAuthenticated()
            }
        }
        try primaryConnection.validateOperation()
        let token = primaryConnection.operationToken
        if let inFlight = primaryAuthenticationInFlight,
           inFlight.generation == token?.generation, !inFlight.terminal.isSettled {
            try await inFlight.value(parent: token)
            try primaryConnection.validateOperation()
            return
        }
        guard let authentication, !primaryConnection.isAuthenticated else { return }
        // With the reconnect inside commands off, a dead transport is the command's to
        // report, not this refresh's to reopen.
        guard primaryConnection.reconnectsInsideCommands || primaryConnection.isConnected else { return }
        logger.info("Primary connection not authenticated; re-authenticating before command")
        let attempt = SharedAttempt<Void>(lifetime: primaryConnection.lifetime, parent: token)
        primaryAuthenticationInFlight = attempt
        attempt.start(on: primaryConnection, operation: { [primaryConnection] in
            try await authentication.authenticate(
                on: primaryConnection,
                skipIfAuthenticatedAfterAdmission: true
            )
        }, completion: { [self] result in
            completePrimaryAuthentication(attempt, with: result)
        })
        try await attempt.value(parent: token)
        try primaryConnection.validateOperation()
    }

    private func completePrimaryAuthentication(_ attempt: SharedAttempt<Void>, with result: Result<Void, Error>) {
        guard primaryAuthenticationInFlight?.id == attempt.id else { return }
        let discoveredNamespaces = primaryConnection.namespacesSnapshot
        attempt.complete(result) { namespaces = discoveredNamespaces }
        if primaryAuthenticationInFlight?.id == attempt.id { primaryAuthenticationInFlight = nil }
    }

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
}
