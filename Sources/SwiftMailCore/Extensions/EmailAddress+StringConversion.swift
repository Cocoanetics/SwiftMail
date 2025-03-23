// EmailAddress+StringConversion.swift
// Extension to make EmailAddress conform to LosslessStringConvertible

import Foundation

// MARK: - LosslessStringConvertible conformance for EmailAddress

extension EmailAddress: LosslessStringConvertible {
    /**
     Initialize an email address from a string representation
     - Parameter description: The string representation of the email address
     */
    public init?(_ description: String) {
        // Simple email address without a name
        if description.contains("@") && !description.contains("<") {
            self.init(address: description)
            return
        }
        
        // Email address with a name
        // Format: "Name <email@example.com>" or "\"Name with, special chars\" <email@example.com>"
        let namePattern = "(?:\"([^\"]+)\"|([^<]+))\\s*<([^>]+)>"
        let nameRegex = try? NSRegularExpression(pattern: namePattern, options: [])
        
        if let match = nameRegex?.firstMatch(in: description, options: [], range: NSRange(location: 0, length: description.count)) {
            let nameRange1 = match.range(at: 1)
            let nameRange2 = match.range(at: 2)
            let emailRange = match.range(at: 3)
            
            if emailRange.location != NSNotFound {
                let nsString = description as NSString
                let email = nsString.substring(with: emailRange)
                
                // Check if we have a quoted name or a regular name
                if nameRange1.location != NSNotFound {
                    // Quoted name (with special characters)
                    let name = nsString.substring(with: nameRange1)
                    self.init(name: name, address: email)
                    return
                } else if nameRange2.location != NSNotFound {
                    // Regular name
                    let name = nsString.substring(with: nameRange2).trimmingCharacters(in: .whitespaces)
                    self.init(name: name, address: email)
                    return
                } else {
                    // Just the email
                    self.init(address: email)
                    return
                }
            }
        }
        
        return nil
    }
	
	/**
	 Get the string representation of the email address
	 This uses the formatted representation which includes the name if available
	 */
	public var description: String {
		if let name = name, !name.isEmpty {
			// Use quotes if the name contains special characters
			if name.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
				return "\"\(name)\" <\(address)>"
			} else {
				return "\(name) <\(address)>"
			}
		} else {
			return address
		}
	}
}
