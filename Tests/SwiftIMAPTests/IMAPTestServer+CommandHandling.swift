import Foundation
#if canImport(Glibc)
    import Glibc
#endif

extension IMAPTestServer {

    // MARK: - Connection Handling

    func acceptClient() {
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

    func handleClient(fd fileDescriptor: Int32) {
        // Send greeting
        sendLine(fd: fileDescriptor, "* OK IMAP test server ready\r\n")

        var buffer = Data()
        var authenticated = false
        var selectedMailbox: String?
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuf.deallocate() }

        var idleTag: String?  // non-nil while in IDLE state

        while true {
            let bytesRead = read(fileDescriptor, readBuf, 65536)
            if bytesRead <= 0 { break }
            buffer.append(readBuf, count: bytesRead)

            while let crlfRange = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
                buffer = Data(buffer[crlfRange.upperBound...])

                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                // Handle DONE (untagged) while in IDLE state
                if let tag = idleTag, line.uppercased() == "DONE" {
                    sendLine(fd: fileDescriptor, "\(tag) OK IDLE terminated\r\n")
                    idleTag = nil
                    continue
                }

                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else {
                    sendLine(fd: fileDescriptor, "* BAD Invalid command\r\n")
                    continue
                }

                let tag = parts[0]
                let command = parts[1].uppercased()
                let args = parts.count > 2 ? parts[2] : ""

                if command == "IDLE" {
                    sendLine(fd: fileDescriptor, "+ idling\r\n")
                    idleTag = tag
                    continue
                }

                let response = handleCommand(
                    tag: tag,
                    command: command,
                    args: args,
                    authenticated: &authenticated,
                    selectedMailbox: &selectedMailbox
                )
                sendLine(fd: fileDescriptor, response)

                if command == "LOGOUT" {
                    close(fileDescriptor)
                    return
                }
            }
        }

        close(fileDescriptor)
    }

    func sendLine(fd fileDescriptor: Int32, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
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

    // MARK: - Command Handling

    func handleCommand(
        tag: String,
        command: String,
        args: String,
        authenticated: inout Bool,
        selectedMailbox: inout String?
    ) -> String {
        if let staticResp = staticResponse(tag: tag, command: command) {
            return staticResp
        }
        switch command {
            case "LOGIN":
                authenticated = true
                return "\(tag) OK LOGIN completed\r\n"
            case "SELECT":
                guard authenticated else { return "\(tag) NO Not authenticated\r\n" }
                let mailbox = args.trimmingCharacters(in: .init(charactersIn: "\" "))
                selectedMailbox = mailbox
                return selectResponse(tag: tag)
            case "UID":
                guard selectedMailbox != nil else { return "\(tag) NO No mailbox selected\r\n" }
                return handleUID(tag: tag, args: args)
            case "FETCH":
                guard selectedMailbox != nil else { return "\(tag) NO No mailbox selected\r\n" }
                return handleFetch(tag: tag, args: args, uidMode: false)
            default:
                return "\(tag) BAD Unknown command \(command)\r\n"
        }
    }

    /// Returns canned responses for commands that take no arguments and don't mutate state.
    private func staticResponse(tag: String, command: String) -> String? {
        switch command {
            case "CAPABILITY":
                let caps = "* CAPABILITY IMAP4rev1 AUTH=PLAIN LITERAL+ ID NAMESPACE UIDPLUS IDLE\r\n"
                return caps + "\(tag) OK CAPABILITY completed\r\n"
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
                return nil
        }
    }

    private func selectResponse(tag: String) -> String {
        let count = messages.count
        let uidnext = (messages.last?.uid ?? 0) + 1
        var response = "* \(count) EXISTS\r\n"
        response += "* 0 RECENT\r\n"
        response += "* OK [UIDVALIDITY 1] UIDs valid\r\n"
        response += "* OK [UIDNEXT \(uidnext)] Predicted next UID\r\n"
        response += "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n"
        response += "* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Flags permitted\r\n"
        response += "\(tag) OK [READ-WRITE] SELECT completed\r\n"
        return response
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
        let (seqStr, itemsStr) = parseFetchArguments(args)
        guard let items = itemsStr else { return "\(tag) BAD Invalid FETCH arguments\r\n" }

        let matched = parseSequenceSet(seqStr, uidMode: uidMode)
        var response = ""

        for msg in matched {
            let seqnum = (messages.firstIndex(where: { $0.uid == msg.uid }) ?? 0) + 1
            let fetchItems = buildFetchItems(for: msg, itemsStr: items, uidMode: uidMode)
            response += "* \(seqnum) FETCH (\(fetchItems.joined(separator: " ")))\r\n"
        }

        response += "\(tag) OK \(uidMode ? "UID " : "")FETCH completed\r\n"
        return response
    }

    private func parseFetchArguments(_ args: String) -> (seqStr: String, itemsStr: String?) {
        if let parenOpen = args.firstIndex(of: "("),
           let parenClose = args.lastIndex(of: ")") {
            let seqStr = String(args[args.startIndex..<parenOpen]).trimmingCharacters(in: .whitespaces)
            let itemsStr = String(args[args.index(after: parenOpen)..<parenClose]).uppercased()
            return (seqStr, itemsStr)
        }
        let fetchParts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard fetchParts.count == 2 else { return ("", nil) }
        return (fetchParts[0], fetchParts[1].uppercased())
    }

    private func buildFetchItems(for msg: Message, itemsStr: String, uidMode: Bool) -> [String] {
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
        return fetchItems
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
}
