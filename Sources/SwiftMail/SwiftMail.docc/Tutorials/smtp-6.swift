// Create an email with attachments
let emailWithAttachment = Email(
    sender: sender,
    recipients: [recipient],
    subject: "Email with Attachment",
    body: "Please find the attached document.",
    attachments: [
        Attachment(
            filename: "document.pdf",
            data: documentData,
            mimeType: "application/pdf"
        )
    ]
)

// Send email with attachment
try await smtpServer.sendEmail(emailWithAttachment) 