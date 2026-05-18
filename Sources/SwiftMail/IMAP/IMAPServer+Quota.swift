import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Quota Commands

extension IMAPServer {
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
}
