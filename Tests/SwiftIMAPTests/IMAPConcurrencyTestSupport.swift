import Foundation
import Testing
@testable import SwiftMail

/// Buffered, repeatable signals: no scheduling sleeps are needed to order races.
final class IMAPTestSignal: @unchecked Sendable {
    private let terminal = IMAPTerminal<Void>()

    func signal() { terminal.complete(.success(())) }

    func wait() async {
        do { try await terminal.value() } catch { Issue.record(error) }
    }
}

final class IMAPTestCounter {
    private let gate = IMAPLifetimeGate()
    private var count = 0

    func increment() -> Int {
        gate.withLock {
            count += 1
            return count
        }
    }

    var value: Int { gate.withLock { count } }
}

enum IMAPConcurrencyTestError: Error { case expected }
