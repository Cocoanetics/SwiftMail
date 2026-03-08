import Testing
@testable import SwiftMail

@Suite("MessageIdentifierSet Chunking")
struct MessageChunkingTests {

    // MARK: - Empty Set

    @Test("Empty set produces no chunks")
    func emptySet() {
        let set = MessageIdentifierSet<SwiftMail.UID>()
        let chunks = set.chunked(size: 10)
        #expect(chunks.isEmpty)
    }

    // MARK: - Single Element

    @Test("Single element produces one chunk")
    func singleElement() {
        let set = MessageIdentifierSet<SwiftMail.UID>(SwiftMail.UID(42))
        let chunks = set.chunked(size: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 1)
        #expect(chunks[0].contains(SwiftMail.UID(42)))
    }

    // MARK: - Set Smaller Than Chunk Size

    @Test("Set smaller than chunk size produces one chunk")
    func smallerThanChunkSize() {
        let uids = (1...5).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 5)
    }

    // MARK: - Set Exactly Equal to Chunk Size

    @Test("Set exactly equal to chunk size produces one chunk")
    func exactlyChunkSize() {
        let uids = (1...10).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 10)
    }

    // MARK: - Set Larger Than Chunk Size

    @Test("Set larger than chunk size produces correct number of chunks")
    func largerThanChunkSize() {
        let uids = (1...25).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 10)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 10)
        #expect(chunks[1].count == 10)
        #expect(chunks[2].count == 5)
    }

    @Test("All original elements are present across chunks")
    func allElementsPreserved() {
        let uids = (1...23).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 7)

        let totalCount = chunks.reduce(0) { $0 + $1.count }
        #expect(totalCount == 23)

        for uid in uids {
            let found = chunks.contains { $0.contains(uid) }
            #expect(found, "UID \(uid.value) should be in one of the chunks")
        }
    }

    // MARK: - Non-Contiguous UIDs

    @Test("Non-contiguous UIDs are preserved correctly")
    func nonContiguousUIDs() {
        // UIDs: 1, 2, 3, 10, 11, 12, 50, 51
        var set = MessageIdentifierSet<SwiftMail.UID>()
        set.insert(range: SwiftMail.UID(1)...SwiftMail.UID(3))
        set.insert(range: SwiftMail.UID(10)...SwiftMail.UID(12))
        set.insert(SwiftMail.UID(50))
        set.insert(SwiftMail.UID(51))
        #expect(set.count == 8)

        let chunks = set.chunked(size: 5)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 5)
        #expect(chunks[1].count == 3)

        // First chunk: 1, 2, 3, 10, 11
        #expect(chunks[0].contains(SwiftMail.UID(1)))
        #expect(chunks[0].contains(SwiftMail.UID(3)))
        #expect(chunks[0].contains(SwiftMail.UID(10)))

        // Second chunk: 12, 50, 51
        #expect(chunks[1].contains(SwiftMail.UID(12)))
        #expect(chunks[1].contains(SwiftMail.UID(50)))
        #expect(chunks[1].contains(SwiftMail.UID(51)))
    }

    // MARK: - SequenceNumber

    @Test("Works with SequenceNumber identifiers")
    func sequenceNumbers() {
        let seqs = (1...12).map { SwiftMail.SequenceNumber(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.SequenceNumber>(seqs)
        let chunks = set.chunked(size: 5)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 5)
        #expect(chunks[1].count == 5)
        #expect(chunks[2].count == 2)
    }

    // MARK: - Zero / Negative Chunk Size

    @Test("Zero chunk size returns single chunk with all elements")
    func zeroChunkSize() {
        let uids = (1...10).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 0)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 10)
    }

    @Test("Negative chunk size returns single chunk with all elements")
    func negativeChunkSize() {
        let uids = (1...10).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: -5)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 10)
    }

    // MARK: - Chunk Size of 1

    @Test("Chunk size of 1 produces one chunk per element")
    func chunkSizeOne() {
        let uids = (1...4).map { SwiftMail.UID(UInt32($0)) }
        let set = MessageIdentifierSet<SwiftMail.UID>(uids)
        let chunks = set.chunked(size: 1)
        #expect(chunks.count == 4)
        for chunk in chunks {
            #expect(chunk.count == 1)
        }
    }
}
