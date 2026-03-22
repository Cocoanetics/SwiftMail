import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private typealias UID = SwiftMail.UID
private typealias SequenceNumber = SwiftMail.SequenceNumber

struct ExtendedSearchHandlerTests {

    // MARK: - Helpers

    private func sendSearchCommand(on channel: NIOAsyncTestingChannel, tag: String, useUID: Bool, useEsearch: Bool, partialRange: NIOIMAPCore.PartialRange? = nil) async throws {
        let key = NIOIMAPCore.SearchKey.all
        var returnOptions: [NIOIMAPCore.SearchReturnOption] = []
        if useEsearch {
            if let range = partialRange {
                returnOptions = [.count, .min, .max, .partial(range)]
            } else {
                returnOptions = [.count, .min, .max, .all]
            }
        }
        let command: NIOIMAPCore.Command = useUID
            ? .uidSearch(key: key, returnOptions: returnOptions)
            : .search(key: key, returnOptions: returnOptions)
        let tagged = NIOIMAPCore.TaggedCommand(tag: tag, command: command)
        let wrapped = IMAPClientHandler.OutboundIn.part(NIOIMAPCore.CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)
        _ = try await channel.readOutbound(as: ByteBuffer.self)
    }

    // MARK: - ESEARCH response (UID search)

    @Test
    func testEsearchResponseUID() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        try await sendSearchCommand(on: channel, tag: "A001", useUID: true, useEsearch: true)

        var esearchResponse = channel.allocator.buffer(capacity: 64)
        esearchResponse.writeString("* ESEARCH (TAG \"A001\") UID COUNT 3 MIN 4 MAX 10 ALL 4,7,10\r\n")
        try await channel.writeInbound(esearchResponse)

        var taggedOK = channel.allocator.buffer(capacity: 64)
        taggedOK.writeString("A001 OK Extended search completed\r\n")
        try await channel.writeInbound(taggedOK)

        let result = try await promise.futureResult.get()

        #expect(result.count == 3)
        #expect(result.min?.value == 4)
        #expect(result.max?.value == 10)

