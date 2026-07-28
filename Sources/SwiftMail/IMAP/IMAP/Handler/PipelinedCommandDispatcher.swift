// PipelinedCommandDispatcher.swift
// NIO channel handler that routes responses to multiple in-flight pipelined command handlers.
//
// IMAP RFC 3501 §5.5 allows clients to send multiple commands without waiting for responses.
// The server processes commands in order and sends tagged responses (A001 OK, A002 OK, etc.)
// so responses can be matched to commands by tag. Untagged responses (e.g., * FETCH data)
// carry no tag; they arrive grouped per message (`.start` … `.finish`) and are routed by
// content when the group identifies itself (UID attribute, streamed body section) and by
// send order otherwise. A server may stream data for several pipelined commands before
// sending any tagged OK (RFC 3501 §5.5), so advancing only on the tagged OK would misdeliver
// a later command's data to an already-finished earlier handler and silently drop it.
//
// Unsolicited FETCH responses are a hard requirement here: RFC 3501 §7.4.2 lets the server
// broadcast flag changes (`* n FETCH (FLAGS (\Seen))`) at any time, including interleaved
// into a pipelined burst. Such a group carries attributes only — no streamed body data — and
// must not consume a pending command's routing slot: doing so shifts every subsequent part's
// bytes one command over and the corruption is cached as a successful fetch. Groups are
// therefore held back until they prove they belong to a command by streaming body data;
// attribute-only groups are discarded at their `.finish`.
//
// This handler sits in the NIO pipeline during a pipelined batch. It maintains an ordered
// registry of (tag → PipelinedHandler) and routes responses accordingly.

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

