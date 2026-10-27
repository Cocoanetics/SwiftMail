import Foundation

// MARK: - Raw Message Fetch

extension IMAPServer {
    /**
     Fetches the complete raw RFC 822 messages for a set of messages as a stream, without setting `\\Seen`.

     The wire request is a `FETCH`/`UID FETCH` of `BODY.PEEK[]`, one per chunk of at most
     `chunkSize` messages, which saves a round trip per message. Each message is yielded as soon
     as its FETCH response ends, as its exact bytes, so only one message at a time is held
     by this method. The stream itself buffers without limit, as
     ``fetchMessageInfos(using:options:headerFields:chunkSize:)`` does:
     a consumer slower than the network lets yielded messages pile up.

     A message the server does not answer is not yielded. Cancelling the stream stops
     further chunks; a command already sent runs to its end or its deadline.

     ```swift
     for try await (uid, data) in server.fetchRawMessages(using: UIDSet(uidRange)) {
         try data.write(to: url(for: uid))
     }
     ```

     - Parameters:
       - identifierSet: The messages to fetch. A `UIDSet` keys each element by UID,
         a `SequenceNumberSet` by sequence number. A set that ends in `*` is sent
         in one command.
       - chunkSize: The most messages one command asks for; 25 when `nil`. Zero or
         less sends the whole set in one command.
       - timeoutSeconds: The deadline for each command's complete answer; 60 seconds
         when `nil`. Raw bodies have no size bound: size it from the chunk's total `RFC822.SIZE`,
         as for ``fetchRawMessage(identifier:timeoutSeconds:)``.
     - Returns: A stream of `(identifier, data)` pairs. It finishes by throwing
       `IMAPError.emptyIdentifierSet`; `IMAPError.invalidArgument` for a timeout below one
       second; `IMAPError.timeout`; or `IMAPError.fetchFailed` if the server rejects the fetch or
       sends invalid data (in a UID fetch, a body without its message's UID). Messages yielded
       before the failure remain valid. A repeated body for an identifier already
       yielded in the same command is ignored.
     */
    public nonisolated func fetchRawMessages<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        chunkSize: Int? = nil,
        timeoutSeconds: Int? = nil
    ) -> AsyncThrowingStream<(identifier: T, data: Data), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let commands = try FetchRawMessagesCommand.chunks(
                        identifierSet: identifierSet, chunkSize: chunkSize, timeoutSeconds: timeoutSeconds,
                        sink: { continuation.yield((identifier: $0, data: $1)) }
                    )
                    for command in commands {
                        try Task.checkCancellation()
                        try await executeCommand(command)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
