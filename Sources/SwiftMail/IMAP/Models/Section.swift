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
