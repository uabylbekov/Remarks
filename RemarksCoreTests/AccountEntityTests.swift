import Testing
import Foundation
@testable import RemarksCore

@Suite("The account entity")
struct AccountEntityTests {
    /// Saved shortcuts and Siri's memory of the account refer to this id, so it must never change (Spec 06).
    @Test("The account id is the one that was first shipped")
    func accountIDNeverChanges() {
        #expect(AccountEntity.accountID.uuidString == "5C1B0B3E-6E52-4B33-9B64-0A1B6A52D0A1")
        #expect(AccountEntity.shared.id == AccountEntity.accountID)
    }
}
