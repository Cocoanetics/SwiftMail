import SwiftMail

/// Create a draft message and store it on the server.
func createDraft(imapServer: IMAPServer) async throws {
    let draft = Email(
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        recipients: [],
        subject: "Draft subject",
        textBody: "Start jotting down ideas..."
    )

    let result = try await imapServer.createDraft(from: draft)
    if let uid = result.firstUID {
        print("Draft stored with UID \(uid.value)")
    }
}
