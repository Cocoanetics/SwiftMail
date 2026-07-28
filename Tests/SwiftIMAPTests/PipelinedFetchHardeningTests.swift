// PipelinedFetchHardeningTests.swift
// Content-verified routing, unsolicited-FETCH suppression, drain policy, and
// timeout scaling for pipelined part fetches.

import Foundation
import Testing
import NIO
import NIOEmbedded
import NIOConcurrencyHelpers
@preconcurrency import NIOIMAP
import NIOIMAPCore
@testable import SwiftMail

/// A pipelined command as the dispatcher sees it registered: tag plus the
/// expected UID/section used for content-verified routing.
private struct ExpectedPart {
    let tag: String
    let uid: SwiftMail.UID?
    let section: Section?
}

@Suite("PipelinedCommandDispatcher content routing")
struct PipelinedDispatcherContentRoutingTests {

    /// Build a `* FETCH (BODY[...] {n})` streaming-bytes response.
    private func bytes(_ text: String) -> Response {
        var buf = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buf.writeString(text)
        return .fetch(.streamingBytes(buf))
    }

    private func taggedOK(_ tag: String) -> Response {
        .tagged(TaggedResponse(tag: tag, state: .ok(ResponseText(text: "completed"))))
    }

    private func sectionSpec(_ components: [Int]) -> SectionSpecifier {
        SectionSpecifier(part: SectionSpecifier.Part(components))
    }

    private func beginBody(_ components: [Int], byteCount: Int) -> Response {
        .fetch(.streamingBegin(
            kind: .body(section: sectionSpec(components), offset: nil),
            byteCount: byteCount
        ))
    }

    private func uidAttr(_ value: UInt32) -> Response {
        .fetch(.simpleAttribute(.uid(NIOIMAPCore.UID(rawValue: value))))
    }

    private func flagsAttr() -> Response {
        .fetch(.simpleAttribute(.flags([.seen])))
    }

    /// Drive the dispatcher through an `EmbeddedChannel` with a scripted server
    /// response stream, registering each command with its expected UID/section as
    /// production does. Returns each part's resolved bytes as UTF-8, aligned to
    /// `requests`; nil means that part's promise never resolved.
    private func resolveParts(requests: [ExpectedPart], stream: [Response]) throws -> [String?] {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let dispatcher = PipelinedCommandDispatcher()
        try channel.pipeline.syncOperations.addHandler(dispatcher)

        // EmbeddedEventLoop fires future callbacks inline when run — capture results
        // synchronously into a box so the test stays single-threaded.
        final class Box: @unchecked Sendable { var results: [Data?] = [] }
        let box = Box(); box.results = Array(repeating: nil, count: requests.count)
        for (index, request) in requests.enumerated() {
            let promise = loop.makePromise(of: Data.self)
            promise.futureResult.whenSuccess { box.results[index] = $0 }
            dispatcher.register(
                tag: request.tag,
                handler: PipelinedFetchPartHandler(promise: promise),
                uid: request.uid,
                expectedSection: request.section.map {
                    SectionSpecifier(part: SectionSpecifier.Part($0.components))
                }
            )
        }

        for response in stream {
            try channel.writeInbound(response)
        }
        loop.run()
        _ = try? channel.finish()

        return box.results.map { $0.flatMap { String(bytes: $0, encoding: .utf8) } }
    }

    /// THE regression this hardening exists for: RFC 3501 §7.4.2 lets the server
    /// broadcast `* n FETCH (FLAGS (\Seen))` at any time — e.g. another client
    /// marking the message read mid-burst. Pre-fix, that attribute-only group
    /// consumed the oldest pending command's routing slot: every subsequent part's
    /// bytes shifted one command over and the corruption was cached as success.
    @Test("Unsolicited flag-update FETCH between body groups must not shift part routing")
    func unsolicitedFlagsFetchDoesNotShiftRouting() throws {
        let requests = [
            ExpectedPart(tag: "A001", uid: nil, section: nil),
            ExpectedPart(tag: "A002", uid: nil, section: nil)
        ]
        let stream: [Response] = [
            .fetch(.start(.init(3))), flagsAttr(), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("PLAINTEXT"), .fetch(.finish),
            .fetch(.start(.init(3))), flagsAttr(), .fetch(.finish),
            .fetch(.start(.init(1))), bytes("<html>HI</html>"), .fetch(.finish),
            taggedOK("A001"), taggedOK("A002")
        ]
        let parts = try resolveParts(requests: requests, stream: stream)
        #expect(parts == ["PLAINTEXT", "<html>HI</html>"])
    }

    /// Sections of one UID arriving in the opposite order from the send order must
    /// route by content (UID + section), not by send order.
    @Test("Out-of-order section responses route by UID and section")
    func outOfOrderSectionsRouteByContent() throws {
        let requests = [
            ExpectedPart(tag: "A001", uid: SwiftMail.UID(9), section: Section([1])),
            ExpectedPart(tag: "A002", uid: SwiftMail.UID(9), section: Section([2]))
        ]
        let stream: [Response] = [
            .fetch(.start(.init(1))), uidAttr(9), beginBody([2], byteCount: 3),
            bytes("TWO"), .fetch(.streamingEnd), .fetch(.finish),
            .fetch(.start(.init(1))), uidAttr(9), beginBody([1], byteCount: 3),
            bytes("ONE"), .fetch(.streamingEnd), .fetch(.finish),
            taggedOK("A001"), taggedOK("A002")
        ]
        let parts = try resolveParts(requests: requests, stream: stream)
        #expect(parts == ["ONE", "TWO"])
    }

