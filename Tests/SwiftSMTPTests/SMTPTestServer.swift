// Single-file POSIX-socket SMTP fake server used by the submission-outcome
// integration tests, modeled on Tests/SwiftIMAPTests/IMAPTestServer.swift.
// Raw POSIX sockets and DispatchSource are only available on macOS/Linux;
// the integration tests that use this server are gated the same way.
// swiftlint:disable file_length type_body_length function_body_length cyclomatic_complexity
#if os(macOS) || os(Linux)
import Foundation
#if canImport(Glibc)
    import Glibc
#endif

enum SMTPTestError: Error {
    case setup(String)
}

/// What the scripted server does when it has to answer a client command.
enum SMTPScriptAction {
    /// Send the reply line (CRLF appended) and keep the connection open.
    case reply(String)
    /// Send the reply line, then immediately close the connection.
    case replyThenClose(String)
    /// Close the connection without sending any reply.
    case close
    /// Never reply, but keep the connection open and keep reading.
    case silence
}

/// Per-command reply scripts. Each list is consumed one action per received
/// command across the whole connection; the last action repeats once the list
/// is exhausted, so single-element scripts describe a constant behavior.
struct SMTPServerScript {
    var onMailFrom: [SMTPScriptAction] = [.reply("250 OK")]
    var onRcptTo: [SMTPScriptAction] = [.reply("250 OK")]
    var onData: [SMTPScriptAction] = [.reply("354 End data with <CRLF>.<CRLF>")]
    var onContent: [SMTPScriptAction] = [.reply("250 2.0.0 OK queued as TEST42")]
}

/// A minimal scripted SMTP server implemented with POSIX sockets.
///
/// Speaks just enough ESMTP for `SMTPServer.connect()` (greeting + EHLO) and
/// then follows its ``SMTPServerScript`` for the mail transaction, recording
/// everything it receives so tests can assert what was — and was not — sent.
final class SMTPTestServer {
    private(set) var port: Int

