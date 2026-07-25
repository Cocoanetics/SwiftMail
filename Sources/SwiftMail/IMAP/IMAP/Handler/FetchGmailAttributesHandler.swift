import Foundation
import NIOIMAPCore

/// Mutable accumulator used while parsing a Gmail attribute FETCH response.
///
/// Fields start `nil`/empty and are filled in as the corresponding FETCH data items
/// arrive; `IMAPServer.fetchGmailAttributes(for:)` converts fully-populated records
/// into the public, non-optional `GmailMessageAttributes`.
struct GmailAttributeRecord: Sendable {
    var uid: UID?
    var messageID: UInt64?
    var threadID: UInt64?
    var labels: [String] = []
}

final class FetchGmailAttributesHandler: BaseIMAPCommandHandler<[GmailAttributeRecord]>,
    IMAPCommandHandler, @unchecked Sendable {

    private var attributes: [GmailAttributeRecord] = []

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        succeedWithResult(lock.withLock { self.attributes })
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        if case .fetch(let fetchResponse) = response { processFetchResponse(fetchResponse) }
        return handled
    }

    private func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case .start:
                lock.withLock { self.attributes.append(GmailAttributeRecord()) }
            case .simpleAttribute(let attribute):
                lock.withLock {
                    guard let index = self.attributes.indices.last else { return }
                    var record = self.attributes[index]
                    Self.apply(attribute, to: &record)
                    self.attributes[index] = record
                }
            default: break
        }
    }

    private static func apply(_ attribute: MessageAttribute, to record: inout GmailAttributeRecord) {
        switch attribute {
            case .uid(let uid): record.uid = UID(nio: uid)
            case .gmailMessageID(let messageID): record.messageID = messageID
            case .gmailThreadID(let threadID): record.threadID = threadID
            case .gmailLabels(let labels): record.labels = labels.map { $0.makeDisplayString() }
            default: break
        }
    }
}
