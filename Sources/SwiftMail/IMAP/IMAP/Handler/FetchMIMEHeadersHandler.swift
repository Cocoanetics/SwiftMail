// FetchMIMEHeadersHandler.swift
// Collects the MIME headers of several parts from one FETCH response

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Handler for ``FetchMIMEHeadersCommand``: gathers each streamed
/// `BODY[<section>.MIME]` into its section's buffer.
///
/// Only the sections that were asked for are collected, and each is capped at
/// ``maximumHeaderBytes``: a part's MIME header is a few hundred bytes, and a
/// server that streams more is not sending one.
final class FetchMIMEHeadersHandler: BaseIMAPCommandHandler<[Section: Data]>, IMAPCommandHandler, @unchecked Sendable {
    /// The most bytes kept for one part's header.
    static let maximumHeaderBytes = 64 * 1024

    private let requested: [SectionSpecifier: Section]
    private var headers: [Section: Data] = [:]
    private var current: Section?

    init(commandTag: String, promise: EventLoopPromise<[Section: Data]>, sections: [Section]) {
        var requested: [SectionSpecifier: Section] = [:]
        for section in sections {
            requested[FetchMIMEHeadersCommand<UID>.specifier(for: section)] = section
        }
        self.requested = requested
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<[Section: Data]>) {
        self.requested = [:]
        super.init(commandTag: commandTag, promise: promise)
    }

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

    private func process(_ response: FetchResponse) {
        switch response {
            case .streamingBegin(kind: .body(let specifier, _), _):
                current = requested[specifier]
                if let current, headers[current] == nil {
                    headers[current] = Data()
                }
            case .streamingBegin:
                current = nil
            case .streamingBytes(let bytes):
                guard let current, var data = headers[current] else { return }
                let room = Self.maximumHeaderBytes - data.count
                guard room > 0 else { return }
                data.append(contentsOf: bytes.readableBytesView.prefix(room))
                headers[current] = data
            case .streamingEnd, .finish:
                current = nil
            default:
                break
        }
    }
}
