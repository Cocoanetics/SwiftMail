import Foundation

// MARK: - Header Field Fetch

extension IMAPServer {
    /**
     Fetches the raw header lines of the named fields for a set of messages, without setting `\\Seen`.

     The wire request is a `FETCH`/`UID FETCH` of `BODY.PEEK[HEADER.FIELDS (...)]`, one per
     chunk of at most `chunkSize` messages. Each message's block is returned exactly as the
     server sent it: every instance of a repeated field (`Received`, `Delivered-To`,
     `Authentication-Results`, ...) in the order the server returns them (servers keep the
     message's order, topmost first), folded and encoded as in the message, ending with the
     empty line that closes the header.
     A message without any of the fields gets just that empty line.

     Unlike ``MessageInfo/additionalHeaderFields``, nothing is decoded, unfolded or left
     out (`Reply-To` and the other ENVELOPE fields are included when asked for).

     ```swift
     let blocks = try await server.fetchHeaderFields(
         ["Reply-To", "Delivered-To", "Authentication-Results"],
         using: UIDSet(uidRange)
     )
     ```

     - Parameters:
       - fields: The header field names to request (case-insensitive).
       - identifierSet: The messages to fetch. A `UIDSet` keys the result by UID,
         a `SequenceNumberSet` by sequence number. A set that ends in `*` is sent
         in one command.
       - chunkSize: The most messages one command asks for; 200 when `nil`. Zero or
         less sends the whole set in one command.
       - timeoutSeconds: The deadline for each command's complete answer; 30 seconds
         when `nil`.
     - Returns: Each answered message's raw header block, by identifier. A message the
       server does not answer with the section is absent.
     - Throws: `IMAPError.emptyIdentifierSet`; `IMAPError.invalidArgument` for an empty or
       malformed field name or a timeout below one second; `IMAPError.timeout`; or
       `IMAPError.fetchFailed` if the server rejects the fetch or sends invalid data:
       a block over 256 KiB, or in a UID fetch a block without its message's UID.
     */
    public func fetchHeaderFields<T: MessageIdentifier>(
        _ fields: [String],
        using identifierSet: MessageIdentifierSet<T>,
        chunkSize: Int? = nil,
        timeoutSeconds: Int? = nil
    ) async throws -> [T: Data] {
        let commands = try FetchHeaderFieldsCommand.chunks(
            fields: fields, identifierSet: identifierSet, chunkSize: chunkSize, timeoutSeconds: timeoutSeconds
        )
        var blocks: [T: Data] = [:]
        for command in commands {
            try Task.checkCancellation()
            blocks.merge(try await executeCommand(command)) { _, latest in latest }
        }
        return blocks
    }
}
