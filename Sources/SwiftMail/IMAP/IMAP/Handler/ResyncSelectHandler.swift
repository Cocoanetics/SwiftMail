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
                changedFlags: changedFlags
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
                        if case .closed = code {
                            resetForClosedBoundary()
                        } else {
                            accumulator.apply(code)
                        }
                    }
                }
                return false
            case .mailboxData(let mailboxData):
                lock.withLock { accumulator.apply(mailboxData) }
                return false
            case .messageData(.vanishedEarlier(let uids)):
                lock.withLock { vanishedEarlier.formUnion(uids) }
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
                case .start, .startUID:
                    pendingFetch = ResyncFetchRecord()
                case .simpleAttribute(.uid(let uid)):
                    pendingFetch?.uid = SwiftMail.UID(nio: uid)
                case .simpleAttribute(.flags(let flags)):
                    pendingFetch?.flags = flags.map(SwiftMail.Flag.init(nio:))
                case .finish:
                    if let record = pendingFetch, let uid = record.uid, let flags = record.flags {
                        changedFlags[uid] = flags
                    }
                    pendingFetch = nil
                default:
                    break
            }
        }
    }

    /// A CLOSED response separates data for the old selected mailbox from this SELECT.
    private func resetForClosedBoundary() {
        accumulator = MailboxSelectionAccumulator()
        vanishedEarlier = NIOIMAPCore.UIDSet()
        changedFlags.removeAll(keepingCapacity: true)
        pendingFetch = nil
    }
}
