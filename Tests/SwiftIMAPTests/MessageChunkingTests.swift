// MessageChunkingTests.swift
// Tests for message chunking functionality

import Testing
import Foundation
@testable import SwiftMail

@Suite("MessageIdentifierSet Chunking")
struct MessageChunkingTests {

    @Test("Empty set produces no chunks")
    func testEmptySetChunking() {
        let emptySet = MessageIdentifierSet<UID>()
        let chunks = emptySet.chunked(size: 10)
        #expect(chunks.isEmpty)
    }

    @Test("Single message produces single chunk")
    func testSingleMessageChunking() {
        let singleSet = MessageIdentifierSet<UID>(UID(1))
        let chunks = singleSet.chunked(size: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 1)
        #expect(chunks[0].contains(UID(1)))
    }

    @Test("Small set under chunk size produces single chunk")
    func testSmallSetChunking() {
        let smallSet = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
        let chunks = smallSet.chunked(size: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 3)
    }

    @Test("Large set produces multiple chunks")
    func testLargeSetChunking() {
        // Create a set with 25 UIDs
        let uids = (1...25).map { UID($0) }
        let largeSet = MessageIdentifierSet<UID>(uids)
        
        let chunks = largeSet.chunked(size: 10)
        #expect(chunks.count == 3) // 10 + 10 + 5
        
        // Verify chunk sizes
        #expect(chunks[0].count == 10)
        #expect(chunks[1].count == 10)
        #expect(chunks[2].count == 5)
        
        // Verify all UIDs are present across chunks
        var allChunkUIDs: Set<UInt32> = []
        for chunk in chunks {
            for uid in chunk.toArray() {
                allChunkUIDs.insert(uid.value)
            }
        }
        #expect(allChunkUIDs.count == 25)
        #expect(allChunkUIDs == Set(1...25))
    }

    @Test("Exact multiple produces exact number of chunks")
    func testExactMultipleChunking() {
        // Create a set with exactly 20 UIDs
        let uids = (1...20).map { UID($0) }
        let exactSet = MessageIdentifierSet<UID>(uids)
        
        let chunks = exactSet.chunked(size: 10)
        #expect(chunks.count == 2) // Exactly 10 + 10
        
        // Verify chunk sizes
        #expect(chunks[0].count == 10)
        #expect(chunks[1].count == 10)
    }

    @Test("Zero chunk size returns single chunk with all elements")
    func testZeroChunkSize() {
        let testSet = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
        let chunks = testSet.chunked(size: 0)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 3)
    }

    @Test("Negative chunk size returns single chunk with all elements")
    func testNegativeChunkSize() {
        let testSet = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
        let chunks = testSet.chunked(size: -5)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 3)
    }

    @Test("Works with SequenceNumber identifiers")
    func testSequenceNumberChunking() {
        let seqNums = (1...15).map { SequenceNumber($0) }
        let seqSet = MessageIdentifierSet<SequenceNumber>(seqNums)
        
        let chunks = seqSet.chunked(size: 5)
        #expect(chunks.count == 3) // 5 + 5 + 5
        
        // Verify all sequence numbers are present
        var allSeqNums: Set<UInt32> = []
        for chunk in chunks {
            for seqNum in chunk.toArray() {
                allSeqNums.insert(seqNum.value)
            }
        }
        #expect(allSeqNums.count == 15)
        #expect(allSeqNums == Set(1...15))
    }

    @Test("Chunking preserves message identifiers correctly")
    func testChunkingPreservesIdentifiers() {
        // Create a set with non-contiguous UIDs
        let uids = [UID(1), UID(3), UID(5), UID(7), UID(10), UID(15), UID(20)]
        let testSet = MessageIdentifierSet<UID>(uids)
        
        let chunks = testSet.chunked(size: 3)
        #expect(chunks.count == 3) // 3 + 3 + 1
        
        // Collect all UIDs from chunks
        var allUIDs: [UID] = []
        for chunk in chunks {
            allUIDs.append(contentsOf: chunk.toArray())
        }
        
        // Sort for comparison
        let originalUIDs = uids.sorted()
        let chunkUIDs = allUIDs.sorted()
        
        #expect(originalUIDs.count == chunkUIDs.count)
        for (original, fromChunk) in zip(originalUIDs, chunkUIDs) {
            #expect(original.value == fromChunk.value)
        }
    }
}