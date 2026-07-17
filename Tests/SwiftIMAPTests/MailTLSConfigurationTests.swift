import Testing
import NIOSSL
@testable import SwiftMail

/// - Note: `.serialized` and `.timeLimit` match the other server-constructing suites.
///   Constructing an `IMAPServer` or `SMTPServer` allocates a `MultiThreadedEventLoopGroup`
///   that is shut down on release; suites that release servers used to be able to deadlock a
///   core-constrained CI runner when the deinit still *blocked* on that shutdown, so the traits
///   keep server churn serialized and bounded in time as defense in depth.
@Suite("TLS minimum version", .serialized, .timeLimit(.minutes(1)))
struct MailTLSConfigurationTests {

    @Test("Default floor is TLS 1.2, not NIOSSL's TLS 1.0")
    func defaultIsTLS12() {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification
        )
        #expect(configuration.minimumTLSVersion == .tlsv12)
        // Guards the whole point of this change: NIOSSL's own default is .tlsv1,
        // which RFC 8996 deprecated in March 2021.
        #expect(TLSConfiguration.makeClientConfiguration().minimumTLSVersion == .tlsv1)
    }

    @Test("Each case maps to the matching NIOSSL version", arguments: [
        (MailTLSMinimumVersion.tlsv1, TLSVersion.tlsv1),
        (MailTLSMinimumVersion.tlsv11, TLSVersion.tlsv11),
        (MailTLSMinimumVersion.tlsv12, TLSVersion.tlsv12),
        (MailTLSMinimumVersion.tlsv13, TLSVersion.tlsv13)
    ])
    func mapsToNIOVersion(_ mail: MailTLSMinimumVersion, _ nio: TLSVersion) {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: mail
        )
        #expect(configuration.minimumTLSVersion == nio)
    }

    /// - Important: This suite covers the *configuration factory* only — that it returns what it
    ///   is handed. It says nothing about whether any connection passes the value in, which is
    ///   where the implicit-TLS defect lived: this test was green throughout, under the name
    ///   *"Raising the floor to TLS 1.3 makes a downgrade impossible"*, while a downgrade on
    ///   port 993 was entirely possible. Enforcement on the wire is covered by
    ///   ``IMAPTLSFloorEnforcementTests``, which talks to a TLS-1.2-only peer.
    @Test("Requesting TLS 1.3 yields a configuration with a TLS 1.3 floor")
    func tls13Floor() {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv13
        )
        #expect(configuration.minimumTLSVersion == .tlsv13)
    }

    @Test("Certificate verification policy still applies alongside the TLS floor")
    func verificationPolicyUnaffected() {
        let verifying = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv13
        )
        #expect(verifying.certificateVerification == .fullVerification)

        let notVerifying = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .noVerification,
            minimumTLSVersion: .tlsv13
        )
        #expect(notVerifying.certificateVerification == .none)
    }

    @Test("IMAPServer carries the caller's TLS floor")
    func imapServerStoresFloor() async {
        let server = IMAPServer(host: "imap.example.com", port: 993, minimumTLSVersion: .tlsv13)
        #expect(await server.minimumTLSVersion == .tlsv13)
    }

    @Test("IMAPServer defaults to TLS 1.2")
    func imapServerDefault() async {
        let server = IMAPServer(host: "imap.example.com", port: 993)
        #expect(await server.minimumTLSVersion == .tlsv12)
    }

    @Test("SMTPServer carries the caller's TLS floor")
    func smtpServerStoresFloor() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587, minimumTLSVersion: .tlsv13)
        #expect(await server.minimumTLSVersion == .tlsv13)
    }

    @Test("SMTPServer defaults to TLS 1.2")
    func smtpServerDefault() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        #expect(await server.minimumTLSVersion == .tlsv12)
    }
}
