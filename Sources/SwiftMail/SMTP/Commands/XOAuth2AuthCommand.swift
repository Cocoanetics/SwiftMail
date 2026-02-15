import Foundation
import NIO

/// Command to authenticate with SMTP server using XOAUTH2 method (used by Gmail and other OAuth2 providers)
struct XOAuth2AuthCommand: SMTPCommand {
    typealias ResultType = AuthResult
    typealias HandlerType = PlainAuthHandler

    let email: String
    let accessToken: String
    let timeoutSeconds: Int = 30

    func toCommandString() -> String {
        // XOAUTH2 format: "user=" + email + "\x01" + "auth=Bearer " + token + "\x01\x01"
        var data = Data()
        data.append(contentsOf: "user=".utf8)
        data.append(contentsOf: email.utf8)
        data.append(0x01)
        data.append(contentsOf: "auth=Bearer ".utf8)
        data.append(contentsOf: accessToken.utf8)
        data.append(0x01)
        data.append(0x01)
        let encoded = data.base64EncodedString()
        return "AUTH XOAUTH2 \(encoded)"
    }

    func validate() throws {
        guard !email.isEmpty else {
            throw SMTPError.authenticationFailed("Email cannot be empty")
        }
        guard !accessToken.isEmpty else {
            throw SMTPError.authenticationFailed("Access token cannot be empty")
        }
    }
}
