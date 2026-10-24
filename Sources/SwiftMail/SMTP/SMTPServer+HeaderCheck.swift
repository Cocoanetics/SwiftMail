import Foundation

extension SMTPServer {
    /// Refuses SMTP content whose header could be read as fields other than the
    /// ones written, such as a `Bcc` field every recipient sees. It checks every
    /// field as written, so it covers each value that goes into one, including
    /// ``Email/additionalHeaders``, ``Email/messageID``, and the sender domain a
    /// generated Message-ID takes.
    ///
    /// Each field name must be an RFC 5322 field name (printable ASCII other than
    /// `:`) and must not be `Bcc` or `Resent-Bcc` (BCC recipients belong in
    /// ``Email/bccRecipients``, envelope only). Each value may hold a CR or LF
    /// only as a fold: CRLF, then a space or tab.
    static func checkHeaderFields(_ headerFields: [Email.HeaderField]) throws {
        let blindFieldNames: Set = ["bcc", "resent-bcc"]
        for field in headerFields {
            let isFieldName = !field.name.isEmpty
                && field.name.unicodeScalars.allSatisfy { (33...126).contains($0.value) && $0 != ":" }
            guard isFieldName else {
                throw SMTPError.sendFailed("A header name is not a header field name")
            }
            if blindFieldNames.contains(field.name.lowercased()) {
                throw SMTPError.sendFailed("Header \(field.name) would show blind-copy recipients to every recipient")
            }
            let unfolded = field.value
                .replacingOccurrences(of: "\r\n ", with: "")
                .replacingOccurrences(of: "\r\n\t", with: "")
            if unfolded.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) {
                throw SMTPError.sendFailed("Header \(field.name) has a line break that would start a new header field")
            }
        }
    }
}
