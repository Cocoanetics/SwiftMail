// SMTPResponse.swift
// A struct representing an SMTP server response

import Foundation

/**
 A struct representing an SMTP server response
 */
public struct SMTPResponse: Sendable {
    /** The response code */
    public let code: Int
    
    /** The response message */
    public let message: String
} 
