// Send the email
do {
    try await smtpServer.sendEmail(email)
    print("Email sent successfully!")
} catch {
    print("Failed to send email: \(error)")
}
