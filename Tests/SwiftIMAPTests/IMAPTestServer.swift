// Single-file POSIX-socket IMAP fake server used by integration tests. Splitting
// this into extensions/separate files was tried but introduced a macOS CI hang
// (build-macos exceeded the 10-minute timeout on jobs that consistently passed
// on iOS and Linux). Keeping it as one file with the structural rules disabled
// is the lower-risk choice.
// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
// Raw POSIX sockets, DispatchSource and sockaddr_in.sin_len are only available
// on macOS/Linux; Windows and Android exclude this fake server entirely (the
// integration tests that use it are themselves gated to `#if os(macOS)`).
#if os(macOS) || os(Linux)
import Foundation
import Testing
#if canImport(Glibc)
    import Glibc
#endif

enum IMAPTestError: Error {
    case setup(String)
}

/// A minimal IMAP4rev1 server implemented in Swift using POSIX sockets.
/// Uses POSIX sockets directly since Network.framework doesn't work in the iOS simulator.
/// Lifecycle/connection lookup is isolated to queue, metrics to metricsQueue, event history
/// to controlQueue, and each connection's worker state to its condition lock.
final class IMAPTestServer: @unchecked Sendable {
    struct ConnectionID: Hashable, Sendable {
        let run: UUID
        let number: UInt64
    }

    struct CommandID: Hashable, Sendable {
        let connection: ConnectionID
        /// Zero is the greeting; subsequent commands increase even if tags repeat.
        let occurrence: Int
        let tag: String
    }

    enum EventKind: Sendable {
        case accepted, commandReachedServer, replyHeld, fragmentSent, released, gateCancelled
        case writerBackpressured, peerEOF, peerReset, readFailed, sendFailed, localShutdown, workerDrained
        case cancellationRequested, callerSettled
    }

    struct Event: Sendable {
        let sequence: UInt64
        let uptimeNanoseconds: UInt64
        let connection: ConnectionID
        let command: CommandID?
        let kind: EventKind
        let detail: String
    }

    /// Scripts replace the entire reply. There is no automatic completion after a script.
    /// Use distinct hold names for successive releases. `send` acknowledges a fragment only
    /// after every byte has reached send(2), not when the action is enqueued.
    enum Action: Sendable {
        case hold(String)
        case send(Data, acknowledgement: String)
        case taggedCompletion(String)
        case close
        case delay(TimeInterval)
    }

    struct Script: Sendable {
        /// Monotonically increasing across restarts of this fixture, independent of the fd.
        let connectionNumber: UInt64
        let occurrence: Int
        let actions: [Action]
    }

    enum WaitError: Error, Equatable {
        case timedOut, connectionEnded, runEnded
    }

    private struct EventQuery {
        let run: UUID
        let connection: ConnectionID?
        let kinds: Set<EventKind>
        let occurrence: Int?
        let detail: String?
        let after: UInt64

        func matches(_ event: Event) -> Bool {
            event.connection.run == run && (connection == nil || event.connection == connection)
                && kinds.contains(event.kind) && (occurrence == nil || event.command?.occurrence == occurrence)
                && (detail == nil || event.detail == detail) && event.sequence > after
        }
    }

    /// Cancellation can win before continuation installation. Timer, event and cancellation
    /// all use this same terminal claim, including disposal of the losing timer.
    private final class EventWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Event, Error>?
        private var continuation: CheckedContinuation<Event, Error>?
        private var timer: DispatchSourceTimer?

        func install(_ continuation: CheckedContinuation<Event, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func arm(_ timer: DispatchSourceTimer) {
            lock.lock()
            if result == nil { self.timer = timer } else { timer.cancel() }
            lock.unlock()
            timer.resume()
        }

        @discardableResult
        func finish(_ result: Result<Event, Error>) -> Bool {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return false }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            timer?.cancel()
            timer = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    private let controlQueue = DispatchQueue(label: "IMAPTestServer.controls")
    private var eventStorage: [Event] = []
    private var eventSequence: UInt64 = 0
    private var eventWaiters: [UUID: (EventQuery, EventWaiter)] = [:]
    private var endedConnections: Set<ConnectionID> = []
    private var endedRuns: Set<UUID> = []
    private var failuresStorage: [String] = []
    private let scripts: [Script]
    private let sendBufferSize: Int32?

    var events: [Event] { controlQueue.sync { eventStorage } }
    var fixtureFailures: [String] { controlQueue.sync { failuresStorage } }
    var pendingEventWaiterCount: Int { controlQueue.sync { eventWaiters.count } }
    var runID: UUID { queue.sync { currentRun } }

    /// Always supply the captured run (or connection.run). History is retained, so callers
    /// can register after arrival; `after` permits waiting for a later occurrence of an event.
    func waitForEvent(
        _ kind: EventKind, run: UUID, connection: ConnectionID? = nil,
        occurrence: Int? = nil, detail: String? = nil, after: UInt64 = 0,
        timeout: TimeInterval = 10, registered: (@Sendable () -> Void)? = nil
    ) async throws -> Event {
        try await waitForEvent(
            EventQuery(run: run, connection: connection, kinds: [kind], occurrence: occurrence,
                       detail: detail, after: after),
            timeout: timeout, registered: registered)
    }

    /// Waits until the client closed `connection`, however the server observed it: a FIN, a reset
    /// (closing with unread replies sends RST, notably on Linux) or a failed read. Use this after a
    /// cancel, abort or disconnect; wait for `.peerEOF` only when a clean FIN is what is asserted.
    func waitForConnectionEnd(
        run: UUID, connection: ConnectionID, timeout: TimeInterval = 10
    ) async throws -> Event {
        try await waitForEvent(
            EventQuery(run: run, connection: connection, kinds: [.peerEOF, .peerReset, .readFailed],
                       occurrence: nil, detail: nil, after: 0),
            timeout: timeout, registered: nil)
    }

    private func waitForEvent(
        _ query: EventQuery, timeout: TimeInterval, registered: (@Sendable () -> Void)?
    ) async throws -> Event {
        let token = UUID()
        let waiter = EventWaiter()
        let run = query.run
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                controlQueue.sync {
                    if let event = eventStorage.first(where: query.matches) {
                        waiter.finish(.success(event))
                    } else if endedRuns.contains(run) {
                        waiter.finish(.failure(WaitError.runEnded))
                    } else if let connection = query.connection, endedConnections.contains(connection),
                              !query.kinds.contains(.workerDrained) {
                        waiter.finish(.failure(WaitError.connectionEnded))
                    } else if Task.isCancelled {
                        waiter.finish(.failure(CancellationError()))
                    } else {
                        eventWaiters[token] = (query, waiter)
                        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
                        timer.setEventHandler { [weak self] in
                            self?.eventWaiters.removeValue(forKey: token)?.1.finish(.failure(WaitError.timedOut))
                        }
                        timer.schedule(deadline: .now() + max(0, timeout))
                        waiter.arm(timer)
                    }
                }
                registered?()
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
            self.controlQueue.async { self.eventWaiters.removeValue(forKey: token) }
        }
    }

