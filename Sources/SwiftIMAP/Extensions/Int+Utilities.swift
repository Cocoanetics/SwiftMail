// Int+Utilities.swift
// Extensions for Int to handle IMAP-related utilities

import Foundation

extension Int {
    /// Format a file size in bytes to a human-readable string
    /// - Parameter locale: Optional locale to use for formatting (nil uses the system locale)
    /// - Returns: A formatted string (e.g., "1.2 KB")
	func formattedFileSize(locale: Locale = .current) -> String {
        let byteCount = Measurement(value: Double(self), unit: UnitInformationStorage.bytes)
        let formatter = MeasurementFormatter()
		formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        
        // Convert to the most appropriate unit
        let converted: Measurement<UnitInformationStorage>
        if self < 1000 {
            converted = byteCount
        } else if self < 1000 * 1000 {
            converted = byteCount.converted(to: .kilobytes)
        } else if self < 1000 * 1000 * 1000 {
            converted = byteCount.converted(to: .megabytes)
        } else {
            converted = byteCount.converted(to: .gigabytes)
        }
        
        return formatter.string(from: converted)
    }
} 
