import NIO
import NIOEmbedded
import NIOIMAP

// NIOIMAP 0.3.0 declares `IMAPClientHandler` explicitly non-`Sendable` (it is tied
// to a single `EventLoop`), so it can't be added via the async
// `pipeline.addHandler(_:)`, which requires a `Sendable` handler. These helpers add
// it through `syncOperations` instead, on the channel's event loop.
extension NIOAsyncTestingChannel {
    static func withIMAPClientHandler(
        loop: NIOAsyncTestingEventLoop = NIOAsyncTestingEventLoop()
    ) async throws -> NIOAsyncTestingChannel {
        try await NIOAsyncTestingChannel(loop: loop) { channel in
            try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
        }
    }

    func addIMAPClientHandler() async throws {
        try await self.eventLoop.submit {
            try self.pipeline.syncOperations.addHandler(IMAPClientHandler())
        }.get()
    }
}
