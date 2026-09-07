/// Controls whether the public `move` APIs may emulate MOVE.
public enum MoveFallbackPolicy: Sendable {
    /// Preserve the traditional behavior: use MOVE when eligible, otherwise
    /// fall back to COPY, STORE `\Deleted`, and EXPUNGE.
    case copyStoreExpunge

    /// Require the server's MOVE extension and never emit fallback commands.
    case disabled
}
