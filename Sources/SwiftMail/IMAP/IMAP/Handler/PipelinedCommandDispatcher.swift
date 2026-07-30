// Routes responses to multiple in-flight pipelined command handlers. Untagged FETCH
// spans are matched by UID/section when available and by send order only when the
// response carries no verifiable identity. RFC 3501 §5.5 permits several untagged
// responses before any tagged completion, so routing cannot advance only on tagged OK.
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
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

final class PipelinedCommandDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias InboundOut = Response

    private let lock = NIOLock()

    /// Ordered registry — insertion order matches send order.
    private var entries: [PipelinedPendingCommand] = []
    private var group: PipelinedUntaggedGroup = .idle

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
            entries.append(PipelinedPendingCommand(
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
}

// MARK: - Untagged FETCH group routing (caller holds `lock`)

private extension PipelinedCommandDispatcher {
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
                    let uid = UID(nio: nioUID)
                    guard validateBoundUID(uid, touchedTags: touchedTags) else {
                        group = .dropping
                        return
                    }
                    group = .bound(currentTag: currentTag, touchedTags: touchedTags, uid: uid)
                }
                deliver(response, toTag: currentTag)
            case .dropping, .idle:
                break
        }
    }

    /// The UID attribute can arrive after body data has already been delivered. A
    /// mismatch at that point cannot be unwound, so the whole batch must fail rather
    /// than return bytes that may belong to another request.
    private func validateBoundUID(_ uid: UID, touchedTags: Set<String>) -> Bool {
        let mismatches = entries.filter {
            touchedTags.contains($0.tag) && $0.uid.map { $0 != uid } == true
        }
        guard !mismatches.isEmpty else { return true }

        let bindings = mismatches.map { "\($0.tag)=UID \($0.uid?.value ?? 0)" }
            .joined(separator: ", ")
        failRoutingViolation(
            "FETCH group reported late UID \(uid.value) after delivering body bytes to \(bindings)"
        )
        return false
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
                bindPendingGroup(held: held, uid: uid, section: section, response: response)
            case .bound(let currentTag, var touchedTags, let uid):
                rebindBoundGroup(
                    currentTag: currentTag,
                    touchedTags: &touchedTags,
                    uid: uid,
                    section: section,
                    response: response
                )
            case .dropping:
                break
            case .idle:
                // Streaming without `.start` — tolerate by treating it as its own group.
                group = .pending(held: [], uid: nil)
                bindOrRebind(section: section, response)
        }
    }

    private func bindPendingGroup(
        held: [FetchResponse],
        uid: UID?,
        section: SectionSpecifier?,
        response: FetchResponse
    ) {
        switch bindingDecision(uid: uid, section: section) {
            case .match(let idx):
                let tag = entries[idx].tag
                group = .bound(currentTag: tag, touchedTags: [tag], uid: uid)
                for heldResponse in held {
                    entries[idx].handler.processFetchResponse(heldResponse)
                }
                entries[idx].handler.processFetchResponse(response)
            case .unsolicited:
                dropUnmatchedBodyData()
            case .routingViolation(let error):
                failRoutingViolation(error.description)
                group = .dropping
        }
    }

    private func rebindBoundGroup(
        currentTag: String,
        touchedTags: inout Set<String>,
        uid: UID?,
        section: SectionSpecifier?,
        response: FetchResponse
    ) {
        guard let section else {
            deliverBoundResponse(
                response,
                toTag: currentTag,
                touchedTags: &touchedTags,
                uid: uid
            )
            return
        }

        switch bindingDecision(uid: uid, section: section) {
            case .match(let idx):
                deliverBoundResponse(
                    response,
                    toTag: entries[idx].tag,
                    touchedTags: &touchedTags,
                    uid: uid
                )
            case .unsolicited:
                dropUnmatchedBodyData()
            case .routingViolation(let error):
                failRoutingViolation(error.description)
                group = .dropping
        }
    }

    private func deliverBoundResponse(
        _ response: FetchResponse,
        toTag tag: String,
        touchedTags: inout Set<String>,
        uid: UID?
    ) {
        touchedTags.insert(tag)
        group = .bound(currentTag: tag, touchedTags: touchedTags, uid: uid)
        deliver(response, toTag: tag)
    }

    private func dropUnmatchedBodyData() {
        logger.warning("Dropping untagged FETCH body data that matches no pipelined command")
        group = .dropping
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

    /// Pick the entry a body-bearing group belongs to. Once the server provides a
    /// UID or section that registered commands can verify, a mismatch is never
    /// allowed to degrade to send-order routing.
    private func bindingDecision(uid: UID?, section: SectionSpecifier?) -> PipelinedBindingDecision {
        let candidates = entries.indices.filter { !entries[$0].finishedUntagged }
        guard !candidates.isEmpty else { return .unsolicited }

        if let uid {
            let uidAware = candidates.filter { entries[$0].uid != nil }
            if !uidAware.isEmpty {
                let uidMatches = uidAware.filter { entries[$0].uid == uid }
                guard !uidMatches.isEmpty else { return .unsolicited }
                return sectionDecision(uid: uid, section: section, candidates: uidMatches)
            }
        }

        return sectionDecision(uid: uid, section: section, candidates: candidates)
    }

    private func sectionDecision(
        uid: UID?,
        section: SectionSpecifier?,
        candidates: [Int]
    ) -> PipelinedBindingDecision {
        guard let section else { return .match(candidates[0]) }
        let sectionAware = candidates.filter { entries[$0].expectedSection != nil }
        guard !sectionAware.isEmpty else { return .match(candidates[0]) }
        if let match = sectionAware.first(where: { entries[$0].expectedSection == section }) {
            return .match(match)
        }

        let uidDescription = uid.map { "UID \($0.value) " } ?? ""
        return .routingViolation(PipelinedFetchRoutingError(
            description: "FETCH \(uidDescription)section \(section) matches no pending pipelined request"
        ))
    }

    private func failRoutingViolation(_ message: String) {
        logger.error("\(message)")
        failAllPending(PipelinedFetchRoutingError(description: message))
    }

    /// Fail every pending handler and clear the registry. Caller holds `lock`.
    private func failAllPending(_ error: Error) {
        for entry in entries {
            entry.handler.fail(error)
        }
        entries.removeAll()
        group = .idle
    }
}

extension PipelinedCommandDispatcher {
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
