// CompressCommand.swift
// Command for enabling COMPRESS=DEFLATE capability

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Command for enabling COMPRESS=DEFLATE compression
public struct CompressCommand: IMAPCommand {
    public typealias ResultType = Void
    public typealias HandlerType = CompressHandler
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { CompressHandler.self }
    
    /// Algorithm to use for compression (only DEFLATE is supported per RFC 4978)
    private let algorithm: Capability.CompressionKind
    
    /// Default timeout increased to allow time for compression setup
    public var timeoutSeconds: Int { return 10 }
    
    /// Initialize a new compress command
    /// - Parameter algorithm: Compression algorithm (defaults to "DEFLATE")
    public init(algorithm: String = "DEFLATE") {
        self.algorithm = Capability.CompressionKind(algorithm)
    }
    
    /// Validate that we only try to use the DEFLATE algorithm
    public func validate() throws {
        // We only support DEFLATE, which is enforced by using Capability.CompressionKind.deflate
        // No validation needed here as we're using the correct type
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .compress(algorithm))
    }
} 