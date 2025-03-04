// EmailAddress.swift
// Model representing an email address

import Foundation

/**
 Represents an email address with an optional name
 */
public struct EmailAddress {
    /// The name associated with the email address (optional)
    public let name: String?
    
    /// The email address
    public let address: String
    
    /**
     Initialize a new email address
     - Parameters:
     - name: The name associated with the email address (optional)
     - address: The email address
     */
    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }
    
    /**
     Get the formatted representation of the email address
     For example: "John Doe <john.doe@example.com>" or "john.doe@example.com"
     */
    public var formatted: String {
        guard let name = name, !name.isEmpty else {
            return address
        }
        
        // If the name contains special characters, it needs to be quoted
        if name.contains(where: { !$0.isLetter && !$0.isNumber && $0 != " " }) {
            return "\"\(name)\" <\(address)>"
        } else {
            return "\(name) <\(address)>"
        }
    }
} 