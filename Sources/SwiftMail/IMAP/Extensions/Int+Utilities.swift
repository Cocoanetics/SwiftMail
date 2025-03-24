// Int+Utilities.swift
// Extensions for Int to handle IMAP-related utilities

import Foundation

/// Extension to provide utilities for Int to describe file sizes
extension Int {
    /// Format the integer as a human-readable file size (e.g. 1.5 MB)
    /// - Parameter locale: The locale to use for formatting (defaults to current)
    /// - Returns: A human-readable string representation of the file size
	public func formattedFileSize(locale: Locale = .current) -> String {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        // Use MeasurementFormatter on Apple platforms
        let byteCount = Measurement(value: Double(self), unit: UnitInformationStorage.bytes)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        formatter.locale = locale
        
        // Format sizes in the appropriate unit
        if self < 1_000 {
            return formatter.string(from: byteCount)
        } else if self < 1_000_000 {
            return formatter.string(from: byteCount.converted(to: .kilobytes))
        } else if self < 1_000_000_000 {
            return formatter.string(from: byteCount.converted(to: .megabytes))
        } else {
            return formatter.string(from: byteCount.converted(to: .gigabytes))
        }
        #else
        // Simplified implementation for Linux that matches the expected test format
        let byteCount = Double(self)
        let numberFormatter = NumberFormatter()
        numberFormatter.maximumFractionDigits = 1
        numberFormatter.locale = locale
        
        if byteCount < 1_000 {
            // Use "byte" (singular) for all byte values - matches test expectations
            return "\(Int(byteCount)) byte"
        } else if byteCount < 1_000_000 {
            let kb = byteCount / 1_000
            // Use lowercase "kB" - matches test expectations
            return "\(numberFormatter.string(from: NSNumber(value: kb)) ?? String(format: "%.1f", kb)) kB"
        } else if byteCount < 1_000_000_000 {
            let mb = byteCount / 1_000_000
            return "\(numberFormatter.string(from: NSNumber(value: mb)) ?? String(format: "%.1f", mb)) MB"
        } else {
            let gb = byteCount / 1_000_000_000
            return "\(numberFormatter.string(from: NSNumber(value: gb)) ?? String(format: "%.1f", gb)) GB"
        }
        #endif
    }
} 