final class PipelinedCommandDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias InboundOut = Response

    private let lock = NIOLock()

    /// A registered pipelined command awaiting its responses. `finishedUntagged` flips
    /// once this command's untagged FETCH data has fully arrived, so subsequent untagged
    /// data routes to the next command even before any tagged OK. `uid` and
    /// `expectedSection` enable content-verified routing when the server's response
    /// identifies itself; entries registered without them fall back to send order.
    private struct PendingCommand {
        let tag: String
        let handler: any PipelinedHandler
        let uid: UID?
        let expectedSection: SectionSpecifier?
        var finishedUntagged: Bool
    }

    /// The untagged FETCH group currently arriving (one `.start` … `.finish` span).
    private enum UntaggedGroup {
        case idle
        /// `.start` seen but no body data yet. The group's responses are held back
        /// (start plus simple attributes — bounded and small) until it proves it
        /// belongs to a pipelined command by streaming body data.
        case pending(held: [FetchResponse], uid: UID?)
        /// Group bound to a command; body chunks stream straight through. A server
        /// may satisfy several pipelined commands for one message inside a single
        /// group, so `touchedTags` tracks every entry the group delivered to.
        case bound(currentTag: String, touchedTags: Set<String>, uid: UID?)
        /// Group streams body data no pending command asked for; swallowed to `.finish`.
        case dropping
    }

    /// Ordered registry — insertion order matches send order.
    private var entries: [PendingCommand] = []
    private var group: UntaggedGroup = .idle

    private let logger = Logger(label: "com.cocoanetics.SwiftMail.PipelinedDispatcher")

    /// Register a handler for a command tag. Must be called in send order.
    /// Pass `uid` and `expectedSection` to enable content-verified routing.
    func register(
        tag: String,
        handler: any PipelinedHandler,
        uid: UID? = nil,
        expectedSection: SectionSpecifier? = nil
    ) {
        lock.withLock {
            entries.append(PendingCommand(
                tag: tag,
                handler: handler,
                uid: uid,
                expectedSection: expectedSection,
                finishedUntagged: false
            ))
        }
    }

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        lock.withLock {
            switch response {
                case .tagged(let taggedResponse):
                    // Route to the handler that owns this tag
                    if let idx = entries.firstIndex(where: { $0.tag == taggedResponse.tag }) {
                        let handler = entries[idx].handler
                        handler.processTaggedResponse(taggedResponse)
                        entries.remove(at: idx)
                    }

                case .fetch(let fetchResponse):
                    routeUntaggedFetch(fetchResponse)

                case .untagged(let payload):
                    // BYE — server is terminating. Fail all pending handlers.
                    if case .conditionalState(let status) = payload, case .bye(let text) = status {
                        failAllPending(IMAPError.connectionFailed("Server terminated connection: \(text.text)"))
                    }

                case .fatal(let text):
                    failAllPending(IMAPError.connectionFailed("Server fatal error: \(text.text)"))

                default:
                    break
            }
        }

        // Always forward to the next handler in the pipeline (UntaggedResponseBuffer)
        context.fireChannelRead(data)
    }

    // MARK: - Untagged FETCH group routing (caller holds `lock`)

    private func routeUntaggedFetch(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case .start:
                beginGroup(uid: nil, fetchResponse)
            case .startUID(let nioUID):
                beginGroup(uid: UID(nio: nioUID), fetchResponse)
            case .simpleAttribute(let attribute):
                handleGroupAttribute(attribute, fetchResponse)
            case .streamingBegin(let kind, _):
                handleStreamingBegin(kind: kind, fetchResponse)
            case .streamingBytes, .streamingEnd:
                deliverBodyChunk(fetchResponse)
            case .finish:
                finishGroup(fetchResponse)
            default:
                deliverToBoundEntry(fetchResponse)
        }
    }

    private func beginGroup(uid: UID?, _ response: FetchResponse) {
        abandonOpenGroup()
        group = .pending(held: [response], uid: uid)
    }

    /// A `.start` arrived while a group was still open — the server never sent the
    /// previous group's `.finish`. Close out a bound group so routing can continue;
    /// discard a pending one (it never proved itself).
    private func abandonOpenGroup() {
        switch group {
            case .idle, .dropping:
                break
            case .pending:
                logger.debug("Discarding unterminated attribute-only FETCH group")
            case .bound(let currentTag, let touchedTags, _):
                logger.warning("FETCH group for tag \(currentTag) ended without .finish; closing it out")
                markTouchedFinished(touchedTags, deliverFinishTo: currentTag)
        }
        group = .idle
    }

    private func handleGroupAttribute(_ attribute: MessageAttribute, _ response: FetchResponse) {
        switch group {
            case .pending(var held, var uid):
                if case .uid(let nioUID) = attribute {
                    uid = UID(nio: nioUID)
                }
                held.append(response)
                group = .pending(held: held, uid: uid)
            case .bound(let currentTag, let touchedTags, _):
                if case .uid(let nioUID) = attribute {
                    verifyBoundUID(UID(nio: nioUID), currentTag: currentTag)
                    group = .bound(currentTag: currentTag, touchedTags: touchedTags, uid: UID(nio: nioUID))
                }
                deliver(response, toTag: currentTag)
            case .dropping, .idle:
                break
        }
    }

    /// The UID attribute can arrive after body data has already been delivered. A
    /// mismatch at that point cannot be unwound — surface it loudly for diagnosis.
    private func verifyBoundUID(_ uid: UID, currentTag: String) {
        guard let entry = entries.first(where: { $0.tag == currentTag }),
              let expected = entry.uid, expected != uid else { return }
        let message = "FETCH group bound to tag \(currentTag) (UID \(expected.value)) reported "
            + "UID \(uid.value); possible misrouted pipelined response"
        logger.warning("\(message)")
    }

    private func handleStreamingBegin(kind: StreamingKind, _ response: FetchResponse) {
        let section: SectionSpecifier?
        switch kind {
            case .body(let specifier, _):
                section = specifier
            case .binary(let part, _):
                section = SectionSpecifier(part: part)
            case .rfc822, .rfc822Text, .rfc822Header:
                section = nil
        }
        bindOrRebind(section: section, response)
    }

    /// Streamed body data is the proof that a group answers a pipelined command.
    /// Bind a pending group to the best-matching entry; inside an already-bound
    /// group, a new section may switch delivery to that section's own entry (a
    /// server may satisfy several pipelined commands in one group).
    private func bindOrRebind(section: SectionSpecifier?, _ response: FetchResponse) {
        switch group {
            case .pending(let held, let uid):
                guard let idx = bindableEntryIndex(uid: uid, section: section) else {
                    logger.warning("Dropping untagged FETCH body data that matches no pipelined command")
                    group = .dropping
                    return
                }
                let tag = entries[idx].tag
                group = .bound(currentTag: tag, touchedTags: [tag], uid: uid)
                for heldResponse in held {
                    entries[idx].handler.processFetchResponse(heldResponse)
                }
                entries[idx].handler.processFetchResponse(response)
            case .bound(let currentTag, var touchedTags, let uid):
                var targetTag = currentTag
                if let section,
                   let idx = bindableEntryIndex(uid: uid, section: section),
                   entries[idx].expectedSection == section {
                    targetTag = entries[idx].tag
                }
                touchedTags.insert(targetTag)
                group = .bound(currentTag: targetTag, touchedTags: touchedTags, uid: uid)
                deliver(response, toTag: targetTag)
            case .dropping:
                break
            case .idle:
                // Streaming without `.start` — tolerate by treating it as its own group.
                group = .pending(held: [], uid: nil)
                bindOrRebind(section: section, response)
        }
    }

    /// Body bytes inside a pending group (a parser that skipped `.streamingBegin`)
    /// still prove the group is a command response — bind by uid/order.
    private func deliverBodyChunk(_ response: FetchResponse) {
        switch group {
            case .pending:
                bindOrRebind(section: nil, response)
            case .bound(let currentTag, _, _):
                deliver(response, toTag: currentTag)
            case .dropping, .idle:
                break
        }
    }

    private func deliverToBoundEntry(_ response: FetchResponse) {
        if case .bound(let currentTag, _, _) = group {
            deliver(response, toTag: currentTag)
        }
    }

    private func finishGroup(_ response: FetchResponse) {
        switch group {
            case .pending(let held, _):
                // Attribute-only group: an unsolicited FETCH (e.g. a flag-change
                // broadcast, RFC 3501 §7.4.2) — not a response to any pipelined
                // command. It must not consume a command's routing slot.
                logger.debug("Ignoring unsolicited attribute-only FETCH group (\(held.count) responses)")
            case .bound(let currentTag, let touchedTags, _):
                markTouchedFinished(touchedTags, deliverFinishTo: currentTag)
            case .dropping, .idle:
                break
        }
        group = .idle
    }

    private func markTouchedFinished(_ touchedTags: Set<String>, deliverFinishTo currentTag: String) {
        deliver(.finish, toTag: currentTag)
        for idx in entries.indices where touchedTags.contains(entries[idx].tag) {
            entries[idx].finishedUntagged = true
        }
    }

    private func deliver(_ response: FetchResponse, toTag tag: String) {
        guard let idx = entries.firstIndex(where: { $0.tag == tag }) else { return }
        entries[idx].handler.processFetchResponse(response)
    }

    /// Pick the entry a body-bearing group belongs to. Most specific match wins:
    /// uid + section, then uid, then section, then send order. A group whose UID
    /// matches no registered command is unsolicited — return nil so it is dropped
    /// rather than corrupting a pending command's data.
    private func bindableEntryIndex(uid: UID?, section: SectionSpecifier?) -> Int? {
        let candidates = entries.indices.filter { !entries[$0].finishedUntagged }
        guard !candidates.isEmpty else { return nil }

        if let uid {
            let uidMatches = candidates.filter { entries[$0].uid == uid }
            if !uidMatches.isEmpty {
                if let section,
                   let exact = uidMatches.first(where: { entries[$0].expectedSection == section }) {
                    return exact
                }
                return uidMatches.first
            }
            if entries.contains(where: { $0.uid != nil }) {
                return nil
            }
        }
        if let section,
           let match = candidates.first(where: { entries[$0].expectedSection == section }) {
            return match
        }
        return candidates.first
    }

    /// Fail every pending handler and clear the registry. Caller holds `lock`.
    private func failAllPending(_ error: Error) {
        for entry in entries {
            entry.handler.fail(error)
        }
        entries.removeAll()
        group = .idle
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = IMAPError.connectionFailed("Connection closed during pipelined fetch")
        lock.withLock {
            failAllPending(error)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            failAllPending(error)
        }
        context.fireErrorCaught(error)
    }

    /// Number of handlers still pending (for diagnostics).
    var pendingCount: Int {
        lock.withLock { entries.count }
    }
}
