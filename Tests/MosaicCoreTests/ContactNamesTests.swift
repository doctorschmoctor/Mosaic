import XCTest
@testable import MosaicCore

final class ContactNamesTests: XCTestCase {
    func testLocalNumbersCountryCodesFormattingAndEmail() {
        let names = ContactNames(entries: [
            .init(id: "alex", name: "Alex Morgan", addresses: ["(415) 555-0123", " Alex@Example.test "]),
            .init(id: "jamie", name: "Jamie Chen", addresses: ["+1 212 555 0199"])
        ], region: "US")
        XCTAssertEqual(names.name(for: "+14155550123"), "Alex Morgan")
        XCTAssertEqual(names.name(for: "tel:0014155550123"), "Alex Morgan")
        XCTAssertEqual(names.name(for: "212.555.0199"), "Jamie Chen")
        XCTAssertEqual(names.name(for: "mailto:ALEX@example.test"), "Alex Morgan")
        XCTAssertNil(names.name(for: "+44 4155550123"))
    }
    func testAmbiguousPhoneAliasesDoNotChooseTheWrongPerson() {
        let names = ContactNames(entries: [
            .init(id: "a", name: "Alex", addresses: ["4155550123"]),
            .init(id: "b", name: "Someone else", addresses: ["+14155550123"])
        ], region: "US")
        XCTAssertNil(names.name(for: "+14155550123"))
        XCTAssertNil(names.name(for: "4155550123"))
    }
    func testNationalTrunkPrefixUsesTheLocalRegion() {
        let names = ContactNames(entries: [.init(id: "a", name: "Alex", addresses: ["020 7946 0123"])], region: "GB")
        XCTAssertEqual(names.name(for: "+442079460123"), "Alex")
        XCTAssertNil(names.name(for: "+612079460123"))
    }
    func testPersonalTitlesResolveRegardlessOfDatabaseDisplayNameAndNamedGroupsStayIntact() {
        let names = ContactNames(entries: [.init(id: "a", name: "Alex", addresses: ["4155550123"])], region: "US")
        XCTAssertEqual(names.title(for: Conversation(id: "direct", name: "Some stale display name", participants: ["+14155550123"])), "Alex")
        XCTAssertEqual(names.title(for: Conversation(id: "group", name: "Weekend crew", participants: ["+14155550123", "other@example.test"])), "Weekend crew")
        XCTAssertEqual(names.title(for: Conversation(id: "unnamed", name: "+14155550123, other@example.test", participants: ["+14155550123", "other@example.test"])), "Alex, other@example.test")
    }
    func testAddressFallbackResolvesWhenMessagesHasNoParticipantRows() {
        let names = ContactNames(entries: [.init(id: "a", name: "Alex", addresses: ["4155550123"])], region: "US")
        XCTAssertEqual(names.title(for: Conversation(id: "direct", name: "+14155550123", participants: [])), "Alex")
        XCTAssertEqual(names.title(for: Conversation(id: "group", name: "Group 4155550123", participants: [])), "Group 4155550123")
    }
}