    private let script: SMTPServerScript
    private let ehloCapabilities: [String]

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "SMTPTestServer")
    private var clientFds: Set<Int32> = []
    private let clientFdsLock = NSLock()
    private let clientGroup = DispatchGroup()
    private var isStopping = false

    private let stateLock = NSLock()
    private var recordedCommandsStorage: [String] = []
    private var receivedContentStorage: [Data] = []
    private var contentTerminatorReceivedStorage = false
    private var contentTerminatorWaiters: [CheckedContinuation<Void, Never>] = []
    private var mailFromActionIndex = 0
    private var rcptToActionIndex = 0
    private var dataActionIndex = 0
    private var contentActionIndex = 0

    init(script: SMTPServerScript = SMTPServerScript(), ehloCapabilities: [String] = ["8BITMIME"], port: Int = 0) {
        self.script = script
        self.ehloCapabilities = ehloCapabilities
        self.port = port
    }

    // MARK: - Recorded state

    /// Every command line received outside of DATA-input mode, verbatim.
    var recordedCommands: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedCommandsStorage
    }

    /// The message contents received in DATA-input mode (terminator stripped).
    var receivedContentMessages: [Data] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receivedContentStorage
    }

    /// Number of received command lines starting with the given prefix
    /// (case-insensitive), e.g. `"RCPT TO"`, `"DATA"`, `"RSET"`.
    func receivedCommandCount(withPrefix prefix: String) -> Int {
        let upper = prefix.uppercased()
        return recordedCommands.filter { $0.uppercased().hasPrefix(upper) }.count
    }

    /// Resumes once the server has read a complete `<CRLF>.<CRLF>` terminator,
    /// i.e. the client has provably transmitted the whole message content.
    func waitForContentTerminator() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            if contentTerminatorReceivedStorage {
                stateLock.unlock()
                continuation.resume()
                return
            }
            contentTerminatorWaiters.append(continuation)
            stateLock.unlock()
        }
    }

    private func recordCommand(_ line: String) {
        stateLock.lock()
        recordedCommandsStorage.append(line)
        stateLock.unlock()
    }

    private func recordContent(_ content: Data) {
        stateLock.lock()
        receivedContentStorage.append(content)
        contentTerminatorReceivedStorage = true
        let waiters = contentTerminatorWaiters
        contentTerminatorWaiters.removeAll()
        stateLock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    private func nextAction(_ actions: [SMTPScriptAction], cursor: inout Int) -> SMTPScriptAction {
        precondition(!actions.isEmpty, "script action list must not be empty")
        let action = actions[min(cursor, actions.count - 1)]
        cursor += 1
        return action
    }

    private func nextMailFromAction() -> SMTPScriptAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nextAction(script.onMailFrom, cursor: &mailFromActionIndex)
    }

    private func nextRcptToAction() -> SMTPScriptAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nextAction(script.onRcptTo, cursor: &rcptToActionIndex)
    }

    private func nextDataAction() -> SMTPScriptAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nextAction(script.onData, cursor: &dataActionIndex)
    }

    private func nextContentAction() -> SMTPScriptAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nextAction(script.onContent, cursor: &contentActionIndex)
    }

    // MARK: - Lifecycle

    func start() throws {
        resetClientTrackingForStart()

        #if os(Linux)
            listenFd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            listenFd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listenFd >= 0 else {
            throw SMTPTestError.setup("socket() failed: \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if !os(Linux)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            throw SMTPTestError.setup("bind() failed: \(errno)")
        }

        guard listen(listenFd, 5) == 0 else {
            close(listenFd)
            throw SMTPTestError.setup("listen() failed: \(errno)")
        }

        // Get actual port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFd, $0, &addrLen)
            }
        }
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fileDescriptor = self?.listenFd, fileDescriptor >= 0 {
                close(fileDescriptor)
                self?.listenFd = -1
            }
        }
        self.acceptSource = source
        source.resume()
    }

    /// Stops the server and awaits the client handlers' drain. Async for the
    /// same reason as `IMAPTestServer.stop()`: never park a cooperative-pool
    /// thread on a DispatchGroup wait.
    func stop() async {
        acceptSource?.cancel()
        acceptSource = nil

        let activeClientFds = markStoppingAndSnapshotClientFds()
        for fileDescriptor in activeClientFds {
            shutdown(fileDescriptor, Int32(SHUT_RDWR))
        }

        if !activeClientFds.isEmpty {
            await awaitClientDrain(timeoutSeconds: 2)
        }

        for fileDescriptor in drainClientFds() {
            close(fileDescriptor)
        }
    }

    /// Runs `body`, then stops the server — on success and on throw alike.
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

    private func awaitClientDrain(timeoutSeconds: Double) async {
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clientGroup.notify(queue: .global()) {
                if once.claim() { continuation.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if once.claim() { continuation.resume() }
            }
        }
    }

    // MARK: - Connection handling

    private func acceptClient() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        guard registerClient(fd: clientFd) else {
            close(clientFd)
            return
        }

        let clientGroup = clientGroup
        clientGroup.enter()
        DispatchQueue.global().async { [weak self] in
            defer { clientGroup.leave() }
            guard let self else {
                close(clientFd)
                return
            }
            self.handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd fileDescriptor: Int32) {
        defer { closeTrackedClient(fd: fileDescriptor) }

        sendLine(fd: fileDescriptor, "220 smtp.test ESMTP SMTPTestServer ready\r\n")

        var buffer = Data()
        var inDataMode = false
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        while true {
            let bytesRead = read(fileDescriptor, readBuf, 65536)
            if bytesRead <= 0 { break }
            buffer.append(readBuf, count: bytesRead)

            while true {
                if inDataMode {
                    guard let terminatorRange = buffer.range(of: Data("\r\n.\r\n".utf8)) else { break }
                    let content = Data(buffer[buffer.startIndex..<terminatorRange.lowerBound])
                    buffer = Data(buffer[terminatorRange.upperBound...])
                    inDataMode = false
                    recordContent(content)

                    switch nextContentAction() {
                        case .reply(let line):
                            sendLine(fd: fileDescriptor, line + "\r\n")
                        case .replyThenClose(let line):
                            sendLine(fd: fileDescriptor, line + "\r\n")
                            return
                        case .close:
                            return
                        case .silence:
                            break
                    }
                } else {
                    guard let crlfRange = buffer.range(of: Data("\r\n".utf8)) else { break }
                    let lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                    buffer = Data(buffer[crlfRange.upperBound...])
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }

                    switch handleCommandLine(line, fd: fileDescriptor, inDataMode: &inDataMode) {
                        case .keepGoing:
                            continue
                        case .closeConnection:
                            return
                    }
                }
            }
        }
    }

    private enum CommandOutcome {
        case keepGoing
        case closeConnection
    }

    private func handleCommandLine(_ line: String, fd fileDescriptor: Int32, inDataMode: inout Bool) -> CommandOutcome {
        recordCommand(line)
        let upper = line.uppercased()

        if upper.hasPrefix("EHLO") || upper.hasPrefix("HELO") {
            var reply = "250-smtp.test greets you\r\n"
            for capability in ehloCapabilities.dropLast() {
                reply += "250-\(capability)\r\n"
            }
            if let last = ehloCapabilities.last {
                reply += "250 \(last)\r\n"
            } else {
                reply = "250 smtp.test greets you\r\n"
            }
            sendLine(fd: fileDescriptor, reply)
            return .keepGoing
        }

        if upper.hasPrefix("MAIL FROM") {
            return apply(nextMailFromAction(), fd: fileDescriptor)
        }

        if upper.hasPrefix("RCPT TO") {
            return apply(nextRcptToAction(), fd: fileDescriptor)
        }

        if upper == "DATA" {
            let action = nextDataAction()
            if case .reply(let text) = action, text.hasPrefix("354") {
                inDataMode = true
            }
            return apply(action, fd: fileDescriptor)
        }

        if upper == "RSET" || upper == "NOOP" {
            sendLine(fd: fileDescriptor, "250 OK\r\n")
            return .keepGoing
        }

        if upper == "QUIT" {
            sendLine(fd: fileDescriptor, "221 smtp.test closing connection\r\n")
            return .closeConnection
        }

        sendLine(fd: fileDescriptor, "500 Unrecognized command\r\n")
        return .keepGoing
    }

    private func apply(_ action: SMTPScriptAction, fd fileDescriptor: Int32) -> CommandOutcome {
        switch action {
            case .reply(let line):
                sendLine(fd: fileDescriptor, line + "\r\n")
                return .keepGoing
            case .replyThenClose(let line):
                sendLine(fd: fileDescriptor, line + "\r\n")
                return .closeConnection
            case .close:
                return .closeConnection
            case .silence:
                return .keepGoing
        }
    }

    // MARK: - Client fd tracking

    private func resetClientTrackingForStart() {
        clientFdsLock.lock()
        isStopping = false
        clientFds.removeAll()
        clientFdsLock.unlock()
    }

    private func registerClient(fd fileDescriptor: Int32) -> Bool {
        clientFdsLock.lock()
        defer { clientFdsLock.unlock() }

        guard !isStopping else { return false }
        clientFds.insert(fileDescriptor)
        return true
    }

    private func markStoppingAndSnapshotClientFds() -> [Int32] {
        clientFdsLock.lock()
        defer { clientFdsLock.unlock() }

        isStopping = true
        return Array(clientFds)
    }

    private func drainClientFds() -> [Int32] {
        clientFdsLock.lock()
        defer { clientFdsLock.unlock() }

        let fileDescriptors = Array(clientFds)
        clientFds.removeAll()
        return fileDescriptors
    }

    private func closeTrackedClient(fd fileDescriptor: Int32) {
        clientFdsLock.lock()
        let shouldClose = clientFds.remove(fileDescriptor) != nil
        clientFdsLock.unlock()

        if shouldClose {
            close(fileDescriptor)
        }
    }

    private func sendLine(fd fileDescriptor: Int32, _ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let bytesWritten = write(fileDescriptor, ptr + sent, data.count - sent)
                if bytesWritten <= 0 { return }
                sent += bytesWritten
            }
        }
    }
}
#endif // os(macOS) || os(Linux)
// swiftlint:enable file_length type_body_length function_body_length cyclomatic_complexity
