import Foundation

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

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "IMAPTestServer")
    private let messages: [Message]
    private var clientFds: [Int32] = []

    init(host: String = "localhost", port: Int = 0, username: String = "testuser", password: String = "testpass", maildirURL: URL) throws {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.messages = try Self.loadMaildir(maildirURL)
    }

    func start() throws {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw IMAPTestError.setup("socket() failed: \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
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
        withUnsafeMutablePointer(to: &boundAddr) {
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
            if let fd = self?.listenFd, fd >= 0 {
                close(fd)
                self?.listenFd = -1
            }
        }
        self.acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for fd in clientFds {
            close(fd)
        }
        clientFds.removeAll()
    }

    // MARK: - Connection Handling

    private func acceptClient() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFd, $0, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        clientFds.append(clientFd)

        // Handle on a background queue
        DispatchQueue.global().async { [weak self] in
            self?.handleClient(fd: clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        // Send greeting
        sendLine(fd: fd, "* OK IMAP test server ready\r\n")

        var buffer = Data()
        var authenticated = false
        var selectedMailbox: String?
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        while true {
            let n = read(fd, readBuf, 65536)
            if n <= 0 { break }
            buffer.append(readBuf, count: n)

            while let crlfRange = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                buffer = Data(buffer[crlfRange.upperBound...])

                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    sendLine(fd: fd, "* BAD Invalid command\r\n")
                    continue
                }

                let tag = parts[0]
                let command = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""

                let response = handleCommand(tag: tag, command: command, args: args, authenticated: &authenticated, selectedMailbox: &selectedMailbox)
                sendLine(fd: fd, response)

                if command == "LOGOUT" {
                    close(fd)
                    return
                }
            }
        }

        close(fd)
    }

    private func sendLine(fd: Int32, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, ptr + sent, data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    // MARK: - Command Handling

    private func handleCommand(tag: String, command: String, args: String, authenticated: inout Bool, selectedMailbox: inout String?) -> String {
        switch command {
        case "CAPABILITY":
            return "* CAPABILITY IMAP4rev1 AUTH=PLAIN LITERAL+ ID NAMESPACE UIDPLUS\r\n\(tag) OK CAPABILITY completed\r\n"
        case "LOGIN":
            authenticated = true
            return "\(tag) OK LOGIN completed\r\n"
        case "SELECT":
            guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
            let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
            selectedMailbox = mailbox
            let count = messages.count
            let uidnext = (messages.last?.uid ?? 0) + 1
            return "* \(count) EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 1] UIDs valid\r\n* OK [UIDNEXT \(uidnext)] Predicted next UID\r\n* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Flags permitted\r\n\(tag) OK [READ-WRITE] SELECT completed\r\n"
        case "UID":
            guard selectedMailbox != nil else { return "\(tag) NO No mailbox selected\r\n" }
            return handleUID(tag: tag, args: args)
        case "FETCH":
            guard selectedMailbox != nil else { return "\(tag) NO No mailbox selected\r\n" }
            return handleFetch(tag: tag, args: args, uidMode: false)
        case "NAMESPACE":
            return "* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n\(tag) OK NAMESPACE completed\r\n"
        case "LIST":
            return "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n\(tag) OK LIST completed\r\n"
        case "ID":
            return "* ID NIL\r\n\(tag) OK ID completed\r\n"
        case "NOOP":
            return "\(tag) OK NOOP completed\r\n"
        case "LOGOUT":
            return "* BYE IMAP server shutting down\r\n\(tag) OK LOGOUT completed\r\n"
        default:
            return "\(tag) BAD Unknown command \(command)\r\n"
        }
    }

    private func handleUID(tag: String, args: String) -> String {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard let subcmd = parts.first?.uppercased() else {
            return "\(tag) BAD Missing UID subcommand\r\n"
        }
        let subargs = parts.count > 1 ? parts[1] : ""
        switch subcmd {
        case "FETCH":
            return handleFetch(tag: tag, args: subargs, uidMode: true)
        case "SEARCH":
            let uids = messages.map { String($0.uid) }.joined(separator: " ")
            return "* SEARCH \(uids)\r\n\(tag) OK UID SEARCH completed\r\n"
        default:
            return "\(tag) BAD Unknown UID subcommand\r\n"
        }
    }

    private func handleFetch(tag: String, args: String, uidMode: Bool) -> String {
        let seqStr: String
        let itemsStr: String

        if let parenOpen = args.firstIndex(of: "("),
           let parenClose = args.lastIndex(of: ")") {
            seqStr = String(args[args.startIndex..<parenOpen]).trimmingCharacters(in: .whitespaces)
            itemsStr = String(args[args.index(after: parenOpen)..<parenClose]).uppercased()
        } else {
            let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
            guard fetchParts.count == 2 else { return "\(tag) BAD Invalid FETCH arguments\r\n" }
            seqStr = fetchParts[0]
            itemsStr = fetchParts[1].uppercased()
        }

        let matched = parseSequenceSet(seqStr, uidMode: uidMode)
        var response = ""

        for msg in matched {
            let seqnum = (messages.firstIndex(where: { $0.uid == msg.uid }) ?? 0) + 1
            var fetchItems: [String] = []

            if itemsStr.contains("UID") || uidMode {
                fetchItems.append("UID \(msg.uid)")
            }
            if itemsStr.contains("FLAGS") {
                fetchItems.append("FLAGS (\\Seen)")
            }
            if itemsStr.contains("ENVELOPE") {
                fetchItems.append("ENVELOPE \(buildEnvelope(msg))")
            }
            if itemsStr.contains("INTERNALDATE") {
                fetchItems.append("INTERNALDATE \"\(msg.internalDate)\"")
            }
            if itemsStr.contains("RFC822.SIZE") {
                fetchItems.append("RFC822.SIZE \(msg.raw.count)")
            }
            if itemsStr.contains("BODYSTRUCTURE") {
                fetchItems.append("BODYSTRUCTURE \(buildBodystructure(msg))")
            }
            if itemsStr.contains("BODY[]") || itemsStr.contains("BODY.PEEK[]") {
                let rawStr = String(data: msg.raw, encoding: .utf8) ?? ""
                fetchItems.append("BODY[] {\(msg.raw.count)}\r\n\(rawStr)")
            }
            if itemsStr.contains("BODY[HEADER]") || itemsStr.contains("BODY.PEEK[HEADER]") {
                let headerStr = String(data: msg.headerData, encoding: .utf8) ?? ""
                fetchItems.append("BODY[HEADER] {\(msg.headerData.count)}\r\n\(headerStr)")
            }
            if itemsStr.contains("BODY[TEXT]") || itemsStr.contains("BODY.PEEK[TEXT]") {
                let bodyStr = String(data: msg.body, encoding: .utf8) ?? ""
                fetchItems.append("BODY[TEXT] {\(msg.body.count)}\r\n\(bodyStr)")
            }

            response += "* \(seqnum) FETCH (\(fetchItems.joined(separator: " ")))\r\n"
        }

        response += "\(tag) OK \(uidMode ? "UID " : "")FETCH completed\r\n"
        return response
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
        return "(\(date) \(subject) \(fromAddr) \(fromAddr) \(fromAddr) \(toAddr) NIL NIL NIL \(msgID))"
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
        let ct = msg.contentType
        let parts = ct.split(separator: "/")
        let maintype = parts.first.map(String.init)?.uppercased() ?? "TEXT"
        let subtype = parts.count > 1 ? String(parts[1]).uppercased() : "PLAIN"
        let charset = msg.charset.uppercased()
        let size = msg.body.count
        let lines = msg.body.filter { $0 == UInt8(ascii: "\n") }.count
        return "(\"\(maintype)\" \"\(subtype)\" (\"CHARSET\" \"\(charset)\") NIL NIL \"7BIT\" \(size) \(lines))"
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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

        let contentType = header("Content-Type")
        let ct: String
        let charset: String
        if contentType.contains(";") {
            let ctParts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            ct = ctParts[0]
            if let charsetPart = ctParts.first(where: { $0.lowercased().hasPrefix("charset=") }) {
                charset = String(charsetPart.dropFirst("charset=".count))
            } else {
                charset = "utf-8"
            }
        } else {
            ct = contentType.isEmpty ? "text/plain" : contentType
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
            date: dateStr,
            internalDate: internalDate,
            messageID: header("Message-ID"),
            contentType: ct,
            charset: charset,
            body: body,
            headerData: headerData
        )
    }
}
