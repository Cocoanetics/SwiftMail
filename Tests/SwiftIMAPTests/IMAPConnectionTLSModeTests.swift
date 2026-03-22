import NIOIMAPCore
import Testing
@testable import SwiftMail

struct IMAPConnectionTLSModeTests {
    @Test
    func infersImplicitTLSOnPort993() throws {
        #expect(try IMAPConnection.resolveTLSTransportMode(port: 993, useTLS: nil) == .implicitTLS)
    }

    @Test
    func infersOpportunisticSTARTTLSOnPort143() throws {
        #expect(
            try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: nil) == .startTLSIfAvailable(requireTLS: false)
        )
    }

    @Test
    func requiresExplicitTLSChoiceOnNonStandardPorts() {
        do {
            _ = try IMAPConnection.resolveTLSTransportMode(port: 1143, useTLS: nil)
            Issue.record("Expected non-standard ports to require explicit useTLS")
        } catch let error as IMAPError {
            guard case .invalidArgument(let message) = error else {
                Issue.record("Expected invalidArgument, got \(error)")
                return
            }

            #expect(message.contains("requires explicit useTLS"))
        } catch {
            Issue.record("Expected IMAPError.invalidArgument, got \(error)")
        }
    }

    @Test
    func explicitTLSOnPort143RequiresSTARTTLSSupport() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: true)
        #expect(mode == .startTLSIfAvailable(requireTLS: true))
    }

    @Test
    func startTLSPolicyOnlyUpgradesWhenServerAdvertisesCapability() throws {
        let mode = try IMAPConnection.resolveTLSTransportMode(port: 143, useTLS: nil)

        #expect(
            IMAPConnection.requiresSTARTTLSUpgrade(
                port: 143,
                tlsTransportMode: mode,
                capabilities: [.startTLS, .idle]
            )
        )

        #expect(
            !IMAPConnection.requiresSTARTTLSUpgrade(
                port: 143,
                tlsTransportMode: mode,
                capabilities: [.idle]
            )
        )
    }
}
