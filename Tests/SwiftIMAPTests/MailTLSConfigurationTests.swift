import Testing
import NIOSSL
@testable import SwiftMail

@Suite("TLS minimum version")
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
        (MailTLSMinimumVersion.tlsv1_1, TLSVersion.tlsv11),
        (MailTLSMinimumVersion.tlsv1_2, TLSVersion.tlsv12),
        (MailTLSMinimumVersion.tlsv1_3, TLSVersion.tlsv13),
    ])
    func mapsToNIOVersion(_ mail: MailTLSMinimumVersion, _ nio: TLSVersion) {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: mail
        )
        #expect(configuration.minimumTLSVersion == nio)
    }

    @Test("Raising the floor to TLS 1.3 makes a downgrade impossible")
    func tls13Floor() {
        let configuration = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv1_3
        )
        #expect(configuration.minimumTLSVersion == .tlsv13)
    }

    @Test("Certificate verification policy still applies alongside the TLS floor")
    func verificationPolicyUnaffected() {
        let verifying = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .fullVerification,
            minimumTLSVersion: .tlsv1_3
        )
        #expect(verifying.certificateVerification == .fullVerification)

        let notVerifying = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: .noVerification,
            minimumTLSVersion: .tlsv1_3
        )
        #expect(notVerifying.certificateVerification == .none)
    }

    @Test("IMAPServer carries the caller's TLS floor")
    func imapServerStoresFloor() async {
        let server = IMAPServer(host: "imap.example.com", port: 993, minimumTLSVersion: .tlsv1_3)
        #expect(await server.minimumTLSVersion == .tlsv1_3)
    }

    @Test("IMAPServer defaults to TLS 1.2")
    func imapServerDefault() async {
        let server = IMAPServer(host: "imap.example.com", port: 993)
        #expect(await server.minimumTLSVersion == .tlsv1_2)
    }

    @Test("SMTPServer carries the caller's TLS floor")
    func smtpServerStoresFloor() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587, minimumTLSVersion: .tlsv1_3)
        #expect(await server.minimumTLSVersion == .tlsv1_3)
    }

    @Test("SMTPServer defaults to TLS 1.2")
    func smtpServerDefault() async {
        let server = SMTPServer(host: "smtp.example.com", port: 587)
        #expect(await server.minimumTLSVersion == .tlsv1_2)
    }
}
