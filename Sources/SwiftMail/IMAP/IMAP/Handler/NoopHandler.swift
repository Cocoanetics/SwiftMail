import Foundation
import Logging
import NIO
import NIOIMAP
import NIOIMAPCore

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
            case let .untagged(payload):
                handleUntagged(payload)
                return false // Let base class handle tagged responses
            case let .fetch(fetch):
                handleFetch(fetch)
                return false // Let base class handle tagged responses
            case let .fatal(text):
                events.append(.bye(text.text))
                return false // Let base class handle tagged responses
            default:
                break
        }

        // For tagged responses and anything else, use base class handling
        return super.processResponse(response)
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // NoopHandler collects BYE as an event rather than terminating immediately
        if case let .untagged(payload) = response,
           case let .conditionalState(status) = payload,
           case let .bye(text) = status {
            events.append(.bye(text.text))
            return true // Indicate we handled this BYE
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
            case let .mailboxData(data):
                handleMailboxData(data)
            case let .messageData(data):
                handleMessageData(data)
            case let .conditionalState(status):
                handleConditionalState(status)
            case let .capabilityData(caps):
                events.append(.capability(caps.map { String($0) }))
            case let .enableData(caps):
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

    private func handleMailboxData(_ data: MailboxData) {
        switch data {
            case let .exists(count):
                events.append(.exists(Int(count)))
            case let .recent(count):
                events.append(.recent(Int(count)))
            case let .flags(nioFlags):
                // Permanent flags of the selected mailbox have changed
                let flags = nioFlags.map { Flag(nio: $0) }
                events.append(.flags(flags))
            case let .status(mailboxName, _):
                let name = String(bytes: mailboxName.bytes, encoding: .utf8) ?? "<unknown>"
                noopLogger.debug("NoopHandler: ignoring unsolicited STATUS for mailbox '\(name)'")
            default:
                logIgnoredMailboxData(data)
        }
    }

    private func logIgnoredMailboxData(_ data: MailboxData) {
        switch data {
            case .search:
                noopLogger.debug("NoopHandler: ignoring unsolicited SEARCH response")
            case .sort:
                noopLogger.debug("NoopHandler: ignoring unsolicited SORT response")
            case .list:
                noopLogger.debug("NoopHandler: ignoring unsolicited LIST response")
            case .lsub:
                noopLogger.debug("NoopHandler: ignoring unsolicited LSUB response")
            case .extendedSearch:
                noopLogger.debug("NoopHandler: ignoring unsolicited ESEARCH response")
            case .namespace:
                noopLogger.debug("NoopHandler: ignoring unsolicited NAMESPACE response")
            case .uidBatches:
                noopLogger.debug("NoopHandler: ignoring unsolicited UIDBATCHES response")
            default:
                break
        }
    }

    private func handleMessageData(_ data: MessageData) {
        switch data {
            case let .expunge(num):
                events.append(.expunge(SequenceNumber(num.rawValue)))
            case let .vanished(nioUIDSet):
                // RFC 7162 CONDSTORE: server reports expunged UIDs directly
                let uidSet = UIDSet(nio: nioUIDSet)
                events.append(.vanished(uidSet))
            case let .vanishedEarlier(nioUIDSet):
                noopLogger.debug("NoopHandler: ignoring VANISHED (EARLIER) for \(nioUIDSet) UIDs")
            case .generateAuthorizedURL:
                noopLogger.debug("NoopHandler: ignoring unsolicited GENURLAUTH")
            case .urlFetch:
                noopLogger.debug("NoopHandler: ignoring unsolicited URLFETCH")
        }
    }

    private func handleConditionalState(_ status: UntaggedStatus) {
        switch status {
            case let .ok(text):
                if text.code == .alert {
                    events.append(.alert(text.text))
                }
            case let .bye(text):
                events.append(.bye(text.text))
            default:
                break
        }
    }

    private func handleFetch(_ fetch: FetchResponse) {
        switch fetch {
            case let .start(seq):
                currentSeq = SequenceNumber(seq.rawValue)
                currentUID = nil
                currentAttributes = []
            case let .startUID(uid):
                currentUID = UID(uid.rawValue)
                currentSeq = nil
                currentAttributes = []
            case let .simpleAttribute(attribute):
                currentAttributes.append(attribute)
            case .finish:
                handleFetchFinish()
            case let .streamingBegin(kind, byteCount):
                noopLogger.debug("NoopHandler: ignoring streaming FETCH begin (kind=\(kind), bytes=\(byteCount))")
            case .streamingBytes:
                break // Silently skip streaming body bytes
            case .streamingEnd:
                noopLogger.debug("NoopHandler: streaming FETCH ended")
        }
    }

    private func handleFetchFinish() {
        if let seq = currentSeq {
            events.append(.fetch(seq, currentAttributes))
        } else if let uid = currentUID {
            let message = "NoopHandler: UID FETCH finish for UID \(uid.value)"
                + ", attributes: \(currentAttributes.count)"
            noopLogger.debug("\(message)")
            events.append(.fetchUID(uid, currentAttributes))
        }
        currentSeq = nil
        currentUID = nil
        currentAttributes = []
    }
}
