import XCTest
@testable import MosaicCore

/// One set of rules for comparing handles and for handing them to Messages: a number becomes
/// international only when that is certain from how it is written and the Mac's region, and is
/// never moved into another country. Synthetic numbers only (555 and Ofcom drama ranges).
final class HandleFormTests: XCTestCase {
    private func form(_ address: String, _ region: String) -> HandleForm { HandleForm(address, region: region) }

    func testNorthAmericanNumbersInTheUSAndCanada() {
        for written in ["(415) 555-0123", "415.555.0123", "1-415-555-0123", "+1 415 555 0123", "tel:+14155550123", "001 415 555 0123", "011 1 415 555 0123"] {
            XCTAssertEqual(form(written, "US"), .phone("14155550123"), written)
        }
        XCTAssertEqual(form("4155550123", "CA").messagesHandle, "+14155550123")
        // Not a North American number (an exchange can't start with 0): left as written.
        XCTAssertEqual(form("13800138000", "US"), .local("13800138000"))
        XCTAssertEqual(form("12345", "US"), .local("12345"), "a short code")
        XCTAssertEqual(form("011 44 20 7946 0123", "US"), .phone("442079460123"))
    }

    /// Outside North America a ten-digit number is never made a US one.
    func testNumbersAreNeverMovedIntoAnotherCountry() {
        XCTAssertEqual(form("4155550123", "GB"), .local("4155550123"))
        XCTAssertEqual(form("4155550123", "GB").messagesHandle, "4155550123", "Messages reads it with the Mac's region")
        XCTAssertEqual(form("9876543210", "IN"), .local("9876543210"))
        XCTAssertEqual(form("13800138000", "CN"), .local("13800138000"))
        XCTAssertEqual(form("13800138000", "CN").messagesHandle, "13800138000")
        XCTAssertEqual(form("4155550123", "BR"), .local("4155550123"), "a region whose national form isn't read")
        // Written internationally, a number keeps its own country wherever the Mac is.
        for region in ["US", "GB", "IN", "JP", "BR"] {
            XCTAssertEqual(form("+44 20 7946 0123", region), .phone("442079460123"), region)
            XCTAssertEqual(form("+1 415 555 0123", region), .phone("14155550123"), region)
        }
    }

    func testNationalFormsWithATrunkZero() {
        XCTAssertEqual(form("020 7946 0123", "GB"), .phone("442079460123"))
        XCTAssertEqual(form("07700 900123", "GB"), .phone("447700900123"))
        XCTAssertEqual(form("44 7700 900123", "GB"), .phone("447700900123"), "its own calling code without +")
        XCTAssertEqual(form("00 49 30 123456", "GB"), .phone("4930123456"))
        XCTAssertEqual(form("09876543210", "IN"), .phone("919876543210"))
        XCTAssertEqual(form("0412 345 678", "AU"), .phone("61412345678"))
        XCTAssertEqual(form("0011 44 20 7946 0123", "AU"), .phone("442079460123"), "Australia's international prefix")
        XCTAssertEqual(form("030 123456", "DE"), .phone("4930123456"))
        XCTAssertEqual(form("010 44 20 7946 0123", "JP"), .phone("442079460123"))
    }

    func testRegionsWithoutATrunkPrefixUseTheNationalLength() {
        XCTAssertEqual(form("412 34 567", "NO"), .phone("4741234567"))
        XCTAssertEqual(form("47 412 34 567", "NO"), .phone("4741234567"))
        XCTAssertEqual(form("612 345 678", "ES"), .phone("34612345678"))
        XCTAssertEqual(form("6123 4567", "ES"), .local("61234567"), "not Spain's length")
    }

    func testEmailsAndOtherHandles() {
        XCTAssertEqual(form(" Alex@Example.test ", "US"), .email("alex@example.test"))
        XCTAssertEqual(form("mailto:ALEX@example.test", "GB").messagesHandle, "alex@example.test")
        XCTAssertEqual(form("urn:biz:Example", "US"), .other("urn:biz:example"))
        XCTAssertFalse(form("urn:biz:Example", "US").isPhone)
        XCTAssertEqual(form("４１５５５５０１２３", "US"), .phone("14155550123"), "full-width digits")
    }

    /// Contacts match by the same rules: national and international forms of one number meet,
    /// a number of uncertain country only meets itself.
    func testContactNamesUseTheSameRules() {
        let britain = ContactNames(entries: [
            .init(id: "sam", name: "Sam", addresses: ["(415) 555-0123"]),
            .init(id: "kit", name: "Kit", addresses: ["07700 900123"]),
        ], region: "GB")
        XCTAssertNil(britain.name(for: "+14155550123"), "in Britain a number saved without +1 isn't assumed to be American")
        XCTAssertEqual(britain.name(for: "415 555 0123"), "Sam")
        XCTAssertEqual(britain.name(for: "+447700900123"), "Kit")
        let america = ContactNames(entries: [.init(id: "wei", name: "Wei", addresses: ["+86 138 0013 8000"])], region: "US")
        XCTAssertEqual(america.name(for: "+8613800138000"), "Wei")
        XCTAssertNil(america.name(for: "+13800138000"))
        XCTAssertNil(america.name(for: "3800138000"))
    }
}
