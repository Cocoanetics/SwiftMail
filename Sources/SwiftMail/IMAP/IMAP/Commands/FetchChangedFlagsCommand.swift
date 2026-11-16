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
    let timeoutSeconds = 10

    func validate() throws {
        guard !identifierSet.isEmpty else { throw IMAPError.emptyIdentifierSet }
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
