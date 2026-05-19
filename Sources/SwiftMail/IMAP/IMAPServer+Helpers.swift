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
        if let authentication, !primaryConnection.isAuthenticated {
            logger.info("Primary connection not authenticated; re-authenticating before command")
            try await authentication.authenticate(on: primaryConnection)
            namespaces = primaryConnection.namespacesSnapshot
        }

        return try await primaryConnection.executeCommand(command)
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
