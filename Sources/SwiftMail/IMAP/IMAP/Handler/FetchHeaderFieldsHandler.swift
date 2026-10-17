// FetchHeaderFieldsHandler.swift
// Collects the raw header lines of named fields from one FETCH response

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Handler for ``FetchHeaderFieldsCommand``: gathers each message's streamed
/// `BODY[HEADER.FIELDS (...)]` and files it under the message's identifier.
///
/// The identifier is known only once the message's FETCH response ends: a
/// server may send `UID` after the body section. Each block is capped at
/// ``maximumHeaderBytes``.
final class FetchHeaderFieldsHandler<T: MessageIdentifier>:
    BaseIMAPCommandHandler<[T: Data]>, IMAPCommandHandler, @unchecked Sendable {
    /// The most bytes kept for one message's header block.
    static var maximumHeaderBytes: Int { 256 * 1024 }

    private var headers: [T: Data] = [:]
    private var sequenceNumber: SequenceNumber?
    private var uid: UID?
    private var block: Data?
    private var collecting = false

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        succeedWithResult(lock.withLock { headers })
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.fetchFailed(String(describing: response.state)))
    }

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        if case .fetch(let fetchResponse) = response {
            lock.withLock { process(fetchResponse) }
        }
        return handled
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        // Keep only connection-termination responses. Retaining the streamed
        // FETCH events in the base history would hold every byte the server
        // sends, past the cap on each block.
        if case .untagged(.conditionalState(.bye)) = response {
            return super.handleUntaggedResponse(response)
        }
        if case .fatal = response { return super.handleUntaggedResponse(response) }
        return false
    }

    private func process(_ response: FetchResponse) {
        switch response {
            case .start(let number):
                beginMessage(sequenceNumber: SequenceNumber(number.rawValue), uid: nil)
            case .startUID(let number):
                beginMessage(sequenceNumber: nil, uid: UID(nio: number))
            case .simpleAttribute(.uid(let number)):
                uid = UID(nio: number)
            case .streamingBegin(let kind, _):
                collecting = Self.isHeaderFields(kind)
                if collecting, block == nil { block = Data() }
            case .streamingBytes(let bytes):
                append(bytes)
            case .streamingEnd:
                collecting = false
            case .finish:
                if let block, let key = identifier() {
                    headers[key] = block
                }
                beginMessage(sequenceNumber: nil, uid: nil)
            default:
                break
        }
    }

    private func append(_ bytes: ByteBuffer) {
        guard collecting, var data = block else { return }
        let room = Self.maximumHeaderBytes - data.count
        guard room > 0 else { return }
        data.append(contentsOf: bytes.readableBytesView.prefix(room))
        block = data
    }

    private func beginMessage(sequenceNumber: SequenceNumber?, uid: UID?) {
        self.sequenceNumber = sequenceNumber
        self.uid = uid
        block = nil
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

    /// Only one body section is requested, so any `HEADER.FIELDS` section of
    /// the whole message is it. The field list is not compared: servers may
    /// echo the names in another case or quoting.
    static func isHeaderFields(_ kind: StreamingKind) -> Bool {
        guard case .body(let section, _) = kind, section.part == SectionSpecifier.Part([]) else { return false }
        if case .headerFields = section.kind { return true }
        return false
    }
}
