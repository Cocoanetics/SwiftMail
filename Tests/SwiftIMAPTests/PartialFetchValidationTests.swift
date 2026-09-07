import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("Partial BODY.PEEK validation", .serialized)
struct PartialFetchValidationTests {
    private struct FailureCase {
        let responses: [FetchResponse]
        let identifier: PartialFetchIdentifier
        let expected: PartialFetchError
    }

    @Test("Conflicting UID attributes are rejected")
    func conflictingUIDs() async {
        await assertUIDConflict(
            start: .start(NIOIMAPCore.SequenceNumber(rawValue: 1)),
            uids: [999, 1]
        )
        await assertUIDConflict(
            start: .start(NIOIMAPCore.SequenceNumber(rawValue: 1)),
            uids: [1, 999]
        )
        await assertUIDConflict(
            start: .startUID(NIOIMAPCore.UID(rawValue: 999)),
            uids: [1]
        )
    }

    @Test("Malformed body literals are rejected")
    func malformedBodyLiterals() async {
        let section = SectionSpecifier(part: .init([1]))
        let otherSection = SectionSpecifier(part: .init([2]))
        let start = matchingStart()
        let validBody = bodyResponses(section: section)
        let cases = [
            FailureCase(
                responses: start + [
                    .streamingBegin(kind: .body(section: otherSection, offset: 0), byteCount: 4),
                    .streamingBytes(buffer("data")), .streamingEnd, .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("section or partial origin did not match request")
            ),
            FailureCase(
                responses: start + [
                    .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 5), .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("literal exceeded requested count")
            ),
            FailureCase(
                responses: start + [
                    .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 4),
                    .streamingBytes(buffer("abc")), .streamingBytes(buffer("de")),
                    .streamingEnd, .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("literal exceeded requested count")
            ),
            FailureCase(
                responses: start + Array(validBody.dropLast()) + [
                    .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 0),
                    .streamingEnd, .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("multiple body literals")
            ),
            FailureCase(
                responses: start + [
                    .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 4),
                    .streamingBytes(buffer("abc")), .streamingEnd, .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("literal length did not match declaration")
            )
        ]
        await assertFailures(cases)
    }

    @Test("Unsafe declarations fail before tagged completion")
    func unsafeDeclarationFailsImmediately() async {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Data.self)
        let handler = makeHandler(promise: promise)
        _ = handler.processResponse(.fetch(.start(.init(rawValue: 1))))
        _ = handler.processResponse(.fetch(.simpleAttribute(.uid(.init(rawValue: 1)))))

        let handled = handler.processResponse(.fetch(.streamingBegin(
            kind: .body(section: SectionSpecifier(part: .init([1])), offset: nil),
            byteCount: 33 * 1024 * 1024 + 257
        )))
        loop.run()

        #expect(handled)
        await #expect(throws: PartialFetchError.invalidResponse(
            "section or partial origin did not match request"
        )) {
            _ = try await promise.futureResult.get()
        }
    }

    @Test("Missing and ambiguous message responses are rejected")
    func ambiguousResponses() async {
        let section = SectionSpecifier(part: .init([1]))
        let start = matchingStart()
        let validBody = bodyResponses(section: section)
        let cases = [
            FailureCase(
                responses: start + validBody + start + validBody,
                identifier: .uid(1),
                expected: .invalidResponse("multiple matching FETCH responses")
            ),
            FailureCase(
                responses: start + [
                    .simpleAttribute(.nilBody(.body(section: section, offset: 0))), .finish
                ],
                identifier: .uid(1),
                expected: .invalidResponse("requested body section was NIL")
            ),
            FailureCase(
                responses: start + [.finish],
                identifier: .uid(1),
                expected: .invalidResponse("missing or ambiguous requested body")
            ),
            FailureCase(
                responses: [
                    .start(.init(rawValue: 1)),
                    .simpleAttribute(.uid(.init(rawValue: 999)))
                ] + validBody,
                identifier: .uid(1),
                expected: .messageNotFound
            ),
            FailureCase(
                responses: [.start(.init(rawValue: 2))] + validBody,
                identifier: .sequenceNumber(1),
                expected: .messageNotFound
            )
        ]
        await assertFailures(cases)
    }

    private func matchingStart() -> [FetchResponse] {
        [.start(.init(rawValue: 1)), .simpleAttribute(.uid(.init(rawValue: 1)))]
    }

    private func bodyResponses(section: SectionSpecifier) -> [FetchResponse] {
        [
            .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 4),
            .streamingBytes(buffer("data")), .streamingEnd, .finish
        ]
    }

    private func assertFailures(_ cases: [FailureCase]) async {
        for testCase in cases {
            await assertPartialFailure(
                testCase.responses,
                identifier: testCase.identifier,
                expected: testCase.expected
            )
        }
    }

    @Test("Opaque bytes are returned without text conversion")
    func preservesOpaqueBytes() async throws {
        let section = SectionSpecifier(part: .init([1]))
        let bytes = Data([0x00, 0xff, 0x01, 0xfe])
        let result = try await partialHandlerResult([
            .start(.init(rawValue: 1)),
            .simpleAttribute(.uid(.init(rawValue: 1))),
            .streamingBegin(kind: .body(section: section, offset: 0), byteCount: bytes.count),
            .streamingBytes(buffer(bytes)),
            .streamingEnd,
            .finish
        ]).get()
        #expect(result == bytes)
    }

    @Test("Connection termination responses fail the partial command")
    func connectionTerminationResponses() async {
        let responses: [Response] = [
            .untagged(.conditionalState(.bye(ResponseText(text: "test shutdown")))),
            .fatal(ResponseText(text: "test decoder failure"))
        ]
        for response in responses {
            let loop = EmbeddedEventLoop()
            let promise = loop.makePromise(of: Data.self)
            let handler = makeHandler(promise: promise)
            #expect(handler.processResponse(response))
            loop.run()
            await #expect(throws: IMAPError.self) {
                _ = try await promise.futureResult.get()
            }
        }
    }

    private func assertUIDConflict(start: FetchResponse, uids: [UInt32]) async {
        let section = SectionSpecifier(part: .init([1]))
        var responses: [FetchResponse] = [
            start,
            .streamingBegin(kind: .body(section: section, offset: 0), byteCount: 4),
            .streamingBytes(buffer("evil")),
            .streamingEnd
        ]
        responses += uids.map { .simpleAttribute(.uid(.init(rawValue: $0))) }
        responses.append(.finish)
        await assertPartialFailure(
            responses,
            expected: .invalidResponse("conflicting UID attributes")
        )
    }

    private func assertPartialFailure(
        _ responses: [FetchResponse],
        identifier: PartialFetchIdentifier = .uid(1),
        expected: PartialFetchError
    ) async {
        await #expect(throws: expected) {
            _ = try await partialHandlerResult(responses, identifier: identifier).get()
        }
    }

    private func partialHandlerResult(
        _ responses: [FetchResponse],
        identifier: PartialFetchIdentifier = .uid(1)
    ) async -> Result<Data, Error> {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Data.self)
        let handler = makeHandler(promise: promise, identifier: identifier)
        for response in responses { _ = handler.processResponse(.fetch(response)) }
        _ = handler.processResponse(.tagged(TaggedResponse(
            tag: "P001",
            state: .ok(ResponseText(text: "completed"))
        )))
        loop.run()
        do {
            return .success(try await promise.futureResult.get())
        } catch {
            return .failure(error)
        }
    }

    private func makeHandler(
        promise: EventLoopPromise<Data>,
        identifier: PartialFetchIdentifier = .uid(1)
    ) -> FetchPartHandler {
        FetchPartHandler(
            commandTag: "P001",
            promise: promise,
            partialRequest: .init(
                identifier: identifier,
                section: SectionSpecifier(part: .init([1])),
                offset: 0,
                count: 4
            )
        )
    }

    private func buffer(_ string: String) -> ByteBuffer {
        buffer(Data(string.utf8))
    }

    private func buffer(_ data: Data) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}

