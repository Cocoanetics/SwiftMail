// Create an email
let email = Email(
    sender: sender,
    recipients: [recipient],
    ccRecipients: [ccRecipient],
    subject: "Hello from SwiftMail",
    body: """
    Hi Jane,
    
    This is a test email sent using SwiftMail.
    
    Best regards,
    John
    """
) 