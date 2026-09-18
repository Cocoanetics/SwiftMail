import NIOIMAPCore

/// One streamed FETCH record. Both UID and FLAGS are required before it is committed.
private struct ResyncFetchRecord: Sendable {
    var uid: SwiftMail.UID?
    var flags: [SwiftMail.Flag]?
}

final class ResyncSelectHandler: BaseIMAPCommandHandler<Mailbox.ResyncSelection>,
    IMAPCommandHandler, @unchecked Sendable {

    private var accumulator = MailboxSelectionAccumulator()
    private var vanishedEarlier = NIOIMAPCore.UIDSet()
    private var vanished = NIOIMAPCore.UIDSet()
    private var changedFlags: [SwiftMail.UID: [SwiftMail.Flag]] = [:]
    private var pendingFetch: ResyncFetchRecord?

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        if case .ok(let responseText) = response.state, let code = responseText.code {
            lock.withLock { accumulator.apply(code) }
        }
        super.handleTaggedOKResponse(response)

        let result = lock.withLock {
            Mailbox.ResyncSelection(
                selection: accumulator.selection,
                vanishedEarlier: SwiftMail.UIDSet(nio: vanishedEarlier),
                changedFlags: changedFlags,
                vanished: SwiftMail.UIDSet(nio: vanished)
            )
        }
        succeedWithResult(result)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.selectFailed(String(describing: response.state)))
    }

    override func processResponse(_ response: Response) -> Bool {
        if case .fetch(let fetchResponse) = response {
            processFetchResponse(fetchResponse)
            return false
        }
        return super.processResponse(response)
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .fatal = response {
            return super.handleUntaggedResponse(response)
        }
        guard case .untagged(let payload) = response else {
            return false
        }

        switch payload {
            case .conditionalState(.ok(let responseText)):
                if let code = responseText.code {
                    lock.withLock {
                        accumulator.apply(code)
                        if case .closed = code {
                            resetForClosedBoundary()
                        }
                    }
                }
                return false
            case .mailboxData(let mailboxData):
                lock.withLock { accumulator.apply(mailboxData) }
                return false
            case .messageData(.vanishedEarlier(let uids)):
                lock.withLock {
                    vanishedEarlier.formUnion(uids)
                    removeChangedFlags(in: uids)
                }
                return false
            case .messageData(.vanished(let uids)):
                lock.withLock {
                    let newlyVanished = uids.subtracting(vanished)
                    vanished.formUnion(uids)
                    accumulator.applyLiveDeletions(newlyVanished)
                    removeChangedFlags(in: uids)
                }
                return false
            case .conditionalState(.bye):
                return super.handleUntaggedResponse(response)
            default:
                // Ordinary unsolicited responses continue through the pipeline, but
                // are not retained as part of this command's result state.
                return false
        }
    }

    private func processFetchResponse(_ response: FetchResponse) {
        lock.withLock {
            switch response {
                case .start:
                    pendingFetch = ResyncFetchRecord()
                case .startUID(let uid):
                    pendingFetch = ResyncFetchRecord(uid: SwiftMail.UID(nio: uid))
                case .simpleAttribute(.uid(let uid)):
                    pendingFetch?.uid = SwiftMail.UID(nio: uid)
                case .simpleAttribute(.flags(let flags)):
                    pendingFetch?.flags = flags.map(SwiftMail.Flag.init(nio:))
                case .finish:
                    if let record = pendingFetch,
                       let uid = record.uid,
                       let flags = record.flags,
                       !vanishedEarlier.contains(uid.toNIO()),
                       !vanished.contains(uid.toNIO()) {
                        changedFlags[uid] = flags
                    }
                    pendingFetch = nil
                default:
                    break
            }
        }
    }

    private func removeChangedFlags(in deletedUIDs: NIOIMAPCore.UIDSet) {
        changedFlags = changedFlags.filter { uid, _ in
            !deletedUIDs.contains(uid.toNIO())
        }
    }

    /// A CLOSED response separates data for the old selected mailbox from this SELECT.
    private func resetForClosedBoundary() {
        vanishedEarlier = NIOIMAPCore.UIDSet()
        vanished = NIOIMAPCore.UIDSet()
        changedFlags.removeAll(keepingCapacity: true)
        pendingFetch = nil
    }
}
