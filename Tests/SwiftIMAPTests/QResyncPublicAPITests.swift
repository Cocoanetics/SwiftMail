import Foundation
import NIO
import NIOEmbedded
import NIOIMAPCore
import Testing
@testable import SwiftMail

struct QResyncServerHarness {
    let server: SwiftMail.IMAPServer
    let connection: IMAPConnection
    let channel: NIOAsyncTestingChannel
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PrimaryQResyncPublicAPITests {
    @Test
    func primaryEnableReturnsConfirmationsWithoutChangingAdvertisement() async throws {
        let harness = try await makeQResyncHarness(
            capabilities: [Capability("enable"), Capability("QrEsYnC")]
        )
        let advertised = harness.connection.capabilitiesSnapshot
        let operation = Task { try await harness.server.enable([.qresync, .condStore]) }

        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 ENABLE QRESYNC CONDSTORE\r\n")
        try await writeQResyncInbound(harness.channel, "* ENABLED qresync\r\nA001 OK Enabled\r\n")

        let enabled = try await operation.value
        #expect(enabled == [.qresync])
        #expect(enabled.contains(.qresync))
        #expect(harness.connection.capabilitiesSnapshot == advertised)
        try await harness.channel.close()
    }

    @Test
    func primaryQResyncNeedsOnlyAdvertisedQResyncAndSendsNoFallback() async throws {
        let harness = try await makeQResyncHarness(capabilities: [Capability("QrEsYnC")])
        let operation = Task {
            try await harness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }

        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"INBOX\" (QRESYNC (777 900))\r\n"
        )
        try await writeQResyncInbound(
            harness.channel,
            "* OK [UIDVALIDITY 777] Current\r\nA001 OK [READ-WRITE] Selected\r\n"
        )
        #expect(try await operation.value.selection.uidValidity == UIDValidity(777))
        #expect(try await nextQResyncOutboundLine(from: harness.channel, timeoutNanoseconds: 100_000_000) == nil)
        try await harness.channel.close()
    }

