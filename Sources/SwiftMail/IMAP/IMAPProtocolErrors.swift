import Foundation

/// Parsing related errors.
public enum IMAPParseError: Error {
    case malformedResponse(String)
}

/// Connection level errors like disconnects or timeouts.
public enum IMAPConnectionError: Error {
    case disconnected
    case timeout
}

/// Protocol errors when server replies unexpectedly.
public enum IMAPProtocolError: Error {
    case unexpectedTaggedResponse(String)
}
