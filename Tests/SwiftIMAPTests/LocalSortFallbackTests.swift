import Foundation
import NIO
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalSortFallbackTests {
    @Test
    func sortsDatesDescendingLocally() throws {
        let infos: [MessageInfo] = [
            MessageInfo(
                sequenceNumber: SequenceNumber(1),
                uid: UID(11),
                subject: "First",
                from: "\"Alice\" <alice@example.com>",
                date: Date(timeIntervalSince1970: 100),
                internalDate: Date(timeIntervalSince1970: 100)
            ),
            MessageInfo(
                sequenceNumber: SequenceNumber(2),
                uid: UID(22),
                subject: "Second",
                from: "\"Bob\" <bob@example.com>",
                date: Date(timeIntervalSince1970: 300),
                internalDate: Date(timeIntervalSince1970: 300)
            ),
            MessageInfo(
                sequenceNumber: SequenceNumber(3),
                uid: UID(33),
                subject: "Third",
                from: "\"Carol\" <carol@example.com>",
                date: Date(timeIntervalSince1970: 200),
                internalDate: Date(timeIntervalSince1970: 200)
            ),
        ]

        let result = try LocalSortFallback.makeExtendedSearchResult(
            from: infos,
            as: UID.self,
            sortCriteria: [.descending(.date)]
        )

        #expect(result.count == 3)
        #expect(result.ordered?.map(\.value) == [22, 33, 11])
    }
}
