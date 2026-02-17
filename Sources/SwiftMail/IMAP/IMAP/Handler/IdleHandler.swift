import Foundation
import NIOIMAPCore
import NIOIMAP
import NIO
import Logging

/// Handler managing the IMAP IDLE session
final class IdleHandler: BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never

    private let continuation: AsyncStream<IMAPServerEvent>.Continuation
    private let idleLogger = Logger(label: "com.cocoanetics.SwiftMail.IdleHandler")

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
    private var currentUID: UID?
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
            idleLogger.debug("IdleHandler: unhandled Response case: \(response)")
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
            case .flags(let nioFlags):
                // Permanent flags of the selected mailbox have changed
                let flags = nioFlags.map { Flag(nio: $0) }
                continuation.yield(.flags(flags))
            case .status(let mailboxName, _):
                // Unsolicited STATUS — log and ignore (not a selected-mailbox event)
                let name = String(bytes: mailboxName.bytes, encoding: .utf8) ?? "<unknown>"
                idleLogger.debug("IdleHandler: ignoring unsolicited STATUS for mailbox '\(name)'")
            case .search:
                idleLogger.debug("IdleHandler: ignoring unsolicited SEARCH response during IDLE")
            case .list:
                idleLogger.debug("IdleHandler: ignoring unsolicited LIST response during IDLE")
            case .lsub:
                idleLogger.debug("IdleHandler: ignoring unsolicited LSUB response during IDLE")
            case .extendedSearch:
                idleLogger.debug("IdleHandler: ignoring unsolicited ESEARCH response during IDLE")
            case .namespace:
                idleLogger.debug("IdleHandler: ignoring unsolicited NAMESPACE response during IDLE")
            case .searchSort:
                idleLogger.debug("IdleHandler: ignoring unsolicited SEARCH SORT response during IDLE")
            case .uidBatches:
                idleLogger.debug("IdleHandler: ignoring unsolicited UIDBATCHES response during IDLE")
            }
        case .messageData(let messageData):
            switch messageData {
            case .expunge(let seq):
                continuation.yield(.expunge(SequenceNumber(seq.rawValue)))
            case .vanished(let nioUIDSet):
                // RFC 7162 CONDSTORE: server reports expunged UIDs directly
                let uidSet = UIDSet(nio: nioUIDSet)
                continuation.yield(.vanished(uidSet))
            case .vanishedEarlier(let nioUIDSet):
                // VANISHED (EARLIER) is a historic-sync response, not a real-time event
                idleLogger.debug("IdleHandler: ignoring VANISHED (EARLIER) for \(nioUIDSet) UIDs")
            case .generateAuthorizedURL:
                idleLogger.debug("IdleHandler: ignoring unsolicited GENURLAUTH during IDLE")
            case .urlFetch:
                idleLogger.debug("IdleHandler: ignoring unsolicited URLFETCH during IDLE")
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
        case .enableData(let caps):
            idleLogger.debug("IdleHandler: ignoring ENABLED response: \(caps.map { String($0) })")
        case .id:
            idleLogger.debug("IdleHandler: ignoring unsolicited ID response during IDLE")
        case .quotaRoot:
            idleLogger.debug("IdleHandler: ignoring unsolicited QUOTAROOT during IDLE")
        case .quota:
            idleLogger.debug("IdleHandler: ignoring unsolicited QUOTA during IDLE")
        case .metadata:
            idleLogger.debug("IdleHandler: ignoring unsolicited METADATA during IDLE")
        case .jmapAccess:
            idleLogger.debug("IdleHandler: ignoring unsolicited JMAPACCESS during IDLE")
        }
        return false  // Most responses are handled but don't terminate the command
    }

    private func handleFetch(_ fetch: FetchResponse) {
        switch fetch {
        case .start(let seq):
            currentSeq = SequenceNumber(seq.rawValue)
            currentUID = nil
            currentAttributes = []
        case .startUID(let uid):
            // UID FETCH response — record the UID and begin collecting attributes
            currentUID = UID(uid.rawValue)
            currentSeq = nil
            currentAttributes = []
        case .simpleAttribute(let attribute):
            currentAttributes.append(attribute)
        case .finish:
            if let seq = currentSeq {
                continuation.yield(.fetch(seq, currentAttributes))
            } else if let uid = currentUID {
                idleLogger.debug("IdleHandler: UID FETCH finish for UID \(uid.value), attributes: \(currentAttributes.count)")
                continuation.yield(.fetchUID(uid, currentAttributes))
            }
            currentSeq = nil
            currentUID = nil
            currentAttributes = []
        case .streamingBegin(let kind, let byteCount):
            idleLogger.debug("IdleHandler: ignoring streaming FETCH begin (kind=\(kind), bytes=\(byteCount)) during IDLE")
        case .streamingBytes:
            break  // Silently skip streaming body bytes
        case .streamingEnd:
            idleLogger.debug("IdleHandler: streaming FETCH ended during IDLE")
        }
    }
}
