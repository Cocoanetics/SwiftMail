import Foundation

extension IMAPTestServer {

    // MARK: - Response Builders

    func buildEnvelope(_ msg: Message) -> String {
        let date = quote(msg.date)
        let subject = quote(msg.subject)
        let fromAddr = buildAddrList(msg.from)
        let toAddr = buildAddrList(msg.to)
        let msgID = quote(msg.messageID)
        return "(\(date) \(subject) \(fromAddr) \(fromAddr) \(fromAddr) \(toAddr) NIL NIL NIL \(msgID))"
    }

    func buildAddrList(_ header: String) -> String {
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

    func buildBodystructure(_ msg: Message) -> String {
        let contentType = msg.contentType
        let parts = contentType.split(separator: "/")
        let maintype = parts.first.map(String.init)?.uppercased() ?? "TEXT"
        let subtype = parts.count > 1 ? String(parts[1]).uppercased() : "PLAIN"
        let charset = msg.charset.uppercased()
        let size = msg.body.count
        let lines = msg.body.filter { $0 == UInt8(ascii: "\n") }.count
        return "(\"\(maintype)\" \"\(subtype)\" (\"CHARSET\" \"\(charset)\") NIL NIL \"7BIT\" \(size) \(lines))"
    }

    func quote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
