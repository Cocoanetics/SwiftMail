import NIOIMAPCore

/// Bounds the IMAP response parser enforces against a malicious or malfunctioning server.
///
/// A server controls both the length prefixes and the number of attributes it sends. Without
/// bounds, a hostile or broken server can force unbounded allocation from a single response —
/// the same class of issue that produced advisories in other IMAP clients, for example Ruby's
/// net-imap (GHSA-j3g3-5qv5-52mj, unbounded literal size) and mutt (CVE-2021-3657).
///
/// The defaults preserve SwiftMail's existing behaviour, so adopting this type changes nothing
/// until a caller opts into tighter bounds:
///
/// ```swift
/// let server = IMAPServer(
///     host: "imap.example.com",
///     port: 993,
///     parserLimits: IMAPParserLimits(
///         bodySizeLimit: 64 * 1024 * 1024,  // refuse absurd single messages
///         messageAttributeLimit: 1024
///     )
/// )
/// ```
///
/// - Note: ``IMAPServer/defaultResponseBufferLimit`` bounds the parser's *working buffer*.
///   These limits bound what a single response may *declare*, which is a separate concern.
public struct IMAPParserLimits: Sendable, Equatable {

    /// Maximum size of message body data in a single response.
    ///
    /// Defaults to `UInt64.max` (unbounded), matching SwiftMail's previous behaviour.
    public var bodySizeLimit: UInt64

    /// Maximum number of attributes (`BODY`, `FLAGS`, `ENVELOPE`, …) in one FETCH response.
    ///
    /// Defaults to `Int.max` (unbounded), matching SwiftMail's previous behaviour.
    public var messageAttributeLimit: Int

    /// Maximum size of a single protocol literal — mailbox names and similar.
    ///
    /// Message bodies are bounded by ``bodySizeLimit`` instead, so this can stay small.
    /// Defaults to `NIOIMAPCore.IMAPDefaults.literalSizeLimit` (4 KB).
    public var literalSizeLimit: Int

    /// SwiftMail's previous behaviour: bodies and attribute counts unbounded.
    public static let `default` = IMAPParserLimits()

    public init(
        bodySizeLimit: UInt64 = .max,
        messageAttributeLimit: Int = .max,
        literalSizeLimit: Int = IMAPDefaults.literalSizeLimit
    ) {
        precondition(bodySizeLimit > 0, "bodySizeLimit must be greater than 0")
        precondition(messageAttributeLimit > 0, "messageAttributeLimit must be greater than 0")
        precondition(literalSizeLimit > 0, "literalSizeLimit must be greater than 0")
        self.bodySizeLimit = bodySizeLimit
        self.messageAttributeLimit = messageAttributeLimit
        self.literalSizeLimit = literalSizeLimit
    }
}
