import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Namespace and Listing

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
                updateMailboxes(allMailboxes)
                return allMailboxes
            }
        }

        let command = ListCommand(wildcard: wildcard)
        let listed = try await executeCommand(command)
        updateMailboxes(listed)
        return listed
    }
}
