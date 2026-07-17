import NIO
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

/// The lowest TLS protocol version a connection is allowed to negotiate.
///
/// Without this, connections inherit NIOSSL's `TLSConfiguration.makeClientConfiguration()`
/// default, which is TLS 1.0 — deprecated by
/// [RFC 8996](https://datatracker.ietf.org/doc/html/rfc8996) since March 2021.
///
/// Callers who know every server they talk to speaks TLS 1.3 can raise the floor and make
/// downgrades impossible regardless of what the server offers.
public enum MailTLSMinimumVersion: Sendable, Equatable {
    /// TLS 1.0. Deprecated by RFC 8996 — only for legacy servers that offer nothing newer.
    case tlsv1

    /// TLS 1.1. Deprecated by RFC 8996.
    case tlsv11

    /// TLS 1.2. The default, and the lowest version RFC 8996 still permits.
    case tlsv12

    /// TLS 1.3. The strongest floor; refuses to negotiate anything older.
    case tlsv13

    var nioTLSVersion: TLSVersion {
        switch self {
            case .tlsv1: return .tlsv1
            case .tlsv11: return .tlsv11
            case .tlsv12: return .tlsv12
            case .tlsv13: return .tlsv13
        }
    }
}

enum MailTLSConfiguration {
    static func makeClientConfiguration(
        certificateVerificationPolicy: MailCertificateVerificationPolicy,
        minimumTLSVersion: MailTLSMinimumVersion = .tlsv12
    ) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = minimumTLSVersion.nioTLSVersion
        switch certificateVerificationPolicy {
            case .fullVerification:
                configuration.certificateVerification = .fullVerification
                configuration.trustRoots = .default
            case .noVerification:
                configuration.certificateVerification = .none
        }
        return configuration
    }

    static func serverHostnameForTLSHandler(host: String) -> String? {
        let normalizedHost = if host.hasPrefix("[") && host.hasSuffix("]") {
            String(host.dropFirst().dropLast())
        } else {
            host
        }

        if (try? SocketAddress(ipAddress: normalizedHost, port: 0)) != nil {
            return nil
        }
        return host
    }
}