extension PartialFetchValidationTests {
    @Test("Concrete responses match wildcard identifiers")
    func wildcardIdentifiers() async throws {
        let section = SectionSpecifier(part: .init([1]))
        let uidResult = try await partialCommandResult(
            identifier: UID.latest,
            responses: matchingStart() + bodyResponses(section: section)
        ).get()
        let sequenceResult = try await partialCommandResult(
            identifier: SwiftMail.SequenceNumber.latest,
            responses: [.start(.init(rawValue: 27))] + bodyResponses(section: section)
        ).get()

        #expect(uidResult == Data("data".utf8))
        #expect(sequenceResult == Data("data".utf8))
    }

    @Test("Identified unrelated body groups are discarded")
    func ignoresUnrelatedBodyGroups() async throws {
        let section = SectionSpecifier(part: .init([1]))
        let otherSection = SectionSpecifier(part: .init([2]))
        let responses: [FetchResponse] = [
            .start(.init(rawValue: 7)),
            .simpleAttribute(.uid(.init(rawValue: 99))),
            .streamingBegin(kind: .body(section: otherSection, offset: nil), byteCount: 4),
            .streamingBytes(buffer("junk")),
            .streamingEnd,
            .finish
        ] + matchingStart() + bodyResponses(section: section)

        let result = try await partialHandlerResult(responses).get()
        #expect(result == Data("data".utf8))
    }

    @Test("Unrelated untagged responses do not complete the handler")
    func ignoresUnrelatedUntaggedResponse() async throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Data.self)
        let handler = makeHandler(promise: promise)
        let unrelated = Response.untagged(.mailboxData(.sort([2, 1], 1)))
        #expect(!handler.processResponse(unrelated))

        for response in matchingStart() + bodyResponses(
            section: SectionSpecifier(part: .init([1]))
        ) {
            _ = handler.processResponse(.fetch(response))
        }
        _ = handler.processResponse(.tagged(TaggedResponse(
            tag: "P001",
            state: .ok(ResponseText(text: "completed"))
        )))
        loop.run()
        #expect(try await promise.futureResult.get() == Data("data".utf8))
    }

    private func partialCommandResult<T: SwiftMail.MessageIdentifier>(
        identifier: T,
        responses: [FetchResponse]
    ) async -> Result<Data, Error> {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: Data.self)
        let command = FetchMessagePartCommand(
            identifier: identifier,
            section: Section([1]),
            range: 0...3
        )
        let handler = command.makeHandler(commandTag: "P001", promise: promise)
        for response in responses { _ = handler.processResponse(.fetch(response)) }
        _ = handler.processResponse(.tagged(TaggedResponse(
            tag: "P001",
            state: .ok(ResponseText(text: "completed"))
        )))
        loop.run()
        do {
            return .success(try await promise.futureResult.get())
        } catch {
            return .failure(error)
        }
    }
}
