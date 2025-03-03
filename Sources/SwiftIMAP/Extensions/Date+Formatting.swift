import Foundation

extension Date {
    /// Format the date using the long style for both date and time
    func formattedForDisplay() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .long
        formatter.locale = .current
        return formatter.string(from: self)
    }
} 