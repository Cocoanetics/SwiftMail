import Foundation

extension IMAPTestServer {

    // MARK: - Maildir Loading

    static func loadMaildir(_ url: URL) throws -> [Message] {
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

    static func parseEmail(raw: Data, uid: Int) -> Message {
        let split = splitHeadersAndBody(raw: raw)
        let headers = split.headerString
        let body = split.body
        let headerData = split.headerData

        let (mediaType, charset) = parseContentTypeHeader(in: headers)
        let dateStr = headerValue("Date", in: headers)
        let internalDate = convertToInternalDate(dateStr)

        return Message(
            uid: uid,
            raw: raw,
            subject: headerValue("Subject", in: headers),
            from: headerValue("From", in: headers),
            to: headerValue("To", in: headers),
            date: dateStr,
            internalDate: internalDate,
            messageID: headerValue("Message-ID", in: headers),
            contentType: mediaType,
            charset: charset,
            body: body,
            headerData: headerData
        )
    }

    private struct HeadersBodySplit {
        let headerString: String
        let body: Data
        let headerData: Data
    }

    private static func splitHeadersAndBody(raw: Data) -> HeadersBodySplit {
        if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
            let headerString = String(data: raw[raw.startIndex..<range.upperBound], encoding: .utf8) ?? ""
            let bodyData = Data(raw[range.upperBound...])
            let headerData = Data(raw[raw.startIndex..<range.upperBound])
            return HeadersBodySplit(headerString: headerString, body: bodyData, headerData: headerData)
        }
        if let range = raw.range(of: Data("\n\n".utf8)) {
            let headerString = String(data: raw[raw.startIndex..<range.upperBound], encoding: .utf8) ?? ""
            let bodyData = Data(raw[range.upperBound...])
            let headerData = Data(raw[raw.startIndex..<range.upperBound])
            return HeadersBodySplit(headerString: headerString, body: bodyData, headerData: headerData)
        }
        let text = String(data: raw, encoding: .utf8) ?? ""
        return HeadersBodySplit(headerString: text, body: Data(), headerData: raw)
    }

    private static func headerValue(_ name: String, in headers: String) -> String {
        let pattern = "(?m)^\(name): (.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let range = Range(match.range(at: 1), in: headers) else { return "" }
        return String(headers[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseContentTypeHeader(in headers: String) -> (mediaType: String, charset: String) {
        let contentType = headerValue("Content-Type", in: headers)
        guard contentType.contains(";") else {
            let mediaType = contentType.isEmpty ? "text/plain" : contentType
            return (mediaType, "utf-8")
        }
        let ctParts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let mediaType = ctParts[0]
        let charset: String
        if let charsetPart = ctParts.first(where: { $0.lowercased().hasPrefix("charset=") }) {
            charset = String(charsetPart.dropFirst("charset=".count))
        } else {
            charset = "utf-8"
        }
        return (mediaType, charset)
    }

    /// Convert RFC 2822 date to IMAP INTERNALDATE format: "DD-Mon-YYYY HH:MM:SS +ZZZZ"
    private static func convertToInternalDate(_ dateStr: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = dateFormatter.date(from: dateStr) else {
            return "01-Jan-2025 00:00:00 +0000"
        }
        let imapFormatter = DateFormatter()
        imapFormatter.locale = Locale(identifier: "en_US_POSIX")
        imapFormatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return imapFormatter.string(from: date)
    }
}
