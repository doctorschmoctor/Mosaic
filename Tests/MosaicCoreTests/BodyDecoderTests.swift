import XCTest
@testable import MosaicCore

final class BodyDecoderTests: XCTestCase {
    private func archive(_ text: String, long: Bool = false) -> Data {
        var data = Data([0x04, 0x0b])
        data.append(Data("streamtyped".utf8))
        data.append(Data("NSString".utf8)); data.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2b])
        let length = text.utf8.count
        if long { data.append(contentsOf: [0x81, UInt8(length & 0xff), UInt8(length >> 8)]) }
        else { data.append(UInt8(length)) }
        data.append(Data(text.utf8)); data.append(0x86)
        return data
    }
    func testPlainTextWinsAndUnicodeDecodes() {
        XCTAssertEqual(BodyDecoder.decode(text: "Plain", attributedBody: archive("Archive")), "Plain")
        XCTAssertEqual(BodyDecoder.decode(text: nil, attributedBody: archive("Coffee ☕ tomorrow?")), "Coffee ☕ tomorrow?")
    }
    func testMultibyteLengthAndMalformedData() {
        let text = String(repeating: "Long message 😊 ", count: 30)
        XCTAssertEqual(BodyDecoder.decode(text: nil, attributedBody: archive(text, long: true)), text)
        var truncated = archive("Hello")
        truncated.removeLast(4)
        XCTAssertEqual(BodyDecoder.decode(text: nil, attributedBody: truncated), "Rich text message · Open in Messages")
        for count in 0..<128 {
            _ = BodyDecoder.decode(text: nil, attributedBody: Data(repeating: 0xff, count: count))
        }
        XCTAssertEqual(BodyDecoder.decode(text: nil, attributedBody: nil), "")
    }
}
