import Foundation
import NIOIMAPCore

/// Representation of an IMAP namespace response
public enum Namespace {
    /// Description of a single namespace
    public struct Description: Sendable {
        /// The prefix string of the namespace
        public let prefix: String
        /// The hierarchy delimiter if provided
        public let delimiter: Character?

        /// Initialize from raw values
        public init(prefix: String, delimiter: Character?) {
            self.prefix = prefix
            self.delimiter = delimiter
        }

        /// Initialize from ``NIOIMAPCore.NamespaceDescription``
        init(from nio: NIOIMAPCore.NamespaceDescription) {
            self.prefix = nio.string.stringValue
            self.delimiter = nio.delimiter
        }
    }

    /// The namespaces returned by the server
    public struct Response: Sendable {
        /// Personal namespaces
        public let personal: [Description]
        /// Other user namespaces
        public let otherUsers: [Description]
        /// Shared namespaces
        public let shared: [Description]

        /// Initialize from raw values
        public init(personal: [Description], otherUsers: [Description], shared: [Description]) {
            self.personal = personal
            self.otherUsers = otherUsers
            self.shared = shared
        }

        /// Initialize from ``NIOIMAPCore.NamespaceResponse``
        init(from nio: NIOIMAPCore.NamespaceResponse) {
            self.personal = nio.userNamespace.map { Description(from: $0) }
            self.otherUsers = nio.otherUserNamespace.map { Description(from: $0) }
            self.shared = nio.sharedNamespace.map { Description(from: $0) }
        }
    }
}
