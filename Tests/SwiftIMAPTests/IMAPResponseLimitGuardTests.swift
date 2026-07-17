import Testing
import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Logging
@testable import SwiftMail

/// Does `bodySizeLimit` bound the whole FETCH response, as documented — not just one section?
///
/// ## The gap these cover
/// `ResponseParser` checks each streaming section on its own and keeps no total, while
/// `FetchPartHandler` and `PipelinedFetchPartHandler` append every section into one `Data`. With
/// `bodySizeLimit: 64 MiB`, a server could send any number of 50 MiB sections in a single FETCH:
/// each passes the parser's check, all of them land in one buffer. The documented guard bounded
/// nothing.
///
/// These tests drive the guard with the response sequence a hostile server would produce, so the
/// bypass is reproducible. Remove `IMAPResponseLimitGuard` from the pipeline and
/// `manySmallSectionsExceedTheTotal` goes green in the wrong direction — it stops throwing.
@Suite("Body size limit covers the whole FETCH response", .timeLimit(.minutes(1)))
struct IMAPResponseLimitGuardTests {

    /// - Note: The channel is **connected** before use. An `EmbeddedChannel` reports
    ///   `isActive == false` until it is, which would make every "the guard closes the channel"
    ///   assertion below pass for the wrong reason — green because the channel was never open,
    ///   not because the guard closed it. A test that cannot fail proves nothing.
    private func makeChannel(bodySizeLimit: UInt64) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            IMAPResponseLimitGuard(
                bodySizeLimit: bodySizeLimit,
                logger: Logger(label: "test"),
                connectionContext: "[test]"
            )
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        #expect(channel.isActive, "Precondition: the channel has to be open for a close to mean anything")
        return channel
    }

    private func write(_ response: Response, to channel: EmbeddedChannel) throws {
        try channel.writeInbound(response)
    }

    /// 🔴 The bypass: every section is legal on its own, the sum is not.
    @Test("Many individually legal sections still exceed the response total")
    func manySmallSectionsExceedTheTotal() throws {
        let channel = try makeChannel(bodySizeLimit: 100)
        try write(.fetch(.start(SequenceNumber(1))), to: channel)

        // Four sections of 30 bytes: each far below 100, together 120.
        try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 30)), to: channel)
        try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 30)), to: channel)
        try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 30)), to: channel)

        #expect(throws: ExceededResponseBodySizeError.self) {
            try channel.writeInbound(
                Response.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 30))
            )
        }
        // A peer that sends this has proven itself; the connection must not stay open.
        #expect(channel.isActive == false, "A limit violation has to close the connection")
    }

    /// The control: the same shape, just under the ceiling, must pass through untouched.
    /// Without this, the test above would also pass if the guard rejected everything.
    @Test("Sections that stay under the total pass through")
    func sectionsUnderTheTotalPass() throws {
        let channel = try makeChannel(bodySizeLimit: 100)
        try write(.fetch(.start(SequenceNumber(1))), to: channel)
        try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 40)), to: channel)
        try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 40)), to: channel)
        try write(.fetch(.finish), to: channel)

        #expect(channel.isActive)
        // Everything must arrive on the far side — the guard observes, it does not swallow.
        var seen = 0
        while try channel.readInbound(as: Response.self) != nil { seen += 1 }
        #expect(seen == 4)
    }

    /// The total is *per response*. Two messages of 80 bytes each are not a 160-byte violation —
    /// otherwise a long mailbox sync would trip the guard for doing exactly what it should.
    @Test("The total resets for each message in the same FETCH")
    func totalResetsPerMessage() throws {
        let channel = try makeChannel(bodySizeLimit: 100)

        for sequence in 1...5 {
            try write(.fetch(.start(SequenceNumber(rawValue: UInt32(sequence)))), to: channel)
            try write(.fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: 80)), to: channel)
            try write(.fetch(.finish), to: channel)
        }

        #expect(channel.isActive, "Five legal messages in a row are not a violation")
    }

    /// `.max` means unbounded — the guard must not add a ceiling where the caller asked for none.
    @Test("The unbounded default lets everything through")
    func unboundedDefaultPassesEverything() throws {
        let channel = try makeChannel(bodySizeLimit: .max)
        try write(.fetch(.start(SequenceNumber(1))), to: channel)
        for _ in 0..<50 {
            try write(
                .fetch(.streamingBegin(kind: .body(section: .text, offset: nil), byteCount: Int.max / 100)),
                to: channel
            )
        }
        #expect(channel.isActive)
    }
}