    @Test
    func primaryQResyncReturnsLiveDeletionWhileResponseBufferIsActive() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.qresync])
        let operation = Task {
            try await harness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }

        _ = try await nextQResyncOutboundLine(from: harness.channel)
        try await writeQResyncInbound(
            harness.channel,
            "* 2 EXISTS\r\n* VANISHED 42\r\nA001 OK [READ-WRITE] Selected\r\n"
        )

        let result = try await operation.value
        #expect(result.selection.messageCount == 1)
        #expect(result.vanished.ranges == [42...42])
        #expect(harness.connection.responseBuffer.bufferedCount == 0)
        try await harness.channel.close()
    }

    @Test
    func primaryCapabilityGuardsSendNothing() async throws {
        let enableHarness = try await makeQResyncHarness(capabilities: [.qresync])
        await #expect(throws: IMAPError.self) {
            _ = try await enableHarness.server.enable([.qresync])
        }
        #expect(try await enableHarness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await enableHarness.channel.close()

        let selectHarness = try await makeQResyncHarness(capabilities: [.enable])
        await #expect(throws: IMAPError.self) {
            _ = try await selectHarness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }
        #expect(try await selectHarness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await selectHarness.channel.close()
    }

    @Test(arguments: [
        "X-ENABLE",
        "ENABLE-OTHER",
        "ENABLE=OTHER"
    ])
    func primaryEnableRejectsLookalikeCapabilities(_ capability: String) async throws {
        let harness = try await makeQResyncHarness(capabilities: [Capability(capability)])

        await #expect(throws: IMAPError.self) {
            _ = try await harness.server.enable([.qresync])
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test(arguments: [
        "X-QRESYNC",
        "QRESYNC-OTHER",
        "QRESYNC=OTHER"
    ])
    func primaryQResyncRejectsLookalikeCapabilities(_ capability: String) async throws {
        let harness = try await makeQResyncHarness(capabilities: [Capability(capability)])

        await #expect(throws: IMAPError.self) {
            _ = try await harness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func primaryEnableRejectsInjectionWithoutSendingBytes() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.enable])

        do {
            _ = try await harness.server.enable([Capability("QRESYNC\r\nA999 LOGOUT")])
            Issue.record("Expected IMAPError.invalidArgument")
        } catch let error as IMAPError {
            guard case .invalidArgument = error else {
                Issue.record("Expected invalidArgument, got \(error)")
                return
            }
        }

        #expect(
            try await nextQResyncOutboundLine(from: harness.channel, timeoutNanoseconds: 100_000_000) == nil
        )
        try await harness.channel.close()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NamedQResyncPublicAPITests {
    @Test
    func enableUsesOnlyTheNamedChannelAndRecordsActivity() async throws {
        let primary = try await makeQResyncHarness(capabilities: [.enable])
        let namedHarness = try await makeQResyncHarness(
            capabilities: [Capability("enable"), Capability("QrEsYnC")]
        )
        let advertised = namedHarness.connection.capabilitiesSnapshot
        let named = IMAPNamedConnection(
            name: "sync",
            connection: namedHarness.connection,
            authenticateOnConnection: { _ in }
        )
        let operation = Task { try await named.enable([.qresync]) }

        #expect(try await nextQResyncOutboundLine(from: namedHarness.channel) == "A001 ENABLE QRESYNC\r\n")
        #expect(try await primary.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await writeQResyncInbound(namedHarness.channel, "* ENABLED qresync\r\nA001 OK Enabled\r\n")

        let enabled = try await operation.value
        #expect(enabled == [.qresync])
        #expect(enabled.contains(.qresync))
        #expect(await named.lastActivity != nil)
        #expect(namedHarness.connection.capabilitiesSnapshot == advertised)
        try await namedHarness.channel.close()
        try await primary.channel.close()
    }

    @Test
    func selectAndAliasResolveNamespaceAfterAuthentication() async throws {
        let harness = try await makeQResyncHarness(
            capabilities: [Capability("QrEsYnC")],
            authenticated: false
        )
        let named = IMAPNamedConnection(
            name: "namespace-sync",
            connection: harness.connection,
            authenticateOnConnection: { connection in
                connection.namespaces = NamespaceResponse(
                    personal: [Namespace(prefix: "INBOX.", delimiter: Character("."))],
                    otherUsers: [],
                    shared: []
                )
                connection.markSessionAuthenticated()
            }
        )

        let primaryMethod = Task {
            try await named.select(mailbox: "Archive", resyncingFrom: 777, modificationSequence: 900)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A001 SELECT \"INBOX.Archive\" (QRESYNC (777 900))\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A001 OK [READ-WRITE] Selected\r\n")
        _ = try await primaryMethod.value

        let alias = Task {
            try await named.selectMailbox("Archive", resyncingFrom: 777, modificationSequence: 901)
        }
        #expect(
            try await nextQResyncOutboundLine(from: harness.channel)
                == "A002 SELECT \"INBOX.Archive\" (QRESYNC (777 901))\r\n"
        )
        try await writeQResyncInbound(harness.channel, "A002 OK [READ-ONLY] Selected\r\n")
        #expect(try await alias.value.selection.isReadOnly)
        #expect(await named.lastActivity != nil)
        #expect(try await nextQResyncOutboundLine(from: harness.channel, timeoutNanoseconds: 100_000_000) == nil)
        try await harness.channel.close()
    }

    @Test
    func namedCapabilityGuardsSendNothing() async throws {
        let harness = try await makeQResyncHarness(capabilities: [])
        let named = IMAPNamedConnection(
            name: "unsupported-sync",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )

        await #expect(throws: IMAPError.self) {
            _ = try await named.enable([.qresync])
        }
        await #expect(throws: IMAPError.self) {
            _ = try await named.select(mailbox: "INBOX", resyncingFrom: 777, modificationSequence: 900)
        }
        #expect(try await harness.channel.readOutbound(as: ByteBuffer.self) == nil)
        try await harness.channel.close()
    }

    @Test
    func namedEnableRejectsInjectionWithoutSendingBytes() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.enable])
        let named = IMAPNamedConnection(
            name: "injection-check",
            connection: harness.connection,
            authenticateOnConnection: { _ in }
        )

        do {
            _ = try await named.enable([Capability("QRESYNC\r\nA999 LOGOUT")])
            Issue.record("Expected IMAPError.invalidArgument")
        } catch let error as IMAPError {
            guard case .invalidArgument = error else {
                Issue.record("Expected invalidArgument, got \(error)")
                return
            }
        }

        #expect(
            try await nextQResyncOutboundLine(from: harness.channel, timeoutNanoseconds: 100_000_000) == nil
        )
        try await harness.channel.close()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct QResyncReconnectTests {
    @Test
    func replacementConnectionDoesNotReplayEnableAndPropagatesSelectRejection() async throws {
        let harness = try await makeQResyncHarness(capabilities: [.enable, .qresync])
        let enable = Task { try await harness.server.enable([.qresync]) }
        #expect(try await nextQResyncOutboundLine(from: harness.channel) == "A001 ENABLE QRESYNC\r\n")
        try await writeQResyncInbound(harness.channel, "* ENABLED QRESYNC\r\nA001 OK Enabled\r\n")
        _ = try await enable.value

        try await harness.channel.close()
        let replacement = NIOAsyncTestingChannel()
        harness.connection.replaceConnectForTesting {
            try await replacement.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
            try await replacement.addIMAPClientHandler()
            try await replacement.pipeline.addHandler(harness.connection.duplexLogger)
            try await replacement.pipeline.addHandler(harness.connection.responseBuffer)
            harness.connection.replaceChannelForTesting(replacement)
        }
        harness.connection.reauthenticateAfterReconnect = { connection in
            connection.replaceCapabilitiesForTesting([.qresync])
            connection.markSessionAuthenticated()
        }

        let selection = Task {
            try await harness.server.selectMailbox(
                "INBOX",
                resyncingFrom: 777,
                modificationSequence: 900
            )
        }
        #expect(
            try await nextQResyncOutboundLine(from: replacement)
                == "A002 SELECT \"INBOX\" (QRESYNC (777 900))\r\n"
        )
        try await writeQResyncInbound(replacement, "A002 NO QRESYNC must be enabled\r\n")

        do {
            _ = try await selection.value
            Issue.record("Expected replacement-connection SELECT rejection")
        } catch let error as IMAPError {
            guard case .selectFailed = error else {
                Issue.record("Unexpected IMAP error: \(error)")
                return
            }
        }
        #expect(try await nextQResyncOutboundLine(from: replacement, timeoutNanoseconds: 100_000_000) == nil)
        try await replacement.close()
    }
}

func makeQResyncHarness(
    capabilities: Set<Capability>,
    authenticated: Bool = true
) async throws -> QResyncServerHarness {
    let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
    let connection = await server.primaryConnection
    let channel = NIOAsyncTestingChannel()
    try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
    try await channel.addIMAPClientHandler()
    try await channel.pipeline.addHandler(connection.duplexLogger)
    try await channel.pipeline.addHandler(connection.responseBuffer)
    connection.replaceChannelForTesting(channel)
    connection.replaceCapabilitiesForTesting(capabilities)
    if authenticated {
        connection.markSessionAuthenticated()
    }
    return QResyncServerHarness(server: server, connection: connection, channel: channel)
}

func writeQResyncInbound(_ channel: NIOAsyncTestingChannel, _ text: String) async throws {
    var buffer = channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    try await channel.writeInbound(buffer)
}

func nextQResyncOutboundLine(
    from channel: NIOAsyncTestingChannel,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws -> String? {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if var line = try await channel.readOutbound(as: ByteBuffer.self) {
            return line.readString(length: line.readableBytes)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    return nil
}
