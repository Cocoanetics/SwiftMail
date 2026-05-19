import Testing
@testable import SwiftMail

@Suite
struct FetchMessageInfoOptionsTests {
    @Test
    func testDefaultIncludesBodyStructureAndFullHeader() {
        #expect(FetchMessageInfoOptions.default.contains(.bodyStructure))
        #expect(FetchMessageInfoOptions.default.contains(.fullHeader))
        #expect(FetchMessageInfoOptions.default.contains(.envelope))
        #expect(FetchMessageInfoOptions.default.contains(.internalDate))
        #expect(FetchMessageInfoOptions.default.contains(.flags))
    }

    @Test
    func testSlimDropsHeavyAttributes() {
        #expect(!FetchMessageInfoOptions.slim.contains(.bodyStructure))
        #expect(!FetchMessageInfoOptions.slim.contains(.fullHeader))
        #expect(FetchMessageInfoOptions.slim.contains(.size))
    }

    @Test
    func testSuggestedChunkSizeScalesWithPayload() {
        // Heaviest payload → smallest chunk so the response stays inside the 10s timeout.
        #expect(FetchMessageInfoOptions.default.suggestedChunkSize == 50)
        // Slim drops body structure + header section → ~order-of-magnitude smaller per message.
        #expect(FetchMessageInfoOptions.slim.suggestedChunkSize == 500)
        // UID+FLAGS only → ~50 bytes per message → tens of thousands fit comfortably.
        #expect(FetchMessageInfoOptions.uidFlagsOnly.suggestedChunkSize == 5000)
        // Custom sets fall into the same bucketing.
        let mid: FetchMessageInfoOptions = [.envelope, .flags]
        #expect(mid.suggestedChunkSize == 500)
        let heavy: FetchMessageInfoOptions = [.flags, .bodyStructure]
        #expect(heavy.suggestedChunkSize == 50)
    }
}