/// Do parser-limit errors fail closed?
///
/// They did not. During IDLE, an oversized body or an over-limit attribute count made
/// `IMAPClientHandler` fire an error; `IdleHandler.errorCaught` only failed a private promise
/// that nothing was awaiting until a later DONE. The decoder kept the rejected response and
/// appended every subsequent read to it — the post-decode buffer cap is skipped when decoding
/// throws — so a malicious peer could keep growing memory while the caller's `AsyncStream` hung.
@Suite("Parser limit violations close the connection", .timeLimit(.minutes(1)))
struct IMAPLimitViolationFailsClosedTests {

    /// - Note: Connected first — see the note in ``IMAPResponseLimitGuardTests``. Without it
    ///   these assertions would be green because the channel was never open.
    private func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            IMAPResponseLimitGuard(
                bodySizeLimit: .max,
                logger: Logger(label: "test"),
                connectionContext: "[test]"
            )
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        #expect(channel.isActive, "Precondition: the channel has to be open for a close to mean anything")
        return channel
    }

    @Test("An oversized single body closes the channel")
    func oversizedBodyCloses() throws {
        let channel = try makeChannel()
        channel.pipeline.fireErrorCaught(ExceededMaximumBodySizeError(actualCount: 100, maximumCount: 10))
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }

    @Test("An over-limit attribute count closes the channel")
    func tooManyAttributesCloses() throws {
        let channel = try makeChannel()
        channel.pipeline.fireErrorCaught(
            ExceededMaximumMessageAttributesError(actualCount: 100, maximumCount: 10)
        )
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }

    @Test("An oversized literal closes the channel")
    func oversizedLiteralCloses() throws {
        let channel = try makeChannel()
        channel.pipeline.fireErrorCaught(ExceededLiteralSizeLimitError(actualCount: 8192, maximumCount: 4096))
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false)
    }

    /// The one that catches what the raw-error tests above cannot: `ResponseDecoder` wraps every
    /// parser error in `IMAPDecoderError` before `IMAPClientHandler` fires it down the pipeline.
    /// The tests above inject the bare types, so a guard that never unwrapped the wrapper — the
    /// shipped defect — passed all of them while never firing in production. This one feeds raw
    /// wire bytes through the real decoder with the real pipeline order, so the error arrives
    /// exactly as a hostile server would deliver it.
    @Test("A parser-limit error raised by the real decoder still closes the channel")
    func decoderWrappedViolationCloses() throws {
        let channel = EmbeddedChannel()
        let limits = IMAPParserLimits(bodySizeLimit: 10)
        try channel.pipeline.syncOperations.addHandlers([
            IMAPClientHandler(parserOptions: limits.makeParserOptions(bufferLimit: 1024)),
            IMAPResponseLimitGuard(
                bodySizeLimit: limits.bodySizeLimit,
                logger: Logger(label: "test"),
                connectionContext: "[test]"
            )
        ])
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        #expect(channel.isActive, "Precondition: the channel has to be open for a close to mean anything")

        // The parser's state machine wants a greeting before anything else; without it the FETCH
        // below fails as a plain syntax error, which the guard rightly ignores.
        var greeting = channel.allocator.buffer(capacity: 16)
        greeting.writeString("* OK ready\r\n")
        try channel.writeInbound(greeting)

        // A FETCH declaring a 100-byte body against a 10-byte limit. The parser rejects the
        // declaration itself, so the body bytes never need to follow.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("* 1 FETCH (BODY[TEXT] {100}\r\n")
        #expect(throws: Error.self) {
            try channel.writeInbound(buffer)
        }
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == false, "A violation from the real decoder has to close the connection")
    }

    /// Deliberately narrow. `errorCaught` sees unrelated failures too, and tearing the connection
    /// down for those would change behaviour far outside this feature.
    @Test("An unrelated error does not close the channel")
    func unrelatedErrorDoesNotClose() throws {
        let channel = try makeChannel()
        struct SomeOtherError: Error {}
        channel.pipeline.fireErrorCaught(SomeOtherError())
        channel.embeddedEventLoop.run()
        #expect(channel.isActive, "Only limit violations are grounds for closing")
    }
}
