// SMTPTypes.swift
// Common SMTP types that can be used across modules

import Foundation

/// SMTP response codes
public enum SMTPResponseCode: Int {
    case commandOK = 250
    case ready = 220
    case readyForContent = 354
    case serviceClosing = 221
    case authSuccess = 235
    case tempError = 421
    case mailboxUnavailable = 450
    case localError = 451
    case insufficientStorage = 452
    case syntaxError = 500
    case argumentError = 501
    case notImplemented = 502
    case badSequence = 503
    case paramNotImplemented = 504
    case mailboxUnavailablePerm = 550
    case userNotLocal = 551
    case exceededStorage = 552
    case nameNotAllowed = 553
    case transactionFailed = 554
}

/// A structure representing a response from an SMTP server
public struct SMTPResponse: MailResponse {
    /// The numeric response code
    public let code: Int
    
    /// The response message text
    public let message: String
    
    /// Whether this response indicates success (codes 200-399 are considered success)
    public var isSuccess: Bool {
        return code >= 200 && code < 400
    }
    
    /// Create a new SMTP response
    /// - Parameters:
    ///   - code: The numeric response code
    ///   - message: The response message text
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// Authentication methods supported by SMTP
public enum AuthMethod {
    case plain
    case login
}

/// Authentication result
public struct AuthResult {
    /// Whether authentication was successful
    public let success: Bool
    
    /// Authentication method used
    public let method: AuthMethod
    
    /// Any error message if authentication failed
    public let errorMessage: String?
    
    /// Create a successful result
    public static func success(method: AuthMethod) -> AuthResult {
        return AuthResult(success: true, method: method, errorMessage: nil)
    }
    
    /// Create a failure result
    public static func failure(method: AuthMethod, errorMessage: String) -> AuthResult {
        return AuthResult(success: false, method: method, errorMessage: errorMessage)
    }
} 
