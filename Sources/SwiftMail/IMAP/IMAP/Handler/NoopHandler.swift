import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import Logging

/// Handler collecting unsolicited responses for a NOOP command.
final class NoopHandler: BaseIMAPCommandHandler<[IMAPServerEvent]>, IMAPCommandHandler, @unchecked Sendable {
    private var events: [IMAPServerEvent] = []
    private var currentSeq: SequenceNumber?
    private var currentUID: UID?
    private var currentAttributes: [MessageAttribute] = []
    private let noopLogger = Logger(label: "com.cocoanetics.SwiftMail.NoopHandler")

    override func processResponse(_ response: Response) -> Bool {
        // Handle our specific responses first, then call super
        switch response {
        case .untagged(let payload):
            handleUntagged(payload)
            return false  // Let base class handle tagged responses
        case .fetch(let fetch):
            handleFetch(fetch)
            return false  // Let base class handle tagged responses
        case .fatal(let text):
            events.append(.bye(text.text))
            return false  // Let base class handle tagged responses
        default:
            break
        }
        
        // For tagged responses and anything else, use base class handling
        return super.processResponse(response)
    }
    
    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // NoopHandler collects BYE as an event rather than terminating immediately
        if case .untagged(let payload) = response,
           case .conditionalState(let status) = payload,
           case .bye(let text) = status {
            events.append(.bye(text.text))
            return true  // Indicate we handled this BYE
        }
        
        // Let base class handle other untagged responses
        return super.handleUntaggedResponse(response)
    }

    	override func handleTaggedOKResponse(_ response: TaggedResponse) {
		// Call super to handle CLIENTBUG warnings
		super.handleTaggedOKResponse(response)
		
		succeedWithResult(events)
	}

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPProtocolError.unexpectedTaggedResponse(String(describing: response.state)))
    }

    private func handleUntagged(_ payload: ResponsePayload) {
        switch payload {
        case .mailboxData(let data):
            switch data {
            case .exists(let count):
                events.append(.exists(Int(count)))
            case .recent(let count):
                events.append(.recent(Int(count)))
            case .flags(let nioFlags):
                // Permanent flags of the selected mailbox have changed
                let flags = nioFlags.map { Flag(nio: $0) }
                events.append(.flags(flags))
            case .status(let mailboxName, _):
                let name = String(bytes: mailboxName.bytes, encoding: .utf8) ?? "<unknown>"
                noopLogger.debug("NoopHandler: ignoring unsolicited STATUS for mailbox '\(name)'")
            case .search:
                noopLogger.debug("NoopHandler: ignoring unsolicited SEARCH response")
            case .list:
                noopLogger.debug("NoopHandler: ignoring unsolicited LIST response")
            case .lsub:
                noopLogger.debug("NoopHandler: ignoring unsolicited LSUB response")
            case .extendedSearch:
                noopLogger.debug("NoopHandler: ignoring unsolicited ESEARCH response")
            case .namespace:
                noopLogger.debug("NoopHandler: ignoring unsolicited NAMESPACE response")
            case .searchSort:
                noopLogger.debug("NoopHandler: ignoring unsolicited SEARCH SORT response")
            case .uidBatches:
                noopLogger.debug("NoopHandler: ignoring unsolicited UIDBATCHES response")
            }
        case .messageData(let data):
            switch data {
            case .expunge(let num):
                events.append(.expunge(SequenceNumber(num.rawValue)))
            case .vanished(let nioUIDSet):
                // RFC 7162 CONDSTORE: server reports expunged UIDs directly
                let uidSet = UIDSet(nio: nioUIDSet)
                events.append(.vanished(uidSet))
            case .vanishedEarlier(let nioUIDSet):
                noopLogger.debug("NoopHandler: ignoring VANISHED (EARLIER) for \(nioUIDSet) UIDs")
            case .generateAuthorizedURL:
                noopLogger.debug("NoopHandler: ignoring unsolicited GENURLAUTH")
            case .urlFetch:
                noopLogger.debug("NoopHandler: ignoring unsolicited URLFETCH")
            }
        case .conditionalState(let status):
            switch status {
            case .ok(let text):
                if text.code == .alert {
                    events.append(.alert(text.text))
                }
            case .bye(let text):
                events.append(.bye(text.text))
            default:
                break
            }
        case .capabilityData(let caps):
            events.append(.capability(caps.map { String($0) }))
        case .enableData(let caps):
            noopLogger.debug("NoopHandler: ignoring ENABLED response: \(caps.map { String($0) })")
        case .id:
            noopLogger.debug("NoopHandler: ignoring unsolicited ID response")
        case .quotaRoot:
            noopLogger.debug("NoopHandler: ignoring unsolicited QUOTAROOT")
        case .quota:
            noopLogger.debug("NoopHandler: ignoring unsolicited QUOTA")
        case .metadata:
            noopLogger.debug("NoopHandler: ignoring unsolicited METADATA")
        case .jmapAccess:
            noopLogger.debug("NoopHandler: ignoring unsolicited JMAPACCESS")
        }
    }

    private func handleFetch(_ fetch: FetchResponse) {
        switch fetch {
        case .start(let seq):
            currentSeq = SequenceNumber(seq.rawValue)
            currentUID = nil
            currentAttributes = []
        case .startUID(let uid):
            currentUID = UID(uid.rawValue)
            currentSeq = nil
            currentAttributes = []
        case .simpleAttribute(let attribute):
            currentAttributes.append(attribute)
        case .finish:
            if let seq = currentSeq {
                events.append(.fetch(seq, currentAttributes))
            } else if let uid = currentUID {
                noopLogger.debug("NoopHandler: UID FETCH finish for UID \(uid.value), attributes: \(currentAttributes.count)")
                events.append(.fetchUID(uid, currentAttributes))
            }
            currentSeq = nil
            currentUID = nil
            currentAttributes = []
        case .streamingBegin(let kind, let byteCount):
            noopLogger.debug("NoopHandler: ignoring streaming FETCH begin (kind=\(kind), bytes=\(byteCount))")
        case .streamingBytes:
            break  // Silently skip streaming body bytes
        case .streamingEnd:
            noopLogger.debug("NoopHandler: streaming FETCH ended")
        }
    }
}
