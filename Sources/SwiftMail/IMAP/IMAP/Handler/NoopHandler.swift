import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO

/// Handler collecting unsolicited responses for a NOOP command.
final class NoopHandler: BaseIMAPCommandHandler<[IMAPServerEvent]>, IMAPCommandHandler, @unchecked Sendable {
    private var events: [IMAPServerEvent] = []
    private var currentSeq: SequenceNumber?
    private var currentAttributes: [MessageAttribute] = []

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
            default:
                break
            }
        case .messageData(let data):
            switch data {
            case .expunge(let num):
                events.append(.expunge(SequenceNumber(num.rawValue)))
            default:
                break
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
        default:
            break
        }
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
                events.append(.fetch(seq, currentAttributes))
            }
            currentSeq = nil
            currentAttributes = []
        default:
            break
        }
    }
}
