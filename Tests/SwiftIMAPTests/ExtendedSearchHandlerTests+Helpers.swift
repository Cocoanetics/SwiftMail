import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
@testable import SwiftMail

enum ExtendedSearchHandlerTestHelpers {
    static func sendSearchCommand(
        on channel: NIOAsyncTestingChannel,
        tag: String,
        useUID: Bool,
        useEsearch: Bool,
        partialRange: NIOIMAPCore.PartialRange? = nil
    ) async throws {
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
}
