import Foundation
import NIOIMAPCore

struct GmailMessageAttributes: Sendable {
    var uid: UID?
    var messageID: UInt64?
    var threadID: UInt64?
    var labels: [String] = []
}

final class FetchGmailAttributesHandler: BaseIMAPCommandHandler<[GmailMessageAttributes]>,
    IMAPCommandHandler, @unchecked Sendable {

    private var attributes: [GmailMessageAttributes] = []

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
                lock.withLock { self.attributes.append(GmailMessageAttributes()) }
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

    private static func apply(_ attribute: MessageAttribute, to record: inout GmailMessageAttributes) {
        switch attribute {
            case .uid(let uid): record.uid = UID(nio: uid)
            case .gmailMessageID(let messageID): record.messageID = messageID
            case .gmailThreadID(let threadID): record.threadID = threadID
            case .gmailLabels(let labels): record.labels = labels.map { $0.makeDisplayString() }
            default: break
        }
    }
}
