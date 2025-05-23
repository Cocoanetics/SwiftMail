import Foundation
import NIOIMAPCore
import NIO

/// Handler managing the IMAP IDLE session
final class IdleHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never

    private let continuation: AsyncStream<IMAPServerEvent>.Continuation

    init(commandTag: String, promise: EventLoopPromise<Void>, continuation: AsyncStream<IMAPServerEvent>.Continuation) {
        self.continuation = continuation
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<Void>) {
        fatalError("Use init(commandTag:promise:continuation:) instead")
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(())
        continuation.finish()
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
        continuation.finish()
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(let payload) = response {
            switch payload {
            case .mailboxData(let mailboxData):
                switch mailboxData {
                case .exists(let count):
                    continuation.yield(.exists(Int(count)))
                case .recent(let count):
                    continuation.yield(.recent(Int(count)))
                default:
                    break
                }
            case .messageData(let messageData):
                switch messageData {
                case .expunge(let seq):
                    continuation.yield(.expunge(SequenceNumber(seq.rawValue)))
                default:
                    break
                }
            default:
                break
            }
        }
        return false
    }
}
