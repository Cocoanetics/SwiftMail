import Foundation
import Testing
@testable import SwiftMail
import NIOIMAPCore
import NIO

/// Tests that BODYSTRUCTURE octet counts surface as MessagePart.size.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MessagePartSizeTests {

    private func fields(octetCount: Int) -> BodyStructure.Fields {
        BodyStructure.Fields(parameters: [:], id: nil, contentDescription: nil, encoding: nil, octetCount: octetCount)
    }

    @Test func singlepartCarriesOctetCountAsSize() {
        let basic = BodyStructure.Singlepart(
            kind: .basic(.init(topLevel: .application, sub: "pdf")),
            fields: fields(octetCount: 123_456)
        )
        let parts = [MessagePart](.singlepart(basic))
        #expect(parts.count == 1)
        #expect(parts[0].size == 123_456)
    }

    @Test func zeroOctetCountIsPreservedAsSize() {
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 10)
        let part = BodyStructure.Singlepart(kind: .text(text), fields: fields(octetCount: 0))
        let parts = [MessagePart](.singlepart(part))
        #expect(parts.count == 1)
        #expect(parts[0].size == 0)
    }

    @Test func multipartChildrenEachCarryTheirOwnSize() {
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 5)
        let child1 = BodyStructure.Singlepart(kind: .text(text), fields: fields(octetCount: 42))
        let child2 = BodyStructure.Singlepart(
            kind: .basic(.init(topLevel: .image, sub: "jpeg")),
            fields: fields(octetCount: 9_000)
        )
        let multipart = BodyStructure.Multipart(
            parts: [.singlepart(child1), .singlepart(child2)],
            mediaSubtype: .mixed
        )
        let parts = [MessagePart](.multipart(multipart))
        #expect(parts.count == 2)
        #expect(parts[0].size == 42)
        #expect(parts[1].size == 9_000)
    }
}