    /// The identity of the `number`th accepted connection in the current run.
    func connection(_ number: UInt64) -> ConnectionID {
        ConnectionID(run: runID, number: number)
    }

    /// Command lines that reached the server on one connection, in arrival order.
    func commandLines(on connection: ConnectionID) -> [String] {
        events.filter { $0.connection == connection && $0.kind == .commandReachedServer }.map(\.detail)
    }

    @discardableResult
    func mark(_ kind: EventKind, connection: ConnectionID, detail: String) -> Event {
        precondition(kind == .cancellationRequested || kind == .callerSettled)
        return recordEvent(kind, connection: connection, detail: detail)
    }

    @discardableResult
    private func recordEvent(
        _ kind: EventKind, connection: ConnectionID, command: CommandID? = nil, detail: String = ""
    ) -> Event {
        controlQueue.sync {
            eventSequence += 1
            let event = Event(
                sequence: eventSequence, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                connection: connection, command: command, kind: kind, detail: detail)
            eventStorage.append(event)
            for (token, entry) in eventWaiters where entry.0.matches(event) {
                eventWaiters.removeValue(forKey: token)
                entry.1.finish(.success(event))
            }
            if kind == .peerEOF || kind == .peerReset || kind == .readFailed
                || kind == .sendFailed || kind == .localShutdown {
                endedConnections.insert(connection)
                for (token, entry) in eventWaiters
                where entry.0.connection == connection && !entry.0.kinds.contains(.workerDrained) {
                    eventWaiters.removeValue(forKey: token)
                    entry.1.finish(.failure(WaitError.connectionEnded))
                }
            }
            return event
        }
    }

    @discardableResult
    func release(_ command: CommandID, gate: String) -> Bool {
        queue.sync { connections[command.connection] }?.settleGate(command, name: gate, released: true) ?? false
    }

    @discardableResult
    func cancelGate(_ command: CommandID, gate: String) -> Bool {
        queue.sync { connections[command.connection] }?.settleGate(command, name: gate, released: false) ?? false
    }

    enum PartialFetchBehavior {
        case honor
        case ignoreRange
        case wrongOffset
        case rejectWithBad
        case rejectWithNo
    }

    struct Message {
        let uid: Int
        let raw: Data
        let subject: String
        let from: String
        let to: String
        let cc: String
        let bcc: String
        let date: String
        let internalDate: String  // IMAP format: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
        let messageID: String
        let contentType: String
        let charset: String
        let body: Data
        let headerData: Data
    }

