// Create sender and recipients
let sender = EmailAddress(name: "Test Sender", address: "sender@example.org")
let recipient = EmailAddress(name: "Test Recipient", address: "recipient@example.org") // Primary recipient

// Create a new email message
let email = Email(sender: sender,
                  recipients: [recipient],
                  subject: "Hello from SwiftMail",
                  textBody: "This is a test email sent using SwiftMail."
            )
