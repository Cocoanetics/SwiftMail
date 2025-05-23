import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO

/// Handler managing the IMAP IDLE session
final class IdleHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    private let continuation: AsyncStream<IMAPServerEvent>.Continuation
    private var currentSequence: SequenceNumber?

    init(commandTag: String, promise: EventLoopPromise<Void>, continuation: AsyncStream<IMAPServerEvent>.Continuation) {
        self.continuation = continuation
        self.currentSequence = nil
        super.init(commandTag: commandTag, promise: promise)
    }

    override func processResponse(_ response: Response) -> Bool {
        // Let base class log and check for tagged completion
        let handled = super.processResponse(response)

        switch response {
        case .idleStarted:
            // IDLE confirmed, nothing to report
            return false
        case .fetch(let fetch):
            handleFetch(fetch)
            return false
        case .untagged(let payload):
            handleUntagged(payload)
            return false
        default:
            return handled
        }
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(())
        continuation.finish()
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
        continuation.finish()
    }

    private func handleUntagged(_ payload: ResponsePayload) {
        switch payload {
        case .mailboxData(.exists(let count)):
            // EXISTS responses just indicate message count; clients may refetch
            continuation.yield(.newMessage(UID(UInt32(count))))
        case .messageData(.expunge(let seq)):
            continuation.yield(.expunge(SequenceNumber(nio: seq)))
        case .conditionalState(let state):
            if case .bye(let text) = state {
                continuation.yield(.bye(text.text))
            }
        default:
            break
        }
    }

    private func handleFetch(_ fetch: FetchResponse) {
        switch fetch {
        case .start(let seq):
            currentSequence = SequenceNumber(nio: seq)
        case .simpleAttribute(let attr):
            guard let seq = currentSequence else { return }
            switch attr {
            case .uid(let uid):
                continuation.yield(.newMessage(UID(nio: uid)))
            case .flags(let flags):
                continuation.yield(.flagsChanged(seq, flags.map(convertFlag)))
            default:
                break
            }
        case .finish:
            currentSequence = nil
        default:
            break
        }
    }

    private func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
        let str = String(flag)
        switch str.uppercased() {
        case "\\SEEN": return .seen
        case "\\ANSWERED": return .answered
        case "\\FLAGGED": return .flagged
        case "\\DELETED": return .deleted
        case "\\DRAFT": return .draft
        default: return .custom(str)
        }
    }
}