    let host: String
    let username: String
    let password: String
    private var portStorage: Int
    var port: Int { queue.sync { portStorage } }

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "IMAPTestServer")
    private let messages: [Message]
    private let advertisedCapabilities: [String]
    private let loginResponseDelay: TimeInterval
    private let rejectedUIDSubcommand: String?
    private let copyUIDSourceOverride: String?
    private let personalNamespacePrefix: String
    private let namespaceDelimiter: Character
    private let partialFetchBehavior: PartialFetchBehavior
    private let withholdsLiteralContinuation: Bool
    private let withheldLiteralReply: String?
    private let bodystructureOverride: String?
    private let mimeHeaders: [String: String]
    private let rejectsMIMEHeaderFetch: Bool
    private let listedMailboxNames: [String]
    private let otherUsersNamespacePrefix: String?
    private let refusedListPatterns: [String: String]
    private let matchesListPatterns: Bool
    private let metricsQueue = DispatchQueue(label: "IMAPTestServer.metrics")
    private var idleCommandCountStorage = 0
    private var commandLogStorage: [String] = []
    private var connections: [ConnectionID: Connection] = [:]
    private var clientGroup = DispatchGroup()
    private var isStopping = false
    private var currentRun = UUID()
    private var nextConnectionNumber: UInt64 = 0

    init(
        host: String = "localhost",
        port: Int = 0,
        username: String = "testuser",
        password: String = "testpass",
        loginResponseDelay: TimeInterval = 0,
        rejectedUIDSubcommand: String? = nil,
        copyUIDSourceOverride: String? = nil,
        advertisedCapabilities: [String] = [
            "IMAP4rev1", "AUTH=PLAIN", "LITERAL+", "ID", "NAMESPACE", "UIDPLUS", "IDLE"
        ],
        personalNamespacePrefix: String = "",
        namespaceDelimiter: Character = "/",
        partialFetchBehavior: PartialFetchBehavior = .honor,
        withholdsLiteralContinuation: Bool = false,
        withheldLiteralReply: String? = nil,
        bodystructureOverride: String? = nil,
        mimeHeaders: [String: String] = [:],
        rejectsMIMEHeaderFetch: Bool = false,
        listedMailboxNames: [String] = ["INBOX"],
        otherUsersNamespacePrefix: String? = nil,
        refusedListPatterns: [String: String] = [:],
        matchesListPatterns: Bool = false,
        scripts: [Script] = [],
        sendBufferSize: Int32? = nil,
        maildirURL: URL
    ) throws {
        self.host = host
        self.portStorage = port
        self.username = username
        self.password = password
        self.loginResponseDelay = loginResponseDelay
        self.rejectedUIDSubcommand = rejectedUIDSubcommand?.uppercased()
        self.copyUIDSourceOverride = copyUIDSourceOverride
        self.advertisedCapabilities = advertisedCapabilities
        self.personalNamespacePrefix = personalNamespacePrefix
        self.namespaceDelimiter = namespaceDelimiter
        self.partialFetchBehavior = partialFetchBehavior
        self.withholdsLiteralContinuation = withholdsLiteralContinuation
        self.withheldLiteralReply = withheldLiteralReply
        self.bodystructureOverride = bodystructureOverride
        self.mimeHeaders = mimeHeaders
        self.rejectsMIMEHeaderFetch = rejectsMIMEHeaderFetch
        self.listedMailboxNames = listedMailboxNames
        self.otherUsersNamespacePrefix = otherUsersNamespacePrefix
        self.refusedListPatterns = refusedListPatterns
        self.matchesListPatterns = matchesListPatterns
        self.scripts = scripts
        self.sendBufferSize = sendBufferSize
        self.messages = try Self.loadMaildir(maildirURL)
    }

    /// RFC 3501 §6.3.8 LIST matching: `*` matches anything, `%` anything but the delimiter `/`,
    /// and INBOX is case-insensitive.
    static func listPattern(_ pattern: String, matches name: String) -> Bool {
        func matches(_ pattern: Substring, _ name: Substring) -> Bool {
            guard let first = pattern.first else { return name.isEmpty }
            let rest = pattern.dropFirst()
            switch first {
                case "*":
                    return name.indices.contains { matches(rest, name[$0...]) } || matches(rest, name[name.endIndex...])
                case "%":
                    if matches(rest, name) { return true }
                    guard let next = name.first, next != "/" else { return false }
                    return matches(pattern, name.dropFirst())
                default:
                    guard name.first == first else { return false }
                    return matches(rest, name.dropFirst())
            }
        }
        func canonical(_ value: String) -> String {
            value.uppercased() == "INBOX" ? "INBOX" : value
        }
        return matches(Substring(canonical(pattern)), Substring(canonical(name)))
    }

    var idleCommandCount: Int {
        metricsQueue.sync { idleCommandCountStorage }
    }

    var commandLog: [String] {
        metricsQueue.sync { commandLogStorage }
    }

    private func recordIdleCommand() {
        metricsQueue.sync { idleCommandCountStorage += 1 }
    }

    /// Number of ID commands received across all connections. Lets tests verify
    /// the RFC 2971 replay actually reached the wire after authentication.
    var idCommandCount: Int {
        metricsQueue.sync { idCommandCountStorage }
    }

    private var idCommandCountStorage = 0

    private func recordIDCommand() {
        metricsQueue.sync { idCommandCountStorage += 1 }
    }

    private func recordCommand(_ line: String) {
        metricsQueue.sync { commandLogStorage.append(line) }
    }

    /// The message literal of every APPEND received, in order.
    var appendedMessages: [Data] {
        metricsQueue.sync { appendedMessagesStorage }
    }

    private var appendedMessagesStorage: [Data] = []

    private func recordAppendedMessage(_ message: Data) {
        metricsQueue.sync { appendedMessagesStorage.append(message) }
    }

    var lastExaminedMailbox: String? {
        metricsQueue.sync { lastExaminedMailboxStorage }
    }

    private var lastExaminedMailboxStorage: String?

    private func recordExaminedMailbox(_ mailbox: String) {
        metricsQueue.sync { lastExaminedMailboxStorage = mailbox }
    }

    /// Total connections ever accepted. Catches re-dials that never reach an
    /// IDLE command (connect + LOGIN + SELECT and then exit), which
    /// `idleCommandCount` alone cannot see.
    var acceptedConnectionCount: Int {
        metricsQueue.sync { acceptedConnectionCountStorage }
    }

    private var acceptedConnectionCountStorage = 0

    private func recordAcceptedConnection() {
        metricsQueue.sync { acceptedConnectionCountStorage += 1 }
    }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    private func startOnQueue() throws {
        guard listenFd < 0, !isStopping, connections.isEmpty else {
            throw IMAPTestError.setup("previous server run has not drained")
        }
        currentRun = UUID()
        clientGroup = DispatchGroup()

        #if os(Linux)
            listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            listenFd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listenFd >= 0 else {
            throw IMAPTestError.setup("socket() failed: \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if !os(Linux)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(portStorage).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            listenFd = -1
            throw IMAPTestError.setup("bind() failed: \(errno)")
        }

        guard listen(listenFd, 5) == 0 else {
            close(listenFd)
            listenFd = -1
            throw IMAPTestError.setup("listen() failed: \(errno)")
        }

        // Get actual port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFd, $0, &addrLen)
            }
        }
        self.portStorage = Int(UInt16(bigEndian: boundAddr.sin_port))

        // Set up accept dispatch source
        let listener = listenFd
        let run = currentRun
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient(listener: listener, run: run)
        }
        let group = clientGroup
        group.enter()
        source.setCancelHandler {
            // The captured fd belongs to this source, never to a subsequent run.
            close(listener)
            group.leave()
        }
        self.acceptSource = source
        source.resume()
    }

    private struct StopSnapshot {
        let run: UUID
        let clients: [Connection]
        let group: DispatchGroup
    }

    /// Stops the server and awaits the client handlers' drain.
    ///
    /// Async on purpose: the drain used to be `clientGroup.wait(timeout: 2s)`, which parks the
    /// calling thread — from a swift-testing test that is a cooperative-pool thread, one of ncpu
    /// on a core-constrained CI runner. The unbounded sibling of that pattern (blocking ELG
    /// shutdown in `SMTPServer.deinit`) deadlocked the 3-core macOS runner outright. Here the
    /// continuation is resumed from `DispatchGroup.notify` when the last handler leaves — same
    /// determinism, same 2-second upper bound, zero threads parked.
    func stop() async {
        let snapshot = queue.sync {
            isStopping = true
            acceptSource?.cancel()
            acceptSource = nil
            listenFd = -1
            return StopSnapshot(run: currentRun, clients: Array(connections.values), group: clientGroup)
        }
        for client in snapshot.clients { client.terminate(.localShutdown) }
        let drained = await awaitClientDrain(snapshot.group, timeoutSeconds: 2)
        controlQueue.sync {
            endedRuns.insert(snapshot.run)
            for (token, entry) in eventWaiters where entry.0.run == snapshot.run {
                eventWaiters.removeValue(forKey: token)
                entry.1.finish(.failure(WaitError.runEnded))
            }
            if !drained { failuresStorage.append("server workers exceeded the two-second drain bound") }
        }
        if !drained {
            Issue.record("IMAPTestServer workers exceeded the two-second drain bound; descriptors retained")
        }
        queue.sync { if currentRun == snapshot.run, drained { isStopping = false } }
    }

    /// Runs `body`, then stops the server — on success and on throw alike. The scoped
    /// replacement for `defer { stop() }`, which cannot await an async `stop()`.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            await stop()
            return result
        } catch {
            await stop()
            throw error
        }
    }

    /// Resumes when the last client handler leaves `clientGroup`, or after `timeoutSeconds` —
    /// whichever comes first. Both paths arrive as GCD callbacks; nothing blocks anywhere.
    private func awaitClientDrain(_ group: DispatchGroup, timeoutSeconds: Double) async -> Bool {
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.setEventHandler {
                if once.claim() { continuation.resume(returning: false) }
                timer.setEventHandler(handler: nil)
                timer.cancel()
            }
            timer.schedule(deadline: .now() + timeoutSeconds)
            group.notify(queue: .global()) {
                if once.claim() { continuation.resume(returning: true) }
                timer.setEventHandler(handler: nil)
                timer.cancel()
            }
            timer.resume()
        }
    }

    // MARK: - Connection Handling

    private func acceptClient(listener: Int32, run: UUID) {
        guard !isStopping, currentRun == run, listenFd == listener else { return }
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        // Set descriptor-level nonblocking mode as well as MSG_DONTWAIT: on Darwin a
        // large send can otherwise stay inside the syscall after making partial progress.
        _ = fcntl(clientFd, F_SETFL, O_NONBLOCK)
        #if os(macOS)
            var noSigPipe: Int32 = 1
            setsockopt(
                clientFd, SOL_SOCKET, SO_NOSIGPIPE,
                &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
            )
        #endif
        if var size = sendBufferSize {
            setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        nextConnectionNumber += 1
        let identity = ConnectionID(run: run, number: nextConnectionNumber)
        let client: Connection
        do {
            client = try Connection(fd: clientFd, id: identity) { [weak self] kind, command, detail in
                self?.recordEvent(kind, connection: identity, command: command, detail: detail)
            }
        } catch {
            close(clientFd)
            controlQueue.sync { failuresStorage.append("connection wakeup pipe failed: \(error)") }
            Issue.record("IMAPTestServer connection setup failed: \(error)")
            return
        }
        connections[identity] = client
        recordAcceptedConnection()
        recordEvent(.accepted, connection: identity)

        // Each client gets its own thread, as its handler blocks in read() for the
        // whole connection. On a GCD global queue it would take one of the
        // process's 64 constrained workers, and GCD starts none while ncpu of
        // them are busy: in a full parallel run on a 3-core runner a new client
        // could wait past the client's 5-second greeting deadline.
        let clientGroup = clientGroup
        clientGroup.enter()
        clientGroup.enter()
        let reader = Thread {
            self.handleClient(client)
            self.finishWorker(client, name: "reader", group: clientGroup)
        }
        let writer = Thread {
            client.writeReplies()
            self.finishWorker(client, name: "writer", group: clientGroup)
        }
        reader.name = "IMAPTestServer reader"
        writer.name = "IMAPTestServer writer"
        reader.start()
        writer.start()
    }

    private func finishWorker(_ client: Connection, name: String, group: DispatchGroup) {
        let last = client.workerExited(name)
        if last { queue.sync { _ = connections.removeValue(forKey: client.id) } }
        group.leave()
    }

    private func actions(for command: CommandID) -> [Action]? {
        scripts.first {
            $0.connectionNumber == command.connection.number && $0.occurrence == command.occurrence
        }?.actions
    }

    private func handleClient(_ client: Connection) {
        let fileDescriptor = client.descriptor
        var occurrence = 0
        var currentCommand = CommandID(connection: client.id, occurrence: 0, tag: "*")
        func reply(_ text: String) {
            guard actions(for: currentCommand) == nil else { return }
            client.enqueue(currentCommand, actions: [.send(Data(text.utf8), acknowledgement: "reply")])
        }

        // Send greeting
        client.enqueue(currentCommand, actions: actions(for: currentCommand) ?? [
            .send(Data("* OK IMAP test server ready\r\n".utf8), acknowledgement: "greeting")
        ])

        var buffer = Data()
        var authenticated = false
        var selectedMailbox: String?
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        var idleCommand: CommandID?  // non-nil while in IDLE state
        var appendLiteral: (command: CommandID, size: Int)?
        var appendCommand: CommandID?  // literal arrived, awaiting its line end
        var commandInputEnded = false

        while true {
            let bytesRead = read(fileDescriptor, readBuf, 65536)
            if bytesRead == 0 { client.terminate(.peerEOF); break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if client.waitForReadable() { continue }
                    break
                }
                client.terminate(errno == ECONNRESET ? .peerReset : .readFailed, detail: "\(errno)")
                break
            }
            buffer.append(readBuf, count: bytesRead)
            if commandInputEnded {
                buffer.removeAll(keepingCapacity: true)
                continue
            }

            while true {
                if let pending = appendLiteral {
                    guard buffer.count >= pending.size else { break }
                    recordAppendedMessage(Data(buffer.prefix(pending.size)))
                    buffer = Data(buffer.dropFirst(pending.size))
                    appendLiteral = nil
                    appendCommand = pending.command
                    continue
                }
                guard let crlfRange = buffer.range(of: Data("\r\n".utf8)) else { break }
                let lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                buffer = Data(buffer[crlfRange.upperBound...])

                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                // The line end after an APPEND literal completes the command.
                if let command = appendCommand {
                    appendCommand = nil
                    currentCommand = command
                    reply("\(command.tag) OK APPEND completed\r\n")
                    continue
                }

                // Handle DONE (untagged) while in IDLE state
                if let command = idleCommand, line.uppercased() == "DONE" {
                    currentCommand = command
                    reply("\(command.tag) OK IDLE terminated\r\n")
                    idleCommand = nil
                    continue
                }

                occurrence += 1
                currentCommand = CommandID(
                    connection: client.id, occurrence: occurrence,
                    tag: line.split(separator: " ").first.map(String.init) ?? "*")
                recordCommand(line)
                recordEvent(.commandReachedServer, connection: client.id, command: currentCommand, detail: line)
                if let script = actions(for: currentCommand) {
                    client.enqueue(currentCommand, actions: script)
                }

                // A synchronizing literal (`{N}`) waits for our `+`; a server that
                // never sends it leaves the client's write pending.
                if withholdsLiteralContinuation,
                   line.range(of: #"\{\d+\}$"#, options: .regularExpression) != nil {
                    // Optionally answer with something other than `+` (`{tag}` is
                    // replaced by the command's tag), keeping the socket open.
                    if withheldLiteralReply == "{close}" {
                        if actions(for: currentCommand) == nil {
                            client.enqueue(currentCommand, actions: [.close])
                        }
                        return
                    }
                    if let withheldReply = withheldLiteralReply {
                        let tag = line.split(separator: " ").first.map(String.init) ?? "*"
                        reply(withheldReply.replacingOccurrences(of: "{tag}", with: tag))
                    }
                    continue
                }

                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    reply("* BAD Invalid command\r\n")
                    continue
                }

                let tag = parts[0]
                let command = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""

                if command == "APPEND",
                   let match = line.range(of: #"\{\d+\+?\}$"#, options: .regularExpression) {
                    let literal = line[match].dropFirst().dropLast()
                    let synchronizing = !literal.hasSuffix("+")
                    appendLiteral = (currentCommand, Int(literal.filter(\.isNumber)) ?? 0)
                    if synchronizing {
                        reply("+ Ready for literal data\r\n")
                    }
                    continue
                }

                if command == "IDLE" {
                    recordIdleCommand()
                    reply("+ idling\r\n")
                    idleCommand = currentCommand
                    continue
                }

                if let data = fetchReply(tag: tag, command: command, args: args, selectedMailbox: selectedMailbox) {
                    if actions(for: currentCommand) == nil {
                        client.enqueue(currentCommand, actions: [.send(data, acknowledgement: "reply")])
                    }
                    continue
                }

                let response = handleCommand(
                    tag: tag,
                    command: command,
                    args: args,
                    authenticated: &authenticated,
                    selectedMailbox: &selectedMailbox
                )
                var responseActions: [Action] = []
                if command == "LOGIN", loginResponseDelay > 0 { responseActions.append(.delay(loginResponseDelay)) }
                responseActions.append(.send(Data(response.utf8), acknowledgement: "reply"))
                if command == "LOGOUT" { responseActions.append(.close) }
                if actions(for: currentCommand) == nil { client.enqueue(currentCommand, actions: responseActions) }

                if command == "LOGOUT" {
                    // LOGOUT's close action can be queued behind a gated reply. Stop parsing
                    // commands, but keep the sole reader alive so peer FIN/reset can cancel
                    // the gate and unsent LOGOUT reply before the writer reaches `.close`.
                    commandInputEnded = true
                    buffer.removeAll(keepingCapacity: true)
                    break
                }
            }
        }
    }

    private struct GateKey: Hashable {
        let command: CommandID
        let name: String
    }

    /// Owns all three descriptors until both workers exit. No server/control lock is held
    /// while waiting on a gate, a delay or socket writability. The reader alone calls read.
    private final class Connection {
        let descriptor: Int32
        let id: ConnectionID
        private let wakeRead: Int32
        private let wakeWrite: Int32
        private let condition = NSCondition()
        private var cancelled = false
        private var workers = 2
        private var replies: [(CommandID, [Action])] = []
        private var gates: [GateKey: Bool] = [:]
        private let emit: (EventKind, CommandID?, String) -> Void

        init(fd fileDescriptor: Int32, id: ConnectionID,
             emit: @escaping (EventKind, CommandID?, String) -> Void) throws {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw IMAPTestError.setup("pipe: \(errno)") }
            descriptor = fileDescriptor
            self.id = id
            self.emit = emit
            wakeRead = descriptors[0]
            wakeWrite = descriptors[1]
            _ = fcntl(wakeWrite, F_SETFL, O_NONBLOCK)
        }

        func enqueue(_ command: CommandID, actions: [Action]) {
            condition.lock()
            if !cancelled { replies.append((command, actions)); condition.signal() }
            condition.unlock()
        }

        @discardableResult
        func settleGate(_ command: CommandID, name: String, released: Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let key = GateKey(command: command, name: name)
            guard !cancelled, gates[key] == nil else { return false }
            gates[key] = released
            emit(released ? .released : .gateCancelled, command, name)
            condition.broadcast()
            return true
        }

        func terminate(_ reason: EventKind, detail: String = "") {
            condition.lock()
            defer { condition.unlock() }
            // read()==0 after our own shutdown is deliberately not called peer EOF.
            guard !cancelled else { return }
            cancelled = true
            emit(reason, nil, detail)
            replies.removeAll()
            condition.broadcast()
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
            shutdown(descriptor, Int32(SHUT_RDWR))
        }

        func workerExited(_ name: String) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            workers -= 1
            if workers == 0 {
                close(descriptor)
                close(wakeRead)
                close(wakeWrite)
            }
            emit(.workerDrained, nil, name)
            return workers == 0
        }

        private func nextReply() -> (CommandID, [Action])? {
            condition.lock()
            defer { condition.unlock() }
            while replies.isEmpty, !cancelled { condition.wait() }
            return cancelled ? nil : replies.removeFirst()
        }

        private var isCancelled: Bool {
            condition.lock()
            defer { condition.unlock() }
            return cancelled
        }

        func waitForReadable() -> Bool {
            while !isCancelled {
                var descriptors = [
                    pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
                ]
                let result = poll(&descriptors, 2, 100)
                if result > 0 { return !isCancelled }
                if result < 0, errno != EINTR {
                    terminate(.readFailed, detail: "poll: \(errno)")
                    return false
                }
            }
            return false
        }

        private func hold(_ name: String, command: CommandID) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let key = GateKey(command: command, name: name)
            emit(.replyHeld, command, name)
            while gates[key] == nil, !cancelled { condition.wait() }
            if cancelled, gates[key] == nil {
                gates[key] = false
                emit(.gateCancelled, command, name)
            }
            return !cancelled && gates[key] == true
        }

        private func delay(_ seconds: TimeInterval) -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
            condition.lock()
            defer { condition.unlock() }
            while !cancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline { return true }
                _ = condition.wait(until: Date(timeIntervalSinceNow: Double(deadline - now) / 1_000_000_000))
            }
            return false
        }

        func writeReplies() {
            while let (command, actions) = nextReply() {
                if !writeReply(command, actions: actions) { return }
            }
        }

        func writeReply(_ command: CommandID, actions: [Action]) -> Bool {
            for action in actions {
                if isCancelled { return false }
                switch action {
                    case .hold(let name):
                        // A cancelled gate discards the batch, including any completion.
                        if !hold(name, command: command) { return !isCancelled }
                    case .send(let data, let acknowledgement):
                        guard sendBytes(data, command: command) else { return false }
                        emit(.fragmentSent, command, acknowledgement)
                    case .taggedCompletion(let text):
                        let data = Data("\(command.tag) \(text)\r\n".utf8)
                        guard sendBytes(data, command: command) else { return false }
                        emit(.fragmentSent, command, "completion")
                    case .delay(let seconds):
                        if !delay(seconds) { return false }
                    case .close:
                        terminate(.localShutdown)
                        return false
                }
            }
            return true
        }

        private func sendBytes(_ data: Data, command: CommandID) -> Bool {
            data.withUnsafeBytes { buffer in
                guard let pointer = buffer.baseAddress else { return true }
                var sent = 0
                var reportedBackpressure = false
                while sent < data.count, !isCancelled {
                    #if os(Linux)
                        let flags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
                    #else
                        let flags = Int32(MSG_DONTWAIT)
                    #endif
                    let count = send(descriptor, pointer + sent, data.count - sent, flags)
                    if count > 0 { sent += count; continue }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        if !reportedBackpressure {
                            emit(.writerBackpressured, command, "\(sent)")
                            reportedBackpressure = true
                        }
                        var descriptors = [
                            pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
                        ]
                        let result = poll(&descriptors, 2, 100)
                        if result >= 0 || errno == EINTR { continue }
                    }
                    terminate(.sendFailed, detail: "\(errno)")
                    return false
                }
                return sent == data.count && !isCancelled
            }
        }
    }

    // MARK: - Command Handling

    private func handleCommand(
        tag: String,
        command: String,
        args: String,
        authenticated: inout Bool,
        selectedMailbox: inout String?
    ) -> String {
        switch command {
            case "CAPABILITY":
                return "* CAPABILITY \(advertisedCapabilities.joined(separator: " "))\r\n"
                    + "\(tag) OK CAPABILITY completed\r\n"
            case "LOGIN":
                authenticated = true
                return "\(tag) OK LOGIN completed\r\n"
            case "SELECT":
                guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
                let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
                selectedMailbox = mailbox
                let count = messages.count
                let uidnext = (messages.last?.uid ?? 0) + 1
                return "* \(count) EXISTS\r\n* 0 RECENT\r\n"
                    + "* OK [UIDVALIDITY 1] UIDs valid\r\n"
                    + "* OK [UIDNEXT \(uidnext)] Predicted next UID\r\n"
                    + "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n"
                    + "* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)]"
                    + " Flags permitted\r\n"
                    + "\(tag) OK [READ-WRITE] SELECT completed\r\n"
            case "EXAMINE":
                guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
                let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
                recordExaminedMailbox(mailbox)
                selectedMailbox = mailbox
                let count = messages.count
                let uidnext = (messages.last?.uid ?? 0) + 1
                return "* \(count) EXISTS\r\n* 0 RECENT\r\n"
                    + "* OK [UIDVALIDITY 1] UIDs valid\r\n"
                    + "* OK [UIDNEXT \(uidnext)] Predicted next UID\r\n"
                    + "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n"
                    + "* OK [PERMANENTFLAGS ()] No permanent flags permitted\r\n"
                    + "\(tag) OK [READ-ONLY] EXAMINE completed\r\n"
            case "UID":
                guard selectedMailbox != nil else { return "\(tag) NO No mailbox selected\r\n" }
                return handleUID(tag: tag, args: args)
            case "FETCH":
                // With a mailbox selected, fetchReply answers.
                return "\(tag) NO No mailbox selected\r\n"
            case "NAMESPACE":
                let otherUsers = otherUsersNamespacePrefix
                    .map { "((\"\($0)\" \"\(namespaceDelimiter)\"))" } ?? "NIL"
                return "* NAMESPACE ((\"\(personalNamespacePrefix)\" \"\(namespaceDelimiter)\")) "
                    + "\(otherUsers) NIL\r\n"
                    + "\(tag) OK NAMESPACE completed\r\n"
            case "LIST":
                // The pattern is the last argument: LIST "" "<pattern>".
                let pattern = args.split(separator: " ").last
                    .map { $0.trimmingCharacters(in: .init(charactersIn: "\"")) }
                if let pattern, let reason = refusedListPatterns[pattern] {
                    return "\(tag) NO \(reason)\r\n"
                }
                // Every name in one write, so the client decodes them from a single read.
                let names = matchesListPatterns
                    ? listedMailboxNames.filter { Self.listPattern(pattern ?? "", matches: $0) }
                    : listedMailboxNames
                return names.map { "* LIST (\\HasNoChildren) \"/\" \"\($0)\"\r\n" }.joined()
                    + "\(tag) OK LIST completed\r\n"
            case "ID":
                recordIDCommand()
                return "* ID NIL\r\n\(tag) OK ID completed\r\n"
            case "STATUS":
                guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
                return statusReply(tag: tag, args: args)
            case "NOOP":
                return "\(tag) OK NOOP completed\r\n"
            case "EXPUNGE":
                return "\(tag) OK EXPUNGE completed\r\n"
            case "LOGOUT":
                return "* BYE IMAP server shutting down\r\n\(tag) OK LOGOUT completed\r\n"
            default:
                return "\(tag) BAD Unknown command \(command)\r\n"
        }
    }

    /// RFC 3501 §6.3.10 STATUS: answers exactly the base data items the client asked for
    /// (MESSAGES, RECENT, UNSEEN, UIDNEXT, UIDVALIDITY), whatever the advertised capabilities.
    private func statusReply(tag: String, args: String) -> String {
        guard let open = args.firstIndex(of: "("), let close = args.lastIndex(of: ")"), open < close else {
            return "\(tag) BAD Invalid STATUS\r\n"
        }
        let mailbox = args[..<open].trimmingCharacters(in: .init(charactersIn: "\" "))
        let uidnext = (messages.last?.uid ?? 0) + 1
        let values: [String: Int] = [
            "MESSAGES": messages.count, "RECENT": 0, "UNSEEN": messages.count,
            "UIDNEXT": uidnext, "UIDVALIDITY": 1
        ]
        let items = args[args.index(after: open)..<close].split(separator: " ").map { $0.uppercased() }
        let answered = items.compactMap { item in values[item].map { "\(item) \($0)" } }
        return "* STATUS \"\(mailbox)\" (\(answered.joined(separator: " ")))\r\n"
            + "\(tag) OK STATUS completed\r\n"
    }

    private func handleUID(tag: String, args: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard let subcmd = parts.first?.uppercased() else {
            return "\(tag) BAD Missing UID subcommand\r\n"
        }
        let subargs = parts.count > 1 ? parts[1] : ""
        if subcmd == rejectedUIDSubcommand {
            return "\(tag) NO Injected UID \(subcmd) failure\r\n"
        }
        switch subcmd {
            case "SEARCH":
                let uids = messages.map { String($0.uid) }.joined(separator: " ")
                return "* SEARCH \(uids)\r\n\(tag) OK UID SEARCH completed\r\n"
            case "MOVE":
                guard advertisesCapability("MOVE") else {
                    return "\(tag) BAD UID MOVE not supported\r\n"
                }
                let moveParts = subargs.split(separator: " ", maxSplits: 1).map(String.init)
                guard moveParts.count == 2 else { return "\(tag) BAD Invalid UID MOVE\r\n" }
                if advertisesCapability("UIDPLUS") {
                    let sourceUIDs = copyUIDSourceOverride ?? moveParts[0]
                    return "\(tag) OK [COPYUID 2 \(sourceUIDs) 101] UID MOVE completed\r\n"
                }
                return "\(tag) OK UID MOVE completed\r\n"
            case "COPY":
                let copyParts = subargs.split(separator: " ", maxSplits: 1).map(String.init)
                guard copyParts.count == 2 else { return "\(tag) BAD Invalid UID COPY\r\n" }
                if advertisesCapability("UIDPLUS") {
                    let sourceUIDs = copyUIDSourceOverride ?? copyParts[0]
                    return "\(tag) OK [COPYUID 2 \(sourceUIDs) 101] UID COPY completed\r\n"
                }
                return "\(tag) OK UID COPY completed\r\n"
            case "STORE":
                return "\(tag) OK UID STORE completed\r\n"
            case "EXPUNGE":
                return "\(tag) OK UID EXPUNGE completed\r\n"
            default:
                return "\(tag) BAD Unknown UID subcommand\r\n"
        }
    }

    private func advertisesCapability(_ expected: String) -> Bool {
        advertisedCapabilities.contains { capability in
            capability.utf8.elementsEqual(expected.lowercased().utf8) { candidate, expectedByte in
                (candidate | 0x20) == expectedByte
            }
        }
    }

    /// The reply to FETCH or UID FETCH in a selected mailbox, as bytes: its literals
    /// carry the stored message bytes, which need not be UTF-8. Nil for any other
    /// command, which `handleCommand` answers.
    private func fetchReply(tag: String, command: String, args: String, selectedMailbox: String?) -> Data? {
        guard selectedMailbox != nil else { return nil }
        if command == "FETCH" {
            return handleFetch(tag: tag, args: args, uidMode: false)
        }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard command == "UID", parts.first?.uppercased() == "FETCH", rejectedUIDSubcommand != "FETCH" else {
            return nil
        }
        return handleFetch(tag: tag, args: parts.count > 1 ? parts[1] : "", uidMode: true)
    }

    /// `name {count}` and the bytes, an IMAP literal.
    private static func literal(_ name: String, _ bytes: Data) -> Data {
        Data("\(name) {\(bytes.count)}\r\n".utf8) + bytes
    }

    private func handleFetch(tag: String, args: String, uidMode: Bool) -> Data {
        let seqStr: String
        let itemsStr: String

        if let parenOpen = args.firstIndex(of: "("),
           let parenClose = args.lastIndex(of: ")") {
            seqStr = String(args[args.startIndex..<parenOpen]).trimmingCharacters(in: .whitespaces)
            itemsStr = String(args[args.index(after: parenOpen)..<parenClose]).uppercased()
        } else {
            let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
            guard fetchParts.count == 2 else { return Data("\(tag) BAD Invalid FETCH arguments\r\n".utf8) }
            seqStr = fetchParts[0]
            itemsStr = fetchParts[1].uppercased()
        }

        let matched = parseSequenceSet(seqStr, uidMode: uidMode)
        let partialRequest = parsePartialBodyRequest(itemsStr)
        if partialRequest != nil {
            switch partialFetchBehavior {
                case .rejectWithBad:
                    return Data("\(tag) BAD Partial FETCH ranges are unsupported\r\n".utf8)
                case .rejectWithNo:
                    return Data("\(tag) NO Partial FETCH is temporarily unavailable\r\n".utf8)
                default:
                    break
            }
        }
        let headerFieldNames = parseHeaderFieldNames(itemsStr)
        let mimeSections = parseMIMEHeaderSections(itemsStr)
        if !mimeSections.isEmpty, rejectsMIMEHeaderFetch {
            return Data("\(tag) NO MIME header fetch is unavailable\r\n".utf8)
        }
        var response = Data()

        for msg in matched {
            let seqnum = (messages.firstIndex(where: { $0.uid == msg.uid }) ?? 0) + 1
            var fetchItems: [Data] = []

            if itemsStr.contains("UID") || uidMode {
                fetchItems.append(Data("UID \(msg.uid)".utf8))
            }
            if itemsStr.contains("FLAGS") {
                fetchItems.append(Data("FLAGS (\\Seen)".utf8))
            }
            if itemsStr.contains("ENVELOPE") {
                fetchItems.append(Data("ENVELOPE \(buildEnvelope(msg))".utf8))
            }
            if itemsStr.contains("INTERNALDATE") {
                fetchItems.append(Data("INTERNALDATE \"\(msg.internalDate)\"".utf8))
            }
            if itemsStr.contains("RFC822.SIZE") {
                fetchItems.append(Data("RFC822.SIZE \(msg.raw.count)".utf8))
            }
            if itemsStr.contains("BODYSTRUCTURE") {
                fetchItems.append(Data("BODYSTRUCTURE \(bodystructureOverride ?? buildBodystructure(msg))".utf8))
            }
            for section in mimeSections {
                if let header = mimeHeaders[section] {
                    fetchItems.append(Self.literal("BODY[\(section).MIME]", Data(header.utf8)))
                }
            }
            if let request = partialRequest, request.section == "1" {
                fetchItems.append(partialBodyFetchItem(request, body: msg.body))
            }
            if partialRequest == nil,
               itemsStr.contains("BODY.PEEK[1]") || itemsStr.contains("BODY[1]") {
                fetchItems.append(Self.literal("BODY[1]", msg.body))
            }
            if itemsStr.contains("BODY[]") || itemsStr.contains("BODY.PEEK[]") {
                fetchItems.append(Self.literal("BODY[]", msg.raw))
            }
            if itemsStr.contains("BODY[HEADER]") || itemsStr.contains("BODY.PEEK[HEADER]") {
                fetchItems.append(Self.literal("BODY[HEADER]", msg.headerData))
            }
            if let names = headerFieldNames {
                let block = Self.headerFieldsBlock(msg.headerData, names: names)
                let echoed = names.joined(separator: " ")
                fetchItems.append(Self.literal("BODY[HEADER.FIELDS (\(echoed))]", Data(block.utf8)))
            }
            if itemsStr.contains("BODY[TEXT]") || itemsStr.contains("BODY.PEEK[TEXT]") {
                fetchItems.append(Self.literal("BODY[TEXT]", msg.body))
            }

            response += Data("* \(seqnum) FETCH (".utf8)
            response += Data(fetchItems.joined(separator: Data(" ".utf8)))
            response += Data(")\r\n".utf8)
        }

        response += Data("\(tag) OK \(uidMode ? "UID " : "")FETCH completed\r\n".utf8)
        return response
    }

    /// The field names of a `BODY[.PEEK][HEADER.FIELDS (...)]` item, if one was asked for.
    private func parseHeaderFieldNames(_ items: String) -> [String]? {
        let pattern = #"BODY(?:\.PEEK)?\[HEADER\.FIELDS \(([^)]*)\)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: items, range: NSRange(items.startIndex..., in: items)),
              let range = Range(match.range(at: 1), in: items) else {
            return nil
        }
        return items[range].split(separator: " ").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// The lines of the fields named in `names` (case-insensitive), folded lines
    /// kept, in the message's order and closed by the empty line, as servers send
    /// `BODY[HEADER.FIELDS (...)]`.
    private static func headerFieldsBlock(_ headerData: Data, names: [String]) -> String {
        let header = String(data: headerData, encoding: .utf8) ?? ""
        var fields: [String] = []
        for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.first == " " || line.first == "\t", !fields.isEmpty {
                fields[fields.count - 1] += "\r\n" + line
            } else {
                fields.append(line)
            }
        }
        let wanted = Set(names.map { $0.uppercased() })
        let selected = fields.filter { wanted.contains($0.prefix { $0 != ":" }.uppercased()) }
        return selected.map { $0 + "\r\n" }.joined() + "\r\n"
    }

    /// The sections of every `BODY[.PEEK][<section>.MIME]` item asked for.
    private func parseMIMEHeaderSections(_ items: String) -> [String] {
        let pattern = #"BODY(?:\.PEEK)?\[([0-9]+(?:\.[0-9]+)*)\.MIME\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: items, range: NSRange(items.startIndex..., in: items)).compactMap {
            Range($0.range(at: 1), in: items).map { String(items[$0]) }
        }
    }

    private struct PartialBodyRequest {
        let section: String
        let offset: Int
        let count: Int
    }

    private func parsePartialBodyRequest(_ items: String) -> PartialBodyRequest? {
        let pattern = #"BODY(?:\.PEEK)?\[([0-9]+(?:\.[0-9]+)*)\]<([0-9]+)\.([0-9]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: items, range: NSRange(items.startIndex..., in: items)),
              let sectionRange = Range(match.range(at: 1), in: items),
              let offsetRange = Range(match.range(at: 2), in: items),
              let countRange = Range(match.range(at: 3), in: items),
              let offset = Int(items[offsetRange]),
              let count = Int(items[countRange]) else {
            return nil
        }
        return PartialBodyRequest(section: String(items[sectionRange]), offset: offset, count: count)
    }

    private func partialBodyFetchItem(
        _ request: PartialBodyRequest,
        body: Data
    ) -> Data {
        let start = min(request.offset, body.count)
        let end = min(start + request.count, body.count)
        let bytes = body.subdata(in: start..<end)
        switch partialFetchBehavior {
            case .honor, .rejectWithBad, .rejectWithNo:
                return Self.literal("BODY[\(request.section)]<\(request.offset)>", bytes)
            case .wrongOffset:
                return Self.literal("BODY[\(request.section)]<\(request.offset + 1)>", bytes)
            case .ignoreRange:
                return Self.literal("BODY[\(request.section)]", body)
        }
    }

    private func parseSequenceSet(_ seqStr: String, uidMode: Bool) -> [Message] {
        var results: [Message] = []
        for part in seqStr.split(separator: ",").map(String.init) {
            if part.contains(":") {
                let range = part.split(separator: ":").map(String.init)
                let start = Int(range[0]) ?? 1
                let end: Int
                if range.count > 1, range[1] != "*" {
                    end = Int(range[1]) ?? messages.count
                } else {
                    end = uidMode ? (messages.last?.uid ?? 0) : messages.count
                }
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val >= start && val <= end {
                        results.append(msg)
                    }
                }
            } else if part == "*" {
                if let last = messages.last {
                    results.append(last)
                }
            } else if let num = Int(part) {
                for (index, msg) in messages.enumerated() {
                    let val = uidMode ? msg.uid : (index + 1)
                    if val == num {
                        results.append(msg)
                    }
                }
            }
        }
        return results
    }

    // MARK: - Response Builders

    private func buildEnvelope(_ msg: Message) -> String {
        let date = quote(msg.date)
        let subject = quote(msg.subject)
        let fromAddr = buildAddrList(msg.from)
        let toAddr = buildAddrList(msg.to)
        let msgID = quote(msg.messageID)
        let ccAddr = buildAddrList(msg.cc)
        let bccAddr = buildAddrList(msg.bcc)
        return "(\(date) \(subject) \(fromAddr) \(fromAddr) \(fromAddr) \(toAddr) \(ccAddr) \(bccAddr) NIL \(msgID))"
    }

    private func buildAddrList(_ header: String) -> String {
        guard !header.isEmpty else { return "NIL" }
        let name: String
        let email: String
        if let angleOpen = header.firstIndex(of: "<"),
           let angleClose = header.firstIndex(of: ">") {
            name = String(header[header.startIndex..<angleOpen]).trimmingCharacters(in: .whitespaces)
            email = String(header[header.index(after: angleOpen)..<angleClose])
        } else {
            name = ""
            email = header.trimmingCharacters(in: .whitespaces)
        }
        guard email.contains("@") else { return "NIL" }
        let parts = email.split(separator: "@")
        let local = String(parts[0])
        let domain = String(parts[1])
        let nameQ = name.isEmpty ? "NIL" : quote(name)
        return "((\(nameQ) NIL \(quote(local)) \(quote(domain))))"
    }

    private func buildBodystructure(_ msg: Message) -> String {
        let contentType = msg.contentType
        let parts = contentType.split(separator: "/")
        let maintype = parts.first.map(String.init)?.uppercased() ?? "TEXT"
        let subtype = parts.count > 1 ? String(parts[1]).uppercased() : "PLAIN"
        let charset = msg.charset.uppercased()
        let size = msg.body.count
        let lines = msg.body.filter { $0 == UInt8(ascii: "\n") }.count
        return "(\"\(maintype)\" \"\(subtype)\" (\"CHARSET\" \"\(charset)\") NIL NIL \"7BIT\" \(size) \(lines))"
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Maildir Loading

    private static func loadMaildir(_ url: URL) throws -> [Message] {
        var messages: [Message] = []
        var uid = 1

        for subdir in ["cur", "new"] {
            let dir = url.appendingPathComponent(subdir)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for file in files {
                var raw = try Data(contentsOf: file)
                if let str = String(data: raw, encoding: .utf8), !str.contains("\r\n") {
                    raw = Data(str.replacingOccurrences(of: "\n", with: "\r\n").utf8)
                }

                let msg = parseEmail(raw: raw, uid: uid)
                messages.append(msg)
                uid += 1
            }
        }

        return messages
    }

    private static func parseEmail(raw: Data, uid: Int) -> Message {
        let text = String(data: raw, encoding: .utf8) ?? ""

        let headerBody: (String, Data)
        if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
            let headerStr = String(data: raw[raw.startIndex..<range.upperBound], encoding: .utf8) ?? ""
            let bodyData = Data(raw[range.upperBound...])
            headerBody = (headerStr, bodyData)
        } else if let range = raw.range(of: Data("\n\n".utf8)) {
            let headerStr = String(data: raw[raw.startIndex..<range.upperBound], encoding: .utf8) ?? ""
            let bodyData = Data(raw[range.upperBound...])
            headerBody = (headerStr, bodyData)
        } else {
            headerBody = (text, Data())
        }

        let headers = headerBody.0
        let body = headerBody.1

        let headerData: Data
        if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
            headerData = Data(raw[raw.startIndex..<range.upperBound])
        } else if let range = raw.range(of: Data("\n\n".utf8)) {
            headerData = Data(raw[raw.startIndex..<range.upperBound])
        } else {
            headerData = raw
        }

        func header(_ name: String) -> String {
            let pattern = "(?m)^\(name): (.+)$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
                  let range = Range(match.range(at: 1), in: headers) else { return "" }
            return String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rawContentType = header("Content-Type")
        let mediaType: String
        let charset: String
        if rawContentType.contains(";") {
            let ctParts = rawContentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            mediaType = ctParts[0]
            if let charsetPart = ctParts.first(where: { $0.lowercased().hasPrefix("charset=") }) {
                charset = String(charsetPart.dropFirst("charset=".count))
            } else {
                charset = "utf-8"
            }
        } else {
            mediaType = rawContentType.isEmpty ? "text/plain" : rawContentType
            charset = "utf-8"
        }

        // Convert RFC 2822 date to IMAP INTERNALDATE format: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
        let dateStr = header("Date")
        let internalDate: String
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = dateFormatter.date(from: dateStr) {
            let imapFormatter = DateFormatter()
            imapFormatter.locale = Locale(identifier: "en_US_POSIX")
            imapFormatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
            internalDate = imapFormatter.string(from: date)
        } else {
            internalDate = "01-Jan-2025 00:00:00 +0000"
        }

        return Message(
            uid: uid,
            raw: raw,
            subject: header("Subject"),
            from: header("From"),
            to: header("To"),
            cc: header("Cc"),
            bcc: header("Bcc"),
            date: dateStr,
            internalDate: internalDate,
            messageID: header("Message-ID"),
            contentType: mediaType,
            charset: charset,
            body: body,
            headerData: headerData
        )
    }
}
#endif // os(macOS) || os(Linux)
// swiftlint:enable file_length type_body_length function_body_length cyclomatic_complexity
