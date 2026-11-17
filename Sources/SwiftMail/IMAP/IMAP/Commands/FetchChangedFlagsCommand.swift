import Foundation
import NIO
import NIOIMAPCore

/// `UID FETCH <set> (UID FLAGS MODSEQ) (CHANGEDSINCE <n>)` (RFC 7162 section 3.1.4.1).
///
/// CHANGEDSINCE already implies MODSEQ in every response; it is also requested explicitly
/// so the request states what the result is built from.
struct FetchChangedFlagsCommand: IMAPTaggedCommand {
    typealias ResultType = [ChangedMessageFlags]
    typealias HandlerType = FetchChangedFlagsHandler

    let identifierSet: UIDSet
    let changedSince: ModificationSequenceValue
    /// Like a QRESYNC select (`ResyncSelectMailboxCommand`), the reply lists every message
    /// changed since the mod-sequence, so it can be as long and gets the same time.
    let timeoutSeconds = 30

    func validate() throws {
        guard !identifierSet.isEmpty else { throw IMAPError.emptyIdentifierSet }
        // `UID.latest` is sent as `*`, the mailbox's highest UID. A range `n:*` whose n is above
        // that UID means that UID alone (RFC 3501 section 6.4.8), which the set does not hold,
        // and its reply looks exactly like an unsolicited update from another session (RFC 7162
        // section 3.1.4.2). Only `1:*` means the same to the server as to the set, every UID, so
        // it is the only set holding `*` whose replies the handler can check.
        if identifierSet.contains(UID.latest),
           let wildcardRange = identifierSet.ranges.last,
           wildcardRange.lowerBound > 1 {
            throw IMAPError.invalidArgument(
                "CHANGEDSINCE needs 1:* or a UID set without UID.latest (*); n:* can mean only the highest UID"
            )
        }
    }

    func makeHandler(
        commandTag: String,
        promise: EventLoopPromise<[ChangedMessageFlags]>
    ) -> FetchChangedFlagsHandler {
        FetchChangedFlagsHandler(commandTag: commandTag, promise: promise, requested: identifierSet)
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let attributes: [FetchAttribute] = [.uid, .flags, .modificationSequence]
        let modifiers: [FetchModifier] = [.changedSince(ChangedSinceModifier(modificationSequence: changedSince))]
        return TaggedCommand(tag: tag, command: .uidFetch(
            .set(identifierSet.toNIOSet()), attributes, modifiers
        ))
    }
}
