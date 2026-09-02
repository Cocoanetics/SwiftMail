import Foundation
import NIOIMAPCore

extension IMAPServer {
    /// Whether the primary connection advertised Gmail's `X-GM-EXT-1` capability.
    public var supportsGmailExtensions: Bool {
        capabilities.contains(.gmailExtensions)
    }

    /// Fetches Gmail-native attributes for the given UIDs.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a
    /// tagged BAD. Gate calls on `Capability.gmailExtensions` being advertised.
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
            result[uid] = GmailMessageAttributes(messageID: messageID, threadID: threadID, labels: record.labels)
        }
        return result
    }
}
