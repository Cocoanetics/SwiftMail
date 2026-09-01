/// A failure to issue or validate a partial IMAP body fetch.
public enum PartialFetchError: Error, Equatable, Sendable {
    /// The requested offset/count cannot be represented by the IMAP grammar.
    case invalidRange
    /// The server returned no matching message for the requested identifier.
    case messageNotFound
    /// The server rejected valid partial-FETCH syntax with a tagged BAD response.
    case serverRejected
    /// The response did not identify or bound the requested body range safely.
    case invalidResponse(String)

}
