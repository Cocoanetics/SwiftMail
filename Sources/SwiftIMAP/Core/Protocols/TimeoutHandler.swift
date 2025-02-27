// TimeoutHandler.swift
// Protocol for handlers that support timeout cancellation

import Foundation
import NIO

/// Protocol for handlers that support timeout cancellation
public protocol TimeoutHandler {
    /// Cancel the timeout for the handler
    func cancelTimeout()
    
    /// Set up the timeout for the handler
    func setupTimeout(on eventLoop: EventLoop)
} 