    /// A server may satisfy several pipelined commands for one message inside a
    /// single untagged FETCH group. Each streamed section must reach its own entry.
    @Test("Single group carrying both sections routes each section to its own handler")
    func combinedGroupRoutesSectionsIndividually() throws {
        let requests = [
            ExpectedPart(tag: "A001", uid: SwiftMail.UID(9), section: Section([1])),
            ExpectedPart(tag: "A002", uid: SwiftMail.UID(9), section: Section([2]))
        ]
        let stream: [Response] = [
            .fetch(.start(.init(1))), uidAttr(9),
            beginBody([1], byteCount: 3), bytes("ONE"), .fetch(.streamingEnd),
            beginBody([2], byteCount: 3), bytes("TWO"), .fetch(.streamingEnd),
            .fetch(.finish),
            taggedOK("A001"), taggedOK("A002")
        ]
        let parts = try resolveParts(requests: requests, stream: stream)
        #expect(parts == ["ONE", "TWO"])
    }

    /// A body-bearing group whose UID matches no pipelined command is unsolicited;
    /// its bytes must be dropped, not delivered to a pending command.
    @Test("Body-bearing group for an unrequested UID is dropped without consuming a slot")
    func unrequestedUIDBodyGroupIsDropped() throws {
        let requests = [
            ExpectedPart(tag: "A001", uid: SwiftMail.UID(9), section: Section([1]))
        ]
        let stream: [Response] = [
            .fetch(.start(.init(7))), uidAttr(999), beginBody([1], byteCount: 4),
            bytes("EVIL"), .fetch(.streamingEnd), .fetch(.finish),
            .fetch(.start(.init(1))), uidAttr(9), beginBody([1], byteCount: 4),
            bytes("GOOD"), .fetch(.streamingEnd), .fetch(.finish),
            taggedOK("A001")
        ]
        let parts = try resolveParts(requests: requests, stream: stream)
        #expect(parts == ["GOOD"])
    }
}

@Suite("PipelinedFetch drain and timeout")
struct PipelinedFetchDrainTests {

    private func makeConnection(group: EventLoopGroup) -> IMAPConnection {
        IMAPConnection(
            host: "localhost",
            port: 143,
            useTLS: false,
            group: group,
            loggerLabel: "test.drain",
            outboundLabel: "test.drain.out",
            inboundLabel: "test.drain.in",
            connectionID: "test",
            connectionRole: "test"
        )
    }

    private func request(_ tag: String, uid: UInt32, section: [Int]) -> IMAPConnection.TaggedFetchRequest {
        IMAPConnection.TaggedFetchRequest(tag: tag, uid: SwiftMail.UID(uid), section: Section(section))
    }

    @Test("All-failed batch surfaces the first failure instead of an empty success")
    func allFailedBatchSurfacesFirstFailure() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = makeConnection(group: group)
        let loop = group.next()
        let promises = [loop.makePromise(of: Data.self), loop.makePromise(of: Data.self)]
        promises[0].fail(IMAPError.timeout)
        promises[1].fail(IMAPError.connectionFailed("dropped"))

        let drain = await connection.drainPipelinedFetchFutures(
            tagToRequest: [request("A001", uid: 9, section: [1]), request("A002", uid: 9, section: [2])],
            futures: promises.map(\.futureResult)
        )

        #expect(drain.results.isEmpty)
        #expect(drain.failureCount == 2)
        #expect(drain.firstLimitViolation == nil)
        if case .timeout = drain.firstFailure as? IMAPError {} else {
            Issue.record("Expected the first failure (timeout) to be surfaced")
        }
    }

    @Test("Partial failure keeps successful results and records the failure")
    func partialFailureKeepsResults() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = makeConnection(group: group)
        let loop = group.next()
        let promises = [loop.makePromise(of: Data.self), loop.makePromise(of: Data.self)]
        promises[0].succeed(Data("ONE".utf8))
        promises[1].fail(IMAPError.timeout)

        let drain = await connection.drainPipelinedFetchFutures(
            tagToRequest: [request("A001", uid: 9, section: [1]), request("A002", uid: 9, section: [2])],
            futures: promises.map(\.futureResult)
        )

        #expect(drain.results.count == 1)
        #expect(drain.results.first.map { String(bytes: $0.data, encoding: .utf8) } == "ONE")
        #expect(drain.failureCount == 1)
        #expect(drain.firstFailure != nil)
    }

    @Test("Limit violations are recorded separately from ordinary failures")
    func limitViolationRecordedSeparately() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = makeConnection(group: group)
        let loop = group.next()
        let promises = [loop.makePromise(of: Data.self), loop.makePromise(of: Data.self)]
        promises[0].fail(IMAPError.timeout)
        promises[1].fail(ExceededResponseBodySizeError(accumulatedCount: 10, maximumCount: 5))

        let drain = await connection.drainPipelinedFetchFutures(
            tagToRequest: [request("A001", uid: 9, section: [1]), request("A002", uid: 9, section: [2])],
            futures: promises.map(\.futureResult)
        )

        #expect(drain.firstLimitViolation != nil)
        #expect(drain.firstFailure != nil)
        #expect(drain.results.isEmpty)
    }

    @Test("Default batch timeout scales with part count and is capped")
    func defaultTimeoutScalesWithPartCount() {
        #expect(IMAPConnection.defaultPipelinedFetchTimeout(partCount: 1) == 60)
        #expect(IMAPConnection.defaultPipelinedFetchTimeout(partCount: 2) == 90)
        #expect(IMAPConnection.defaultPipelinedFetchTimeout(partCount: 4) == 150)
        #expect(IMAPConnection.defaultPipelinedFetchTimeout(partCount: 20) == 300)
    }
}
