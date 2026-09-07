import Foundation
import NIOIMAPCore

extension IMAPNamedConnection {
    /// Whether this connection advertised Gmail's `X-GM-EXT-1` capability.
    public var supportsGmailExtensions: Bool {
        capabilities.containsGmailExtensionsCapability
    }

    /// Fetches Gmail-native attributes for the given UIDs on this named connection.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a
    /// tagged BAD. Gate calls on `supportsGmailExtensions`.
    public func fetchGmailAttributes(
        for identifierSet: UIDSet
    ) async throws -> [UID: GmailMessageAttributes] {
        let command = FetchGmailAttributesCommand(identifierSet: identifierSet)
        let records = try await executeCommand(command)

        var result: [UID: GmailMessageAttributes] = [:]
        for record in records {
            guard let uid = record.uid,
                  let messageID = record.messageID,
                  let threadID = record.threadID
            else { continue }
            result[uid] = GmailMessageAttributes(
                messageID: messageID,
                threadID: threadID,
                labels: record.labels
            )
        }
        return result
    }
}
