import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

extension IMAPConnection {
    func id(_ identification: Identification = Identification()) async throws -> Identification {
        guard capabilities.contains(.id) else {
            throw IMAPError.commandNotSupported("ID command not supported by server")
        }

        let command = IDCommand(identification: identification)
        return try await executeCommand(command)
    }

    func noop() async throws -> [IMAPServerEvent] {
        let command = NoopCommand()
        return try await executeCommand(command)
    }

    /// Drain any untagged responses that were buffered between command handlers.
    ///
    /// Returns them converted to `IMAPServerEvent`s. Responses that don't map
    /// to a known event type are logged and skipped.
    func drainBufferedEvents() -> [IMAPServerEvent] {
        let raw = responseBuffer.drainBuffer()
        guard !raw.isEmpty else { return [] }

        logBufferedTerminationReasonsIfAny()

        logger.debug("\(connectionContext) Draining \(raw.count) buffered response(s)")
        var events: [IMAPServerEvent] = []
        for response in raw {
            events.append(contentsOf: convertBufferedResponse(response))
        }
        return events
    }

    private func logBufferedTerminationReasonsIfAny() {
        let terminationReasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
        guard !terminationReasons.isEmpty else { return }
        let joinedReasons = terminationReasons.joined(separator: " | ")
        let count = terminationReasons.count
        let warning = "\(connectionContext) Draining \(count) buffered connection "
            + "termination signal(s): \(joinedReasons)"
        logger.warning("\(warning)")
    }

    private func convertBufferedResponse(_ response: Response) -> [IMAPServerEvent] {
        switch response {
        case .untagged(let payload):
            return convertBufferedPayload(payload)
        case .fetch(let fetch):
            logBufferedFetch(fetch)
            return []
        case .fatal(let text):
            return [.bye(text.text)]
        default:
            return []
        }
    }

    private func convertBufferedPayload(_ payload: ResponsePayload) -> [IMAPServerEvent] {
        switch payload {
        case .mailboxData(let data):
            return convertBufferedMailboxData(data)
        case .messageData(let data):
            return convertBufferedMessageData(data)
        case .conditionalState(let status):
            return convertBufferedConditionalState(status)
        case .capabilityData(let caps):
            return [.capability(caps.map { String($0) })]
        default:
            logger.debug("Buffered unhandled payload: \(payload)")
            return []
        }
    }

    private func convertBufferedMailboxData(_ data: MailboxData) -> [IMAPServerEvent] {
        switch data {
        case .exists(let count):
            return [.exists(Int(count))]
        case .recent(let count):
            return [.recent(Int(count))]
        case .flags(let flags):
            return [.flags(flags.map { Flag(nio: $0) })]
        default:
            logger.debug("Buffered unhandled mailboxData: \(data)")
            return []
        }
    }

    private func convertBufferedMessageData(_ data: MessageData) -> [IMAPServerEvent] {
        switch data {
        case .expunge(let seq):
            return [.expunge(SequenceNumber(seq.rawValue))]
        default:
            logger.debug("Buffered unhandled messageData: \(data)")
            return []
        }
    }

    private func convertBufferedConditionalState(_ status: UntaggedStatus) -> [IMAPServerEvent] {
        switch status {
        case .ok(let text):
            if text.code == .alert {
                return [.alert(text.text)]
            }
            return []
        case .bye(let text):
            return [.bye(text.text)]
        default:
            return []
        }
    }

    private func logBufferedFetch(_ fetch: FetchResponse) {
        switch fetch {
        case .start, .startUID, .simpleAttribute, .finish:
            // Individual fetch parts can't be meaningfully reconstructed here
            // since we may not have the complete sequence. Log it.
            logger.debug("Buffered fetch response part: \(fetch)")
        default:
            logger.debug("Buffered unhandled fetch: \(fetch)")
        }
    }

    func handleConnectionTerminationInResponses(_ untaggedResponses: [Response]) async {
        for response in untaggedResponses {
            if case .untagged(let payload) = response,
               case .conditionalState(let status) = payload,
               case .bye = status {
                try? await self.disconnectBody()
                break
            }
            if case .fatal = response {
                try? await self.disconnectBody()
                break
            }
        }
    }
}
