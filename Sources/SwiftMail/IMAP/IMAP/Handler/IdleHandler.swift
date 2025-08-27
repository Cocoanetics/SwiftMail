import Foundation
import NIOIMAPCore
import NIOIMAP
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
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		succeedWithResult(())
		continuation.finish()
	}

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
        continuation.finish()
    }

    private var currentSeq: SequenceNumber?
    private var currentAttributes: [MessageAttribute] = []

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        switch response {
        case .untagged(let payload):
            return handlePayload(payload)
        case .fetch(let fetch):
            handleFetch(fetch)
        case .fatal(let text):
            continuation.yield(.bye(text.text))
            // Server-initiated termination - complete the IDLE session
            succeedWithResult(())
            continuation.finish()
            return true  // Indicate this response was fully handled
        default:
            break
        }
        return false
    }

    private func handlePayload(_ payload: ResponsePayload) -> Bool {
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
        case .conditionalState(let status):
            switch status {
            case .ok(let text):
                if text.code == .alert {
                    continuation.yield(.alert(text.text))
                }
            case .bye(let text):
                continuation.yield(.bye(text.text))
                // Server-initiated termination - complete the IDLE session
                succeedWithResult(())
                continuation.finish()
                return true  // Indicate this response was fully handled
            default:
                break
            }
        case .capabilityData(let caps):
            continuation.yield(.capability(caps.map { String($0) }))
        default:
            break
        }
        return false  // Most responses are handled but don't terminate the command
    }

    private func handleFetch(_ fetch: FetchResponse) {
        switch fetch {
        case .start(let seq):
            currentSeq = SequenceNumber(seq.rawValue)
            currentAttributes = []
        case .simpleAttribute(let attribute):
            currentAttributes.append(attribute)
        case .finish:
            if let seq = currentSeq {
                continuation.yield(.fetch(seq, currentAttributes))
            }
            currentSeq = nil
            currentAttributes = []
        default:
            break
        }
    }
}
