// EmailAddress.swift
// Common utilities shared between IMAP and SMTP modules

import Foundation
import NIO
import NIOSSL

/// Email address representation
public struct EmailAddress: Hashable, Codable, Sendable {
    /// The name part of the address (optional)
    public let name: String?

    /// The email address
    public let address: String

    /// Initialize a new email address
    /// - Parameters:
    ///   - name: Optional display name. An empty name is the same as no name
    ///     and is stored as `nil`, as the two read and write identically.
    ///   - address: The email address
    public init(name: String? = nil, address: String) {
        self.name = name?.isEmpty == false ? name : nil
        self.address = address
    }
}
