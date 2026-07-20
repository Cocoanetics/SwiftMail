import Foundation
import NIOIMAPCore

extension IMAPServer {
    /// Fetches Gmail-native attributes for the given UIDs.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a
    /// tagged BAD. Gate calls on `Capability.gmailExtensions` being advertised.
    public func fetchGmailAttributes(
        for identifierSet: UIDSet
    ) async throws -> [UID: (messageID: UInt64, threadID: UInt64, labels: [String])] {
        let command = FetchGmailAttributesCommand(identifierSet: identifierSet)
        let records = try await executeCommand(command)

        var result: [UID: (messageID: UInt64, threadID: UInt64, labels: [String])] = [:]
        for record in records {
            guard let uid = record.uid,
                  let messageID = record.messageID,
                  let threadID = record.threadID
            else { continue }
            result[uid] = (messageID: messageID, threadID: threadID, labels: record.labels)
        }
        return result
    }
}
