// Process each email
for (index, email) in emails.enumerated() {
    print("\n[\(index + 1)] From: \(email.from)")
    print("Subject: \(email.subject)")
    print("Date: \(email.date)")
    
    if let textBody = email.textBody {
        print("Content: \(textBody)")
    }
} 