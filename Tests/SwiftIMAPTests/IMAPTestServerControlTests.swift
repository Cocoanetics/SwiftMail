#if os(macOS) || os(Linux)
// Keep the raw helper and full socket control matrix together.
// swiftlint:disable file_length
import Foundation
import Testing
@testable import SwiftMail
#if canImport(Glibc)
import Glibc
#endif

/// A write-half shutdown sends a real FIN while the client declines incoming bytes.
private final class RawClient {
    let descriptor: Int32

    init(port: Int, receiveBuffer: Int32? = nil) throws {
        #if os(Linux)
        let socketDescriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard socketDescriptor >= 0 else { throw IMAPTestError.setup("raw socket: \(errno)") }
        var connected = false
        defer { if !connected { close(socketDescriptor) } }
        guard fcntl(socketDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw IMAPTestError.setup("raw nonblocking socket: \(errno)")
        }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var noSigPipe: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if var size = receiveBuffer {
            setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try Self.finishConnect(socketDescriptor, result: result)
        descriptor = socketDescriptor
        connected = true
    }

    private static func finishConnect(_ descriptor: Int32, result: Int32) throws {
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw IMAPTestError.setup("raw connect: \(errno)") }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&item, 1, 50)
            if polled > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw IMAPTestError.setup("raw connect completion: \(error)")
                }
                return
            }
            if polled < 0, errno != EINTR { throw IMAPTestError.setup("raw connect poll: \(errno)") }
        }
        throw IMAPTestError.setup("raw connect watchdog expired")
    }

    deinit { close(descriptor) }

    func finishWriting() throws {
        guard shutdown(descriptor, Int32(SHUT_WR)) == 0 else {
            throw IMAPTestError.setup("raw FIN: \(errno)")
        }
    }

    func resetOnClose() throws {
        var value = linger(l_onoff: 1, l_linger: 0)
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_LINGER, &value, socklen_t(MemoryLayout<linger>.size)) == 0 else {
            throw IMAPTestError.setup("raw SO_LINGER: \(errno)")
        }
    }

    private func ready(_ events: Int16, deadline: UInt64) throws {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, 50)
            if result > 0 { return }
            if result < 0, errno != EINTR { throw IMAPTestError.setup("raw poll: \(errno)") }
        }
        throw IMAPTestError.setup("raw socket watchdog expired")
    }

    func send(_ string: String) throws {
        let data = Data(string.utf8)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        try data.withUnsafeBytes { buffer in
            let pointer = try #require(buffer.baseAddress)
            var sent = 0
            while sent < data.count {
                try ready(Int16(POLLOUT), deadline: deadline)
                #if os(Linux)
                let flags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
                let count = Glibc.send(descriptor, pointer + sent, data.count - sent, flags)
                #else
                let count = Darwin.send(descriptor, pointer + sent, data.count - sent, Int32(MSG_DONTWAIT))
                #endif
                if count > 0 { sent += count; continue }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw IMAPTestError.setup("raw send: \(errno)")
            }
        }
    }

    func receive(_ count: Int) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: max(1, count))
        while result.count < count {
            try ready(Int16(POLLIN), deadline: deadline)
            let received = recv(descriptor, &buffer, count - result.count, Int32(MSG_DONTWAIT))
            if received > 0 { result.append(contentsOf: buffer.prefix(received)); continue }
            if received < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw IMAPTestError.setup("raw receive ended: \(received), errno \(errno)")
        }
        return result
    }

    func expect(_ string: String) throws {
        #expect(try receive(string.utf8.count) == Data(string.utf8))
    }

    func greeting() throws { try expect("* OK IMAP test server ready\r\n") }
}

@Suite("IMAP socket fixture controls", .serialized, .timeLimit(.minutes(2)))
struct IMAPTestServerControlTests {
    private typealias Server = IMAPTestServer

