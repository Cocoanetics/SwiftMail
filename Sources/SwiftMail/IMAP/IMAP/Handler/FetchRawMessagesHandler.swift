// FetchRawMessagesHandler.swift
// Passes each message's complete raw bytes from one FETCH response to a sink

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Handler for ``FetchRawMessagesCommand``: gathers each message's streamed
/// `BODY[]` and hands it to the sink, under the message's identifier, once the
/// message's FETCH response ends. Only one body is held at a time.
///
/// The identifier is known only once the message's FETCH response ends: a
/// server may send `UID` after the body. Invalid server data fails the command
/// once its tagged response arrives, so the rest of the response is still
/// consumed here: in a UID fetch, a body whose FETCH response carries no UID.
/// Nothing is passed on after that. A second body for an identifier already
/// delivered in this command is ignored.
final class FetchRawMessagesHandler<T: MessageIdentifier>:
    BaseIMAPCommandHandler<Void>, IMAPCommandHandler, @unchecked Sendable {
    private let sink: @Sendable (T, Data) -> Void
    private var delivered: Set<T> = []
    private var sequenceNumber: SequenceNumber?
    private var uid: UID?
    private var body: Data?
    private var collecting = false
    /// The first invalid server data seen; reported instead of success.
    private var failure: IMAPError?

    init(commandTag: String, promise: EventLoopPromise<Void>, sink: @escaping @Sendable (T, Data) -> Void) {
        self.sink = sink
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<Void>) {
        self.sink = { _, _ in }
        super.init(commandTag: commandTag, promise: promise)
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        let failure: IMAPError? = lock.withLock { self.failure }
        if let failure {
            failWithError(failure)
        } else {
            // The base implementation succeeds a Void promise.
            super.handleTaggedOKResponse(response)
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        if case .fetch(let fetchResponse) = response {
            // The sink runs outside the lock.
            let delivery = lock.withLock { process(fetchResponse) }
            if let delivery { sink(delivery.identifier, delivery.data) }
        }
        return handled
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Keep only connection-termination responses. Retaining the streamed
        // FETCH events in the base history would buffer every body twice.
        if case .untagged(.conditionalState(.bye)) = response {
            return super.handleUntaggedResponse(response)
        }
        if case .fatal = response { return super.handleUntaggedResponse(response) }
        return false
    }

    private func process(_ response: FetchResponse) -> (identifier: T, data: Data)? {
        switch response {
            case .start(let number):
                beginMessage(sequenceNumber: SequenceNumber(number.rawValue), uid: nil)
            case .startUID(let number):
                beginMessage(sequenceNumber: nil, uid: UID(nio: number))
            case .simpleAttribute(.uid(let number)):
                uid = UID(nio: number)
            case .streamingBegin(let kind, _):
                collecting = Self.isCompleteBody(kind)
                if collecting, body == nil { body = Data() }
            case .streamingBytes(let bytes):
                if collecting { body?.append(contentsOf: bytes.readableBytesView) }
            case .streamingEnd:
                collecting = false
            case .finish:
                let delivery = finishMessage()
                beginMessage(sequenceNumber: nil, uid: nil)
                return delivery
            default:
                break
        }
        return nil
    }

    private func finishMessage() -> (identifier: T, data: Data)? {
        guard let body else { return nil }
        guard let key = identifier() else {
            record(.fetchFailed(
                "Server sent a body for \(messageDescription) without its UID in a UID FETCH"
            ))
            return nil
        }
        guard failure == nil else { return nil }
        guard delivered.insert(key).inserted else {
            logger.debug("Ignoring a repeated body for \(messageDescription)")
            return nil
        }
        return (key, body)
    }

    private func record(_ error: IMAPError) {
        if failure == nil { failure = error }
    }

    private func beginMessage(sequenceNumber: SequenceNumber?, uid: UID?) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        body = nil
        collecting = false
    }

    /// The finished message's key: its UID for a UID fetch, its sequence
    /// number otherwise.
    private func identifier() -> T? {
        if T.self == UID.self {
            return uid.map { T($0.value) }
        }
        return sequenceNumber.map { T($0.value) }
    }

    /// The finished message, by the identifiers its response carried.
    private var messageDescription: String {
        if let uid { return "UID \(uid.value)" }
        if let sequenceNumber { return "message \(sequenceNumber.value)" }
        return "a message"
    }

    /// Only the full-message `BODY[]` is wanted; part, header and text
    /// sections are not it.
    static func isCompleteBody(_ kind: StreamingKind) -> Bool {
        guard case .body(let section, _) = kind else { return false }
        return section == SectionSpecifier.complete
    }
}
