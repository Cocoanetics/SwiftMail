import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private typealias UID = SwiftMail.UID
private typealias Helpers = ExtendedSearchHandlerTestHelpers

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ExtendedSearchHandlerFallbackTests {

    // MARK: - Fallback: plain SEARCH response

    @Test
    func testFallbackPlainSearch() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A003", promise: promise)
        try await channel.pipeline.addHandler(handler)

        try await Helpers.sendSearchCommand(on: channel, tag: "A003", useUID: true, useEsearch: false)

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
        #expect(result.ordered?.map(\.value) == [4, 7, 10])
    }

    @Test
    func testFallbackSortPreservesServerOrder() async throws {
        let channel = NIOAsyncTestingChannel()
        let promise = channel.eventLoop.makePromise(of: ExtendedSearchResult<UID>.self)
        let handler = ExtendedSearchHandler<UID>(commandTag: "A003B", promise: promise)
        _ = handler.processResponse(.untagged(.mailboxData(.sort([10, 7, 4], 123))))
        handler.handleTaggedOKResponse(.init(tag: "A003B", state: .ok(.init(text: "Sort complete"))))

        let result = try await promise.futureResult.get()

        #expect(result.count == 3)
        #expect(result.ordered?.map(\.value) == [10, 7, 4])
        #expect(result.all?.toArray().map(\.value) == [4, 7, 10])
    }
}
