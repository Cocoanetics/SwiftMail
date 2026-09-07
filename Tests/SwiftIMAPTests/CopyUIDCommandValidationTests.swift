import Testing
@testable import SwiftMail

@Suite("COPYUID command validation")
struct CopyUIDCommandValidationTests {
    @Test
    func unrequestedPartialMappingIsNotExposedAsVerified() {
        let command = MoveCommand(
            identifierSet: UIDSet(UID(1)),
            destinationMailbox: "Archive"
        )
        let invalid = CopyUID(
            destinationUIDValidity: UIDValidity(10),
            mapping: [(source: UID(2), destination: UID(300))]
        )
        let error = command.validate(
            error: .moveFailedAfterPartialCompletion(copyUID: invalid, reason: "MOVE denied")
        )

        guard case .moveFailedAfterPossiblePartialCompletion = error else {
            Issue.record("Expected invalid mapping to become possible partial completion")
            return
        }
    }

    @Test
    func requestedWildcardMappingIsNotExposedAsVerified() {
        let copyUID = CopyUID(
            destinationUIDValidity: UIDValidity(10),
            mapping: [(source: UID(42), destination: UID(300))]
        )
        let singleton = CopyCommand(
            identifierSet: UIDSet(UID.latest),
            destinationMailbox: "Archive"
        )
        let reversedRange = MoveCommand(
            identifierSet: UIDSet(UID(559)...UID.latest),
            destinationMailbox: "Archive"
        )

        expectUnverifiableWildcard { try singleton.validate(copyUID: copyUID) }
        expectUnverifiableWildcard { try reversedRange.validate(copyUID: copyUID) }
        let partial = reversedRange.validate(
            error: .moveFailedAfterPartialCompletion(copyUID: copyUID, reason: "MOVE denied")
        )
        guard case .moveFailedAfterPossiblePartialCompletion = partial else {
            Issue.record("Expected wildcard mapping to remain unverified")
            return
        }
    }

    private func expectUnverifiableWildcard(_ operation: () throws -> CopyUID?) {
        do {
            _ = try operation()
            Issue.record("Expected wildcard COPYUID evidence to be rejected")
        } catch let error as IMAPError {
            guard case .malformedCopyUIDAfterTaggedOK(let reason) = error else {
                Issue.record("Expected malformedCopyUIDAfterTaggedOK, got \(error)")
                return
            }
            #expect(reason.contains("cannot be verified against a wildcard request"))
        } catch {
            Issue.record("Expected IMAPError.malformedCopyUIDAfterTaggedOK, got \(error)")
        }
    }
}