    private func withServer(
        scripts: [Server.Script] = [], sendBufferSize: Int32? = nil, loginDelay: TimeInterval = 0,
        _ body: (Server) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cur"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("new"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try Server(
            loginResponseDelay: loginDelay, scripts: scripts, sendBufferSize: sendBufferSize, maildirURL: root)
        try server.start()
        try await server.run { try await body(server) }
        #expect(server.fixtureFailures.isEmpty)
        #expect(server.pendingEventWaiterCount == 0)
        let events = server.events
        #expect(zip(events, events.dropFirst()).allSatisfy {
            $0.sequence < $1.sequence && $0.uptimeNanoseconds <= $1.uptimeNanoseconds
        })
        for accepted in events where accepted.kind == .accepted {
            let workers = events.filter { $0.connection == accepted.connection && $0.kind == .workerDrained }
            #expect(workers.map(\.detail).sorted() == ["reader", "writer"])
        }
    }

    private func event(
        _ server: Server, _ kind: Server.EventKind, _ connection: Server.ConnectionID,
        occurrence: Int? = nil, detail: String? = nil
    ) async throws -> Server.Event {
        do {
            return try await server.waitForEvent(
                kind, run: connection.run, connection: connection, occurrence: occurrence, detail: detail)
        } catch {
            Issue.record("Waiting for \(kind) failed: \(error); history: \(server.events)")
            throw error
        }
    }

    @Test("held greeting, LOGIN, discovery and FETCH observe FIN before release", arguments: [
        "greeting", "A LOGIN user pass\r\n", "A CAPABILITY\r\n", "A UID FETCH 1 BODY[]\r\n"
    ])
    func heldReplyObservesFIN(command: String) async throws {
        let occurrence = command == "greeting" ? 0 : 1
        let script = Server.Script(connectionNumber: 1, occurrence: occurrence, actions: [
            .hold("reply"), .taggedCompletion("OK scripted")
        ])
        try await withServer(scripts: [script]) { server in
            let raw = try RawClient(port: server.port)
            let accepted = try await server.waitForEvent(.accepted, run: server.runID)
            if occurrence > 0 {
                try raw.greeting()
                try raw.send(command)
                _ = try await event(server, .commandReachedServer, accepted.connection, occurrence: occurrence)
            }
            let held = try await event(server, .replyHeld, accepted.connection, occurrence: occurrence)
            try raw.finishWriting()
            let eof = try await event(server, .peerEOF, accepted.connection)
            #expect(held.sequence < eof.sequence)
            #expect(!server.release(try #require(held.command), gate: "reply"))
            _ = try await event(server, .workerDrained, accepted.connection, detail: "writer")
            #expect(!server.events.contains { $0.kind == .released && $0.command == held.command })
            #expect(!server.events.contains { $0.kind == .fragmentSent && $0.command == held.command })
        }
    }

    @Test("a partially sent literal stays gated while the reader observes FIN")
    func partialLiteralObservesFIN() async throws {
        let prefix = "* 1 FETCH (BODY[] {100}\r\nabc"
        let script = Server.Script(connectionNumber: 1, occurrence: 1, actions: [
            .send(Data(prefix.utf8), acknowledgement: "literal-prefix"),
            .hold("remaining-literal"), .send(Data(repeating: 0x61, count: 97), acknowledgement: "remainder"),
            .taggedCompletion("OK FETCH completed")
        ])
        try await withServer(scripts: [script]) { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            try raw.send("F FETCH 1 BODY[]\r\n")
            let fragment = try await event(
                server, .fragmentSent, connection, occurrence: 1, detail: "literal-prefix")
            let held = try await event(server, .replyHeld, connection, detail: "remaining-literal")
            try raw.expect(prefix)
            try raw.finishWriting()
            let eof = try await event(server, .peerEOF, connection)
            #expect(fragment.sequence < held.sequence && held.sequence < eof.sequence)
            _ = try await event(server, .workerDrained, connection, detail: "writer")
            #expect(!server.events.contains { $0.command == held.command && $0.detail == "remainder" })
        }
    }

    @Test("a full send buffer cannot prevent independent reader EOF", arguments: [false, true])
    func backpressuredWriter(finishWithStop: Bool) async throws {
        let script = Server.Script(connectionNumber: 1, occurrence: 1, actions: [
            .send(Data(repeating: 0x61, count: 16 * 1024 * 1024), acknowledgement: "large-literal"),
            .taggedCompletion("OK FETCH completed")
        ])
        try await withServer(scripts: [script], sendBufferSize: 4096) { server in
            let raw = try RawClient(port: server.port, receiveBuffer: 4096)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            try raw.send("F FETCH 1 BODY[]\r\n")
            _ = try await event(server, .commandReachedServer, connection)
            let blocked = try await event(server, .writerBackpressured, connection)
            #expect((Int(blocked.detail) ?? 0) > 0)
            #expect((Int(blocked.detail) ?? Int.max) < 16 * 1024 * 1024)
            if finishWithStop {
                await server.stop()
                #expect(server.events.contains { $0.connection == connection && $0.kind == .localShutdown })
                #expect(!server.events.contains { $0.connection == connection && $0.kind == .peerEOF })
            } else {
                // Continue declining reads, but send a genuine FIN in the opposite direction.
                try raw.finishWriting()
                let eof = try await event(server, .peerEOF, connection)
                #expect(blocked.sequence < eof.sequence)
            }
            _ = try await event(server, .workerDrained, connection, detail: "reader")
            _ = try await event(server, .workerDrained, connection, detail: "writer")
            #expect(!server.events.contains { $0.kind == .fragmentSent && $0.detail == "large-literal" })
        }
    }

    @Test("two clients have independent gates, repeated tags and command logs")
    func isolatedClients() async throws {
        let scripts = (1...2).map { number in
            Server.Script(connectionNumber: UInt64(number), occurrence: 1, actions: [
                .hold("same-name"), .taggedCompletion("OK client-\(number)")
            ])
        }
        try await withServer(scripts: scripts) { server in
            let first = try RawClient(port: server.port)
            let firstAccepted = try await server.waitForEvent(.accepted, run: server.runID)
            let second = try RawClient(port: server.port)
            let secondAccepted = try await server.waitForEvent(
                .accepted, run: server.runID, after: firstAccepted.sequence)
            try first.greeting()
            try second.greeting()
            try first.send("A NOOP first\r\n")
            try second.send("A NOOP second\r\n")
            let firstHeld = try await event(server, .replyHeld, firstAccepted.connection)
            let secondHeld = try await event(server, .replyHeld, secondAccepted.connection)
            let firstCommand = try #require(firstHeld.command)
            let secondCommand = try #require(secondHeld.command)
            #expect(firstCommand != secondCommand)
            #expect(server.release(firstCommand, gate: "same-name"))
            #expect(!server.release(firstCommand, gate: "same-name"))
            try first.expect("A OK client-1\r\n")
            #expect(!server.events.contains { $0.command == secondCommand && $0.kind == .released })
            #expect(server.release(secondCommand, gate: "same-name"))
            try second.expect("A OK client-2\r\n")
            for (connection, line) in [(firstAccepted.connection, "A NOOP first"),
                                       (secondAccepted.connection, "A NOOP second")] {
                let log = server.events.filter { $0.connection == connection && $0.kind == .commandReachedServer }
                #expect(log.map(\.detail) == [line])
            }
            #expect(server.commandLog.sorted() == ["A NOOP first", "A NOOP second"])
            try first.finishWriting()
            try second.finishWriting()
        }
    }

    @Test("release and cancellation before gate arrival win only once")
    func releaseBeforeWait() async throws {
        let scripts = [
            Server.Script(connectionNumber: 1, occurrence: 0, actions: [.hold("greeting")]),
            Server.Script(connectionNumber: 1, occurrence: 1, actions: [
                .hold("early"), .send(Data("prefix".utf8), acknowledgement: "prefix"),
                .hold("cancelled"), .taggedCompletion("OK must not appear")
            ])
        ]
        try await withServer(scripts: scripts) { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            let greeting = try await event(server, .replyHeld, connection, occurrence: 0)
            try raw.send("A NOOP\r\n")
            let reached = try await event(server, .commandReachedServer, connection, occurrence: 1)
            let command = try #require(reached.command)
            #expect(server.release(command, gate: "early"))
            #expect(!server.cancelGate(command, gate: "early"))
            #expect(server.cancelGate(command, gate: "cancelled"))
            #expect(!server.cancelGate(command, gate: "cancelled"))
            #expect(!server.release(command, gate: "cancelled"))
            #expect(server.release(try #require(greeting.command), gate: "greeting"))
            let released = try await event(server, .released, connection, occurrence: 1, detail: "early")
            let held = try await event(server, .replyHeld, connection, occurrence: 1, detail: "early")
            #expect(released.sequence < held.sequence)
            _ = try await event(server, .replyHeld, connection, occurrence: 1, detail: "cancelled")
            #expect(server.events.filter { $0.command == command && $0.kind == .released }.count == 1)
            #expect(server.events.filter { $0.command == command && $0.kind == .gateCancelled }.count == 1)
            try raw.expect("prefix")
            // A later command is processed, but the cancelled script has no implicit OK.
            try raw.send("A NOOP\r\n")
            try raw.expect("A OK NOOP completed\r\n")
            let next = try await event(server, .commandReachedServer, connection, occurrence: 2)
            #expect(next.command?.tag == command.tag && next.command != command)
            try raw.finishWriting()
        }
    }

    @Test("script fragments serialize across pipelined commands without interleaving")
    func serializedFragments() async throws {
        let scripts = [
            Server.Script(connectionNumber: 1, occurrence: 1, actions: [
                .send(Data([0, 255, 1]), acknowledgement: "binary-prefix"), .hold("middle"),
                .send(Data("tail".utf8), acknowledgement: "tail"), .taggedCompletion("OK first")
            ]),
            Server.Script(connectionNumber: 1, occurrence: 2, actions: [
                .send(Data("second".utf8), acknowledgement: "second"), .taggedCompletion("OK second")
            ])
        ]
        try await withServer(scripts: scripts) { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            try raw.send("A NOOP\r\nB NOOP\r\n")
            let held = try await event(server, .replyHeld, connection)
            _ = try await event(server, .commandReachedServer, connection, occurrence: 2)
            #expect(try raw.receive(3) == Data([0, 255, 1]))
            #expect(server.release(try #require(held.command), gate: "middle"))
            try raw.expect("tailA OK first\r\nsecondB OK second\r\n")
            _ = try await event(server, .fragmentSent, connection, occurrence: 2, detail: "completion")
            let fragments = server.events.filter { $0.kind == .fragmentSent && ($0.command?.occurrence ?? 0) > 0 }
            #expect(fragments.map(\.detail) == ["binary-prefix", "tail", "completion", "second", "completion"])
            try raw.finishWriting()
        }
    }

}

