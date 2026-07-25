import Foundation
import NIOIMAPCore

struct FetchGmailAttributesCommand: IMAPTaggedCommand {
    typealias ResultType = [GmailAttributeRecord]
    typealias HandlerType = FetchGmailAttributesHandler

    let identifierSet: UIDSet
    let timeoutSeconds = 10

    func validate() throws {
        guard !identifierSet.isEmpty else { throw IMAPError.emptyIdentifierSet }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        // UID is requested explicitly: Gmail need not return messages in the
        // requested order, so responses are keyed by returned UID, not position.
        let attributes: [FetchAttribute] = [.uid, .gmailMessageID, .gmailThreadID, .gmailLabels]
        return TaggedCommand(tag: tag, command: .uidFetch(
            .set(identifierSet.toNIOSet()), attributes, []
        ))
    }
}
