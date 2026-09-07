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
        try await ensurePrimaryConnectionAuthenticated()

        return try await primaryConnection.executeCommand(command)
    }

    /// Refreshes session-scoped state before a capability-dependent command decision.
    ///
    /// One recovery at a time: concurrent primary callers that all found the session
    /// gone share the same authentication instead of each sending LOGIN or
    /// AUTHENTICATE, which failed the later ones on an already-authenticated session
    /// and could invoke an OAuth token provider twice.
    func ensurePrimaryConnectionAuthenticated() async throws {
        guard let authentication, !primaryConnection.isAuthenticated else { return }
        if let inFlight = primaryAuthenticationInFlight {
            try await inFlight.value
            return
        }
        logger.info("Primary connection not authenticated; re-authenticating before command")
        let task = Task { [primaryConnection] in
            try await authentication.authenticate(on: primaryConnection)
        }
        primaryAuthenticationInFlight = task
        defer { primaryAuthenticationInFlight = nil }
        try await task.value
        namespaces = primaryConnection.namespacesSnapshot
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

    func canonicalizeCRLF(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.replacingOccurrences(of: "\n", with: "\r\n")
    }
}