extension IMAPTestServerControlTests {
    @Test("event history, cancellation, timeout and arrival share a single terminal winner")
    func waiterSettlement() async throws {
        try await withServer { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            // Task cancellation may occur before registration. Immediate timers may race
            // with both cancellation and already-recorded arrivals; every task must settle.
            for index in 0..<32 {
                let label = "wait-\(index)"
                let task = Task {
                    defer { server.mark(.callerSettled, connection: connection, detail: label) }
                    return try await server.waitForEvent(
                        .callerSettled, run: connection.run, connection: connection,
                        detail: label + "-arrival", timeout: index.isMultiple(of: 2) ? 0 : 2,
                        registered: {
                            server.mark(.callerSettled, connection: connection, detail: label + "-registered")
                        })
                }
                _ = try await event(server, .callerSettled, connection, detail: label + "-registered")
                if index.isMultiple(of: 3) {
                    server.mark(.callerSettled, connection: connection, detail: label + "-arrival")
                }
                server.mark(.cancellationRequested, connection: connection, detail: label)
                task.cancel()
                task.cancel()
                server.mark(.callerSettled, connection: connection, detail: label + "-arrival")
                _ = await task.result
                #expect(server.events.filter { $0.kind == .callerSettled && $0.detail == label }.count == 1)
            }
            do {
                _ = try await server.waitForEvent(
                    .replyHeld, run: connection.run, connection: connection, timeout: 0.01)
                Issue.record("missing event should time out")
            } catch { #expect(error as? Server.WaitError == .timedOut) }
            let arrived = server.mark(.callerSettled, connection: connection, detail: "already-arrived")
            let replay = try await event(server, .callerSettled, connection, detail: "already-arrived")
            #expect(arrived.sequence == replay.sequence)
            let pending = Task {
                try await server.waitForEvent(
                    .replyHeld, run: connection.run, connection: connection, detail: "never", registered: {
                        server.mark(.callerSettled, connection: connection, detail: "pending-registered")
                    })
            }
            _ = try await event(server, .callerSettled, connection, detail: "pending-registered")
            try raw.finishWriting()
            _ = try await event(server, .peerEOF, connection)
            do {
                _ = try await pending.value
                Issue.record("EOF should settle outstanding connection waits")
            } catch { #expect(error as? Server.WaitError == .connectionEnded) }
            #expect(server.pendingEventWaiterCount == 0)
        }
    }

    @Test("stop cancels gates and legacy LOGIN delay and allows a clean restart")
    func stopAndRestart() async throws {
        let script = Server.Script(connectionNumber: 1, occurrence: 1, actions: [
            .hold("stopped"), .taggedCompletion("OK must not appear")
        ])
        try await withServer(scripts: [script], loginDelay: 60) { server in
            let oldRun = server.runID
            let first = try RawClient(port: server.port)
            let oldConnection = try await server.waitForEvent(.accepted, run: oldRun).connection
            try first.greeting()
            try first.send("A NOOP\r\n")
            let held = try await event(server, .replyHeld, oldConnection)
            await server.stop()
            #expect(!server.release(try #require(held.command), gate: "stopped"))
            let cancelled = try await event(server, .gateCancelled, oldConnection, detail: "stopped")
            #expect(cancelled.kind == .gateCancelled)
            try server.start()
            let newRun = server.runID
            #expect(newRun != oldRun)
            let second = try RawClient(port: server.port)
            let newConnection = try await server.waitForEvent(.accepted, run: newRun).connection
            #expect(newConnection.number > oldConnection.number)
            #expect(newConnection.run == newRun)
            #expect(!server.release(try #require(held.command), gate: "stopped"))
            try second.greeting()
            try second.send("B NOOP\r\n")
            try second.expect("B OK NOOP completed\r\n")
            do {
                _ = try await server.waitForEvent(.replyHeld, run: newRun, timeout: 0.01)
                Issue.record("a new run must not replay the old held event")
            } catch { #expect(error as? Server.WaitError == .timedOut) }
            try second.send("C LOGIN user pass\r\n")
            _ = try await event(server, .commandReachedServer, newConnection, occurrence: 2)
            await server.stop()
            #expect(!server.events.contains { $0.kind == .fragmentSent && $0.command?.occurrence == 2 })
        }
    }

    @Test("accept versus stop races never strand workers or affect a restarted listener")
    func acceptStopRace() async throws {
        try await withServer { server in
            for _ in 0..<12 {
                let port = server.port
                let connector = Task.detached { () -> Bool in
                    guard let raw = try? RawClient(port: port) else { return false }
                    try? raw.finishWriting()
                    return true
                }
                await server.stop()
                _ = await connector.value
                try server.start()
                let raw = try RawClient(port: server.port)
                let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
                try raw.greeting()
                try raw.send("A NOOP\r\n")
                try raw.expect("A OK NOOP completed\r\n")
                try raw.finishWriting()
                _ = try await event(server, .peerEOF, connection)
            }
        }
    }
}

extension IMAPTestServerControlTests {
    @Test
    func activeOperationCancellationSettlesBeforeHeldReplyAndInvalidatesOnlyItsGeneration() async throws {
        let script = Server.Script(connectionNumber: 1, occurrence: 2, actions: [
            .hold("active-reply"), .taggedCompletion("OK NOOP completed")
        ])
        try await withServer(scripts: [script]) { server in
            try await withEventLoopGroup { group in
                func connection(_ id: String) -> IMAPConnection {
                    IMAPConnection(host: "127.0.0.1", port: server.port, transportSecurity: .plainText,
                                   minimumTLSVersion: .tlsv12, group: group, loggerLabel: "test.cancel",
                                   outboundLabel: "test.cancel.out", inboundLabel: "test.cancel.in",
                                   connectionID: id, connectionRole: "test", parserLimits: .default)
                }
                let primary = connection("primary")
                let sibling = connection("sibling")
                defer { primary.abortNow(); sibling.abortNow() }
                try await primary.connect()
                try await sibling.connect()
                let oldGeneration = primary.lifetime.currentGeneration
                let active = Task { try await primary.noop() }
                let held = try await server.waitForEvent(.replyHeld, run: server.runID, detail: "active-reply")
                let queued = IMAPTestSignal()
                primary.commandQueue.testHooks.didEnqueue = queued.signal
                let collateral = Task { try await primary.noop() }
                await queued.wait()
                active.cancel()
                await #expect(throws: CancellationError.self) { try await authenticationResult(active) }
                await #expect(throws: IMAPConnectionAbortedError.self) {
                    try await authenticationResult(collateral)
                }
                _ = try await server.waitForEvent(.peerEOF, run: server.runID, connection: held.connection)
                #expect(!server.release(try #require(held.command), gate: "active-reply"))
                #expect(server.events.filter {
                    $0.kind == .commandReachedServer && $0.connection == held.connection
                }.count == 2)
                #expect(primary.lifetime.reservationCount == 0)
                _ = try await sibling.noop()
                try await primary.connect()
                #expect(primary.lifetime.currentGeneration != oldGeneration)
                _ = try await primary.noop()
                _ = try await sibling.noop()
            }
        }
    }

