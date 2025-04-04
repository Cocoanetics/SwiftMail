//
//  Section.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 03.04.25.
//

import Foundation

/// Represents a section number in an email message part (e.g., [1, 2, 3] represents "1.2.3")
public struct Section: Codable, Hashable, Sendable {
	private let numbers: [Int]
	
	/// Initialize a section from an array of integers
	public init(_ numbers: [Int]) {
		self.numbers = numbers.isEmpty ? [1] : numbers
	}
	
	/// Initialize a section from a dot-separated string
	public init(_ string: String) {
		let numbers = string.split(separator: ".").compactMap { Int($0) }
		self.numbers = numbers.isEmpty ? [1] : numbers
	}
	
	/// Get the section number as a dot-separated string
	public var description: String {
		numbers.map { String($0) }.joined(separator: ".")
	}
	
	/// Access the underlying array of integers
	public var components: [Int] {
		numbers
	}
}

// MARK: - CustomStringConvertible
extension Section: CustomStringConvertible {}

// MARK: - ExpressibleByArrayLiteral
extension Section: ExpressibleByArrayLiteral {
	public init(arrayLiteral elements: Int...) {
		self.init(elements)
	}
}

extension Section: Comparable {
	/// Compare two sections based on their components
	/// - Parameters:
	///   - lhs: The left-hand section
	///   - rhs: The right-hand section
	/// - Returns: true if lhs comes before rhs in natural order
	public static func < (lhs: Section, rhs: Section) -> Bool {
		// Compare each component in order until we find a difference
		let maxLength = min(lhs.components.count, rhs.components.count)
		
		for i in 0..<maxLength {
			if lhs.components[i] != rhs.components[i] {
				return lhs.components[i] < rhs.components[i]
			}
		}
		
		// If all components match up to the shorter length,
		// the shorter section comes first
		return lhs.components.count < rhs.components.count
	}
}
