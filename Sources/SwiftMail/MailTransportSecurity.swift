/// Transport-security policy for IMAP and SMTP connections.
public enum MailTransportSecurity: Sendable, Equatable {
    /// Infer transport security from the server port, preserving SwiftMail's legacy defaults.
    case automatic

    /// Start the connection inside TLS from the first byte.
    case implicitTLS

    /// Require STARTTLS after the plaintext greeting or EHLO capability exchange.
    case startTLS

    /// Use plaintext transport without TLS.
    case plainText
}
