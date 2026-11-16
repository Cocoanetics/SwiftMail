import Foundation
import NIO
import NIOIMAPCore

/// What the FETCH responses for one UID have said so far.
private struct ChangedFlagsRecord: Sendable {
    var flags: [SwiftMail.Flag]?
    var modificationSequence: UInt64?
}

/// Collects the answer to a `UID FETCH … (CHANGEDSINCE n)`.
///
/// Responses are keyed by the UID they carry, never by position. A UID outside the requested
/// set, or a FETCH without a UID (an unsolicited sequence-number update), is not part of the
/// answer and is skipped. The command sends only sets the server reads as their numeric
/// members (no `*`, or `1:*`), so this membership is the server's. Several responses for one
/// UID (an unsolicited update and the reply) merge in arrival order, so the last value of each
/// item wins. A requested UID whose responses end without both FLAGS and MODSEQ fails the
/// command: dropping it would hide a change.
final class FetchChangedFlagsHandler: BaseIMAPCommandHandler<[ChangedMessageFlags]>,
    IMAPCommandHandler, @unchecked Sendable {

    private let requested: SwiftMail.UIDSet?
    private var pendingUID: SwiftMail.UID?
    private var pending = ChangedFlagsRecord()
    private var records: [SwiftMail.UID: ChangedFlagsRecord] = [:]

    init(commandTag: String, promise: EventLoopPromise<[ChangedMessageFlags]>, requested: SwiftMail.UIDSet) {
        self.requested = requested
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<[ChangedMessageFlags]>) {
        self.requested = nil
        super.init(commandTag: commandTag, promise: promise)
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        let collected = lock.withLock { records }

        var changes: [ChangedMessageFlags] = []
        changes.reserveCapacity(collected.count)
        for (uid, record) in collected {
            guard let flags = record.flags, let modificationSequence = record.modificationSequence else {
                failWithError(IMAPError.fetchFailed(
                    "CHANGEDSINCE response for UID \(uid.value) lacks FLAGS or MODSEQ"
                ))
                return
            }
            changes.append(ChangedMessageFlags(uid: uid, flags: flags, modificationSequence: modificationSequence))
        }
        changes.sort { $0.uid.value < $1.uid.value }
        succeedWithResult(changes)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        if case .fetch(let fetchResponse) = response { processFetchResponse(fetchResponse) }
        return handled
    }

    private func processFetchResponse(_ response: FetchResponse) {
        lock.withLock {
            switch response {
                case .start:
                    pendingUID = nil
                    pending = ChangedFlagsRecord()
                case .startUID(let uid):
                    pendingUID = SwiftMail.UID(nio: uid)
                    pending = ChangedFlagsRecord()
                case .simpleAttribute(.uid(let uid)):
                    pendingUID = SwiftMail.UID(nio: uid)
                case .simpleAttribute(.flags(let flags)):
                    pending.flags = flags.map(SwiftMail.Flag.init(nio:))
                case .simpleAttribute(.fetchModificationSequence(let value)):
                    pending.modificationSequence = UInt64(value)
                case .finish:
                    commitPending()
                default:
                    break
            }
        }
    }

    /// Merges the finished response into its UID's record. Called with the lock held.
    private func commitPending() {
        defer {
            pendingUID = nil
            pending = ChangedFlagsRecord()
        }
        guard let uid = pendingUID, requested?.contains(uid) ?? true else { return }
        var record = records[uid] ?? ChangedFlagsRecord()
        if let flags = pending.flags { record.flags = flags }
        if let modificationSequence = pending.modificationSequence {
            record.modificationSequence = modificationSequence
        }
        records[uid] = record
    }
}
