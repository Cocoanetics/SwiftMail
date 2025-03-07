// DeflateHandler.swift
// Handler for DEFLATE compression in IMAP

import Foundation
import NIO
import Logging
import CompressNIO
import Atomics // Instead of NIOConcurrencyHelpers

/// A duplex channel handler that supports deflate compression and decompression for IMAP.
/// This handler is designed to be added to the pipeline during connection setup,
/// and then activated after the COMPRESS=DEFLATE command is accepted by the server.

final class DeflateHandler: ChannelDuplexHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private let logger: Logger
    private let isActive: ManagedAtomic<Bool> // Use ManagedAtomic instead of NIOAtomic
    
    // These variables are only accessed on the event loop and 
    // are effectively isolated because the class is only accessed through IMAPServer
    private var decompressor: ZlibDecompressor?
    private var compressor: ZlibCompressor?
    
    // Constants for buffer management
    private let initialDecompressionFactor: Int = 10 // Initial factor for decompression buffer
    private let maxDecompressionAttempts: Int = 3    // Maximum number of resize attempts
    
    /// Initialize a new DeflateHandler
    /// - Parameters:
    ///   - logger: The logger to use for logging
    ///   - isActive: Whether compression is initially active
    public init(logger: Logger, isActive: Bool = false) {
        self.logger = logger
        self.isActive = ManagedAtomic<Bool>(isActive) // Use ManagedAtomic instead
        logger.debug("DEFLATE handler initialized (active: \(isActive))")
    }
    
    /// Activate or deactivate compression
    public func setActive(_ active: Bool) {
        let oldValue = isActive.exchange(active, ordering: .relaxed)
        if oldValue != active {
            logger.info("DEFLATE handler \(active ? "activated" : "deactivated")")
            
            if active {
                do {
                    // Create new compressor and decompressor when activating
                    self.compressor = try ZlibCompressor(algorithm: .deflate)
                    self.decompressor = try ZlibDecompressor(algorithm: .deflate)
                    logger.debug("Created new deflate compressor and decompressor")
                } catch {
                    logger.error("Failed to create compressor/decompressor: \(error)")
                }
            } else {
                // Clean up when deactivating
                if self.compressor != nil || self.decompressor != nil {
                    logger.debug("Preparing to clear compressor and decompressor during deactivation")
                    
                    // Safe to set to nil - full cleanup will happen in handlerRemoved if needed
                    self.compressor = nil
                    self.decompressor = nil
                    logger.debug("Cleared deflate compressor and decompressor")
                }
            }
        }
    }
    
    /// Decompress incoming data if active
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        
        // If compression is not active or there's no data, just pass through
        guard isActive.load(ordering: .relaxed) && buffer.readableBytes > 0 else {
            context.fireChannelRead(wrapInboundOut(buffer))
            return
        }
        
        guard let decompressor = self.decompressor else {
            logger.error("Decompressor not initialized but compression is active")
            context.fireChannelRead(wrapInboundOut(buffer))
            return
        }
        
        // Keep the original buffer for recovery in case of error
        let originalBuffer = buffer
        let originalSize = buffer.readableBytes
        
        // Try to decompress with multiple attempts if needed (to handle buffer overflow)
        for attempt in 1...maxDecompressionAttempts {
            do {
                // Calculate capacity with increasing factor for each attempt
                let capacityFactor = initialDecompressionFactor * attempt
                let capacity = max(originalSize * capacityFactor, 4096) // Minimum 4KB
                
                // Reset buffer position if this is a retry
                if attempt > 1 {
                    buffer = originalBuffer
                }
                
                // Create a buffer to hold the decompressed data with larger capacity
                var decompressedBuffer = context.channel.allocator.buffer(capacity: capacity)
                
                // Use stream decompression which maintains state between chunks
                try decompressor.inflate(from: &buffer, to: &decompressedBuffer)
                
                logger.debug("Decompressed \(originalSize) bytes to \(decompressedBuffer.readableBytes) bytes (attempt \(attempt))")
                
                // Pass the decompressed data up the pipeline
                context.fireChannelRead(wrapInboundOut(decompressedBuffer))
                return
            } catch let error as CompressNIOError where error == .bufferOverflow && attempt < maxDecompressionAttempts {
                // If we got a buffer overflow and have more attempts, log and try again with a larger buffer
                logger.warning("Decompression buffer overflow on attempt \(attempt), trying with larger buffer")
                continue
            } catch {
                if attempt == maxDecompressionAttempts {
                    logger.error("Failed to decompress after \(maxDecompressionAttempts) attempts: \(error) (buffer size: \(originalSize))")
                } else {
                    logger.error("Error decompressing data on attempt \(attempt): \(error) (buffer size: \(originalSize))")
                }
                
                // Log the first few bytes of the buffer for debugging
                if originalSize > 0 {
                    let bytesToLog = min(originalSize, 20)
                    var bufferCopy = originalBuffer
                    if let bytes = bufferCopy.readBytes(length: bytesToLog) {
                        logger.error("First \(bytesToLog) bytes: \(bytes)")
                    }
                }
                
                // On error, pass the original data through
                context.fireChannelRead(wrapInboundOut(originalBuffer))
                return
            }
        }
    }
    
    /// Compress outbound data if active
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        
        // If compression is not active or there's no data, just pass through
        guard isActive.load(ordering: .relaxed) && buffer.readableBytes > 0 else {
            context.write(wrapOutboundOut(buffer), promise: promise)
            return
        }
        
        guard let compressor = self.compressor else {
            logger.error("Compressor not initialized but compression is active")
            context.write(wrapOutboundOut(buffer), promise: promise)
            if let promise = promise {
                promise.succeed(())
            }
            return
        }
        
        do {
            let originalSize = buffer.readableBytes
            
            // Create a buffer to hold the compressed data
            var compressedBuffer = context.channel.allocator.buffer(capacity: compressor.maxSize(from: buffer))
            
            // Compress the data
            try compressor.deflate(from: &buffer, to: &compressedBuffer, flush: .sync)
            
            logger.debug("Compressed \(originalSize) bytes to \(compressedBuffer.readableBytes) bytes")
            
            // Write the compressed data
            context.write(wrapOutboundOut(compressedBuffer), promise: promise)
        } catch {
            logger.error("Error compressing data: \(error)")
            // On error, pass the original data through
            context.write(wrapOutboundOut(buffer), promise: promise)
        }
    }
    
    public func handlerAdded(context: ChannelHandlerContext) {
        logger.debug("DeflateHandler added to pipeline")
    }
    
    public func handlerRemoved(context: ChannelHandlerContext) {
        logger.debug("DeflateHandler removed from pipeline")
        
        // Properly finalize compressor before setting to nil
        if let compressor = self.compressor {
            do {
                // Create a temporary buffer for any remaining data
                var tempInBuffer = context.channel.allocator.buffer(capacity: 0)
                var tempOutBuffer = context.channel.allocator.buffer(capacity: 64)
                
                // Final flush to clean up resources
                try compressor.deflate(from: &tempInBuffer, to: &tempOutBuffer, flush: .finish)
                logger.debug("Compressor finalized successfully")
            } catch {
                logger.error("Error finalizing compressor: \(error)")
            }
        }
        
        // For decompressor, there's no real "finalization" needed - just log and release
        if self.decompressor != nil {
            logger.debug("Releasing decompressor resources")
        }
        
        // Now safe to set to nil
        self.compressor = nil
        self.decompressor = nil
    }
} 
