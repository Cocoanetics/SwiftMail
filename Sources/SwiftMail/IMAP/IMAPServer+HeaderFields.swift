import Foundation

// MARK: - Header Field Fetch

extension IMAPServer {
    /**
     Fetches the raw header lines of the named fields for a set of messages, without setting `\\Seen`.

     The wire request is a single `FETCH`/`UID FETCH` of `BODY.PEEK[HEADER.FIELDS (...)]`.
     Each message's block is returned exactly as the server sent it: every instance of a
     repeated field (`Received`, `Delivered-To`, `Authentication-Results`, ...) in the
     order the server returns them (servers keep the message's order, topmost first),
     folded and encoded as in the message, ending with the empty line that closes the
     header.
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
         a `SequenceNumberSet` by sequence number.
     - Returns: Each answered message's raw header block, by identifier. A message the
       server does not answer with the section is absent. Each block is capped at 256 KiB.
     - Throws: `IMAPError.emptyIdentifierSet`, `IMAPError.invalidArgument` for an empty
       or malformed field name, or `IMAPError.fetchFailed` if the server rejects the fetch.
     */
    public func fetchHeaderFields<T: MessageIdentifier>(
        _ fields: [String],
        using identifierSet: MessageIdentifierSet<T>
    ) async throws -> [T: Data] {
        try await executeCommand(FetchHeaderFieldsCommand(identifierSet: identifierSet, fields: fields))
    }
}