        if let all = result.all {
            let values = Set(all.toArray().map { $0.value })
            #expect(values == Set([UInt32(4), UInt32(7), UInt32(10)]))
        } else {
            Issue.record("Expected non-nil 'all' in ESEARCH result")
        }
    }

    // MARK: - ESEARCH response (sequence number search)

    @Test
    func testEsearchResponseSequenceNumber() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<SequenceNumber>.self)
        let handler = ExtendedSearchHandler<SequenceNumber>(commandTag: "A002", promise: promise)
        try await channel.pipeline.addHandler(handler)

        try await sendSearchCommand(on: channel, tag: "A002", useUID: false, useEsearch: true)

        var esearchResponse = channel.allocator.buffer(capacity: 64)
        esearchResponse.writeString("* ESEARCH COUNT 2 MIN 1 MAX 5 ALL 1,5\r\n")
        try await channel.writeInbound(esearchResponse)

        var taggedOK = channel.allocator.buffer(capacity: 64)
        taggedOK.writeString("A002 OK Search complete\r\n")
        try await channel.writeInbound(taggedOK)

        let result = try await promise.futureResult.get()

        #expect(result.count == 2)
        #expect(result.min?.value == 1)
        #expect(result.max?.value == 5)
        #expect(result.all != nil)
    }

    // MARK: - Fallback: plain SEARCH response

    @Test
    func testFallbackPlainSearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A003", promise: promise)
        try await channel.pipeline.addHandler(handler)

        try await sendSearchCommand(on: channel, tag: "A003", useUID: true, useEsearch: false)

        var searchResponse = channel.allocator.buffer(capacity: 32)
        searchResponse.writeString("* SEARCH 4 7 10\r\n")
        try await channel.writeInbound(searchResponse)

        var taggedOK = channel.allocator.buffer(capacity: 32)
        taggedOK.writeString("A003 OK Search complete\r\n")
        try await channel.writeInbound(taggedOK)

        let result = try await promise.futureResult.get()

        #expect(result.count == 3)
        #expect(result.min?.value == 4)
        #expect(result.max?.value == 10)
        #expect(result.all != nil)
    }

    // MARK: - Empty ESEARCH result

    @Test
    func testEsearchEmptyResult() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A004", promise: promise)
        try await channel.pipeline.addHandler(handler)

        try await sendSearchCommand(on: channel, tag: "A004", useUID: true, useEsearch: true)

        var esearchResponse = channel.allocator.buffer(capacity: 64)
        esearchResponse.writeString("* ESEARCH (TAG \"A004\") UID COUNT 0\r\n")
        try await channel.writeInbound(esearchResponse)

        var taggedOK = channel.allocator.buffer(capacity: 32)
        taggedOK.writeString("A004 OK Search complete\r\n")
        try await channel.writeInbound(taggedOK)

        let result = try await promise.futureResult.get()

        #expect(result.count == 0)
        #expect(result.min == nil)
        #expect(result.max == nil)
        #expect(result.all == nil)
    }

    // MARK: - Command wire format

    @Test
    func testCommandWireFormatWithEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C001")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(wireString.contains("COUNT"))
        #expect(wireString.contains("MIN"))
        #expect(wireString.contains("MAX"))
        #expect(wireString.contains("ALL"))
    }

    @Test
    func testCommandWireFormatWithoutEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(criteria: [SearchCriteria.all], useEsearch: false)
        let tagged = command.toTaggedCommand(tag: "C002")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(!wireString.contains("RETURN"))
    }

    @Test
    func testCommandWireFormatSequenceNumberWithEsearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<SequenceNumber>(criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C003")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(!wireString.contains("UID SEARCH"))
        #expect(wireString.contains("SEARCH"))
        #expect(wireString.contains("RETURN"))
    }

    @Test
    func testIdentifierSetScopeIsIncludedInUIDSearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let ids = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
        let command = ExtendedSearchCommand<UID>(identifierSet: ids, criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C005")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("UID 1:3") || wireString.contains("UID 1,2,3"))
    }

    @Test
    func testNoIdentifierSetSearchesEntireMailbox() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let command = ExtendedSearchCommand<UID>(identifierSet: nil, criteria: [SearchCriteria.all], useEsearch: true)
        let tagged = command.toTaggedCommand(tag: "C006")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(!wireString.contains("UID 1"))
    }

    // MARK: - PARTIAL response parsing

    @Test
    func testEsearchPartialResponse() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A007", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let partialRange = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...100))
        try await sendSearchCommand(on: channel, tag: "A007", useUID: true, useEsearch: true, partialRange: partialRange)

        var esearchResponse = channel.allocator.buffer(capacity: 64)
        esearchResponse.writeString("* ESEARCH (TAG \"A007\") UID COUNT 3 PARTIAL (1:100 4,7,10)\r\n")
        try await channel.writeInbound(esearchResponse)

        var taggedOK = channel.allocator.buffer(capacity: 32)
        taggedOK.writeString("A007 OK Extended search completed\r\n")
        try await channel.writeInbound(taggedOK)

        let result = try await promise.futureResult.get()

        #expect(result.count == 3)
        #expect(result.all == nil)

        if let partial = result.partial {
            let values = Set(partial.results.toArray().map { $0.value })
            #expect(values == Set([UInt32(4), UInt32(7), UInt32(10)]))
            if case .first(let range) = partial.range {
                #expect(range.range.lowerBound == NIOIMAPCore.SequenceNumber(1))
                #expect(range.range.upperBound == NIOIMAPCore.SequenceNumber(100))
            } else {
                Issue.record("Expected .first partial range")
            }
        } else {
            Issue.record("Expected non-nil 'partial' in ESEARCH result")
        }
    }

    // MARK: - PARTIAL wire format

    @Test
    func testCommandWireFormatWithPartial() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let partialRange = NIOIMAPCore.PartialRange.first(NIOIMAPCore.SequenceRange(1...100))
        let command = ExtendedSearchCommand<UID>(criteria: [SearchCriteria.unseen], useEsearch: true, partialRange: partialRange)
        let tagged = command.toTaggedCommand(tag: "C007")
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        try await channel.writeAndFlush(wrapped)

        guard var outbound = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wireString = outbound.readString(length: outbound.readableBytes) ?? ""

        #expect(wireString.contains("UID SEARCH"))
        #expect(wireString.contains("RETURN"))
        #expect(wireString.contains("PARTIAL"))
        #expect(wireString.contains("1:100"))
        #expect(!wireString.contains("ALL"))
    }
}