    @Test("queued LOGOUT keeps the reader alive to observe FIN behind a held reply")
    func queuedLogoutStillObservesFIN() async throws {
        let script = Server.Script(connectionNumber: 1, occurrence: 1, actions: [
            .hold("noop"), .taggedCompletion("OK NOOP completed")
        ])
        try await withServer(scripts: [script]) { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            try raw.send("A NOOP\r\nB LOGOUT\r\n")
            let held = try await event(server, .replyHeld, connection, occurrence: 1)
            let logout = try await event(server, .commandReachedServer, connection, occurrence: 2)
            #expect(logout.command?.tag == "B")
            #expect(!server.events.contains {
                $0.connection == connection && $0.kind == .workerDrained && $0.detail == "reader"
            })

            try raw.finishWriting()
            let eof = try await event(server, .peerEOF, connection)
            #expect(logout.sequence < eof.sequence)
            #expect(!server.release(try #require(held.command), gate: "noop"))
            _ = try await event(server, .workerDrained, connection, detail: "reader")
            _ = try await event(server, .workerDrained, connection, detail: "writer")
            #expect(!server.events.contains {
                $0.command?.occurrence == 2 && $0.kind == .fragmentSent
            })
        }
    }

    @Test("scripted APPEND and IDLE preserve parser state and LOGOUT flushes queued writes")
    func protocolTransitions() async throws {
        let scripts = [
            Server.Script(connectionNumber: 1, occurrence: 1, actions: [
                .send(Data("+ ready\r\n".utf8), acknowledgement: "continuation"),
                .hold("append"), .taggedCompletion("OK appended")
            ]),
            Server.Script(connectionNumber: 1, occurrence: 2, actions: [
                .send(Data("+ idling\r\n".utf8), acknowledgement: "idle-continuation"),
                .hold("idle"), .taggedCompletion("OK ended")
            ])
        ]
        try await withServer(scripts: scripts) { server in
            let raw = try RawClient(port: server.port)
            let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
            try raw.greeting()
            try raw.send("A APPEND INBOX {3}\r\n")
            try raw.expect("+ ready\r\n")
            let append = try await event(server, .replyHeld, connection, occurrence: 1)
            try raw.send("abc\r\nB IDLE\r\nDONE\r\nC LOGOUT\r\n")
            _ = try await event(server, .commandReachedServer, connection, occurrence: 3)
            #expect(server.appendedMessages == [Data("abc".utf8)])
            #expect(server.idleCommandCount == 1)
            #expect(server.commandLog == ["A APPEND INBOX {3}", "B IDLE", "C LOGOUT"])
            #expect(server.release(try #require(append.command), gate: "append"))
            try raw.expect("A OK appended\r\n+ idling\r\n")
            let idle = try await event(server, .replyHeld, connection, occurrence: 2)
            #expect(server.release(try #require(idle.command), gate: "idle"))
            try raw.expect("B OK ended\r\n* BYE IMAP server shutting down\r\nC OK LOGOUT completed\r\n")
            _ = try await event(server, .workerDrained, connection, detail: "reader")
            _ = try await event(server, .workerDrained, connection, detail: "writer")
        }
    }

    @Test("reset is distinguished from peer FIN and local shutdown")
    func resetIsNotEOF() async throws {
        let script = Server.Script(connectionNumber: 1, occurrence: 1, actions: [.hold("reset")])
        try await withServer(scripts: [script]) { server in
            func resetPeer() async throws -> Server.ConnectionID {
                let raw = try RawClient(port: server.port)
                let connection = try await server.waitForEvent(.accepted, run: server.runID).connection
                try raw.greeting()
                try raw.send("A NOOP\r\n")
                _ = try await event(server, .replyHeld, connection)
                try raw.resetOnClose()
                return connection
            }
            let connection = try await resetPeer()
            _ = try await event(server, .peerReset, connection)
            #expect(!server.events.contains { $0.kind == .peerEOF || $0.kind == .localShutdown })
        }
    }
}
#endif
