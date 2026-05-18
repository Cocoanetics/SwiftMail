import Foundation
#if canImport(Glibc)
    import Glibc
#endif

enum IMAPTestError: Error {
    case setup(String)
}

/// A minimal IMAP4rev1 server implemented in Swift using POSIX sockets.
/// Uses POSIX sockets directly since Network.framework doesn't work in the iOS simulator.
final class IMAPTestServer {
    struct Message {
        let uid: Int
        let raw: Data
        let subject: String
        let from: String
        let to: String
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
    private(set) var port: Int

    var listenFd: Int32 = -1
    var acceptSource: DispatchSourceRead?
    let queue = DispatchQueue(label: "IMAPTestServer")
    let messages: [Message]
    var clientFds: [Int32] = []

    init(
        host: String = "localhost",
        port: Int = 0,
        username: String = "testuser",
        password: String = "testpass",
        maildirURL: URL
    ) throws {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.messages = try Self.loadMaildir(maildirURL)
    }

    func start() throws {
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
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            throw IMAPTestError.setup("bind() failed: \(errno)")
        }

        guard listen(listenFd, 5) == 0 else {
            close(listenFd)
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
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))

        // Set up accept dispatch source
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

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for fileDescriptor in clientFds {
            close(fileDescriptor)
        }
        clientFds.removeAll()
    }
}
