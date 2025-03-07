import Foundation

extension String {
    /// Determines if a string is safe for 8bit MIME transmission according to SMTP standards.
    /// Verifies:
    /// - No NULL bytes (which would terminate message in some implementations)
    /// - No control characters except CR, LF, and TAB
    /// - No lines exceeding 998 characters (RFC 5322 limit)
    public func isSafe8BitContent() -> Bool {
        // Quick return if empty string
        if isEmpty { return true }
        
        // Define allowed control characters (CR, LF, TAB)
        let allowedControlChars: Set<UInt8> = [0x09, 0x0A, 0x0D] // TAB, LF, CR
        
        // Check each character for NULL bytes and problematic control characters
        for char in utf8 where char < 32 || char == 127 {
            if char == 0 { // NULL byte - immediate fail
                return false
            }
            
            if !allowedControlChars.contains(char) { // Other control character not in our allowed set
                return false
            }
        }
        
        // Check line lengths - use components rather than split to handle all newline types
        return components(separatedBy: .newlines)
            .allSatisfy { $0.count <= 998 }
    }
} 