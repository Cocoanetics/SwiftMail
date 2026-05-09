import NIOSSL

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

/// Certificate-verification policy for TLS connections.
public enum MailCertificateVerificationPolicy: Sendable, Equatable {
    /// Validate the server certificate against trusted roots and the requested hostname.
    case fullVerification

    /// Do not validate the server certificate.
    ///
    /// Use only when the caller has explicitly chosen to trust an endpoint that presents a
    /// self-signed or otherwise locally untrusted certificate.
    case noVerification
}

enum MailTLSConfiguration {
    static func makeClientConfiguration(
        certificateVerificationPolicy: MailCertificateVerificationPolicy
    ) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch certificateVerificationPolicy {
        case .fullVerification:
            configuration.certificateVerification = .fullVerification
            configuration.trustRoots = .default
        case .noVerification:
            configuration.certificateVerification = .none
        }
        return configuration
    }
}
