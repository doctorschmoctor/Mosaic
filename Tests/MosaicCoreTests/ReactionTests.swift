import XCTest
@testable import MosaicCore

final class ReactionTests: XCTestCase {
    private var base = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private func event(_ id: Int, _ kind: ReactionEvent.Kind, by actor: String?, on target: String = "G1", part: Int? = 0,
                       removal: Bool = false, at seconds: Double? = nil) -> ReactionEvent {
        ReactionEvent(id: String(id), date: base.addingTimeInterval(seconds ?? Double(id)), isFromMe: actor == nil, actor: actor,
                      targetGUID: target, targetPart: part, kind: kind, isRemoval: removal)
    }

    /// The latest row per person and part decides; kinds group with their people in the order
    /// they first appeared.
    func testReactionsGroupByKindAndPerson() {
        let state = Reactions.reduce([
            event(1, .love, by: "alex"), event(2, .love, by: nil), event(3, .laugh, by: "sam"), event(4, .like, by: "jamie", on: "G2"),
        ])
        XCTAssertEqual(state["G1"], [ReactionSummary(kind: .love, actors: [.handle("alex"), .me]),
                                     ReactionSummary(kind: .laugh, actors: [.handle("sam")])])
        XCTAssertEqual(state["G1"]?.first?.count, 2)
        XCTAssertTrue(state["G1"]?.first?.includesMe ?? false)
        XCTAssertEqual(state["G2"], [ReactionSummary(kind: .like, actors: [.handle("jamie")])])
    }

    /// One reaction per person per part: a new kind replaces the old one; a removal clears only
    /// that person's matching reaction; rebuilding from the same rows gives the same result.
    func testReplacementRemovalAndIdempotence() {
        let rows = [
            event(1, .love, by: "alex"), event(2, .laugh, by: "alex"),           // Alex changes to laugh
            event(3, .like, by: "sam"), event(4, .like, by: "sam", removal: true), // Sam takes it back
            event(5, .question, by: nil), event(6, .love, by: nil, removal: true),  // a removal of the wrong kind changes nothing
        ]
        let state = Reactions.reduce(rows)
        XCTAssertEqual(state["G1"], [ReactionSummary(kind: .laugh, actors: [.handle("alex")]),
                                     ReactionSummary(kind: .question, actors: [.me])])
        XCTAssertEqual(Reactions.reduce(rows), state, "the same rows always give the same state")
        XCTAssertEqual(Reactions.reduce(rows.reversed()), state, "row order in the input does not matter; dates do")
        // A deleted reaction row simply is not there next time: its badge is gone.
        XCTAssertEqual(Reactions.reduce(Array(rows.dropFirst(2)))["G1"]?.contains { $0.kind == .laugh }, false)
    }

    /// Custom emoji reactions and their removals; a person reacting to two parts with the same
    /// kind counts once on the message.
    func testEmojiReactionsAndPartsCountOnce() {
        let state = Reactions.reduce([
            event(1, .emoji("🔥"), by: "alex"), event(2, .emoji(""), by: "alex", removal: true),
            event(3, .emoji("🎉"), by: "mia"), event(4, .like, by: "sam", part: 0), event(5, .like, by: "sam", part: 1),
        ])
        XCTAssertEqual(state["G1"], [ReactionSummary(kind: .emoji("🎉"), actors: [.handle("mia")]),
                                     ReactionSummary(kind: .like, actors: [.handle("sam")])])
        XCTAssertTrue(Reactions.reduce([]).isEmpty)
    }

    /// The line above a reply names what it answers in one short line.
    func testReplyExcerpts() {
        let short = Message(id: "1", text: "Lunch?\nor dinner", date: base, isFromMe: false)
        XCTAssertEqual(MessageExcerpt.of(short), "Lunch?", "the first line only")
        let long = Message(id: "2", text: String(repeating: "word ", count: 40), date: base, isFromMe: false)
        XCTAssertTrue(MessageExcerpt.of(long).hasSuffix("…"))
        XCTAssertLessThanOrEqual(MessageExcerpt.of(long).count, MessageExcerpt.limit)
        let photo = Message(id: "3", text: "", date: base, isFromMe: false, attachments: [Attachment(id: "a", path: nil, name: "x.jpg", mimeType: "image/jpeg")])
        XCTAssertEqual(MessageExcerpt.of(photo), "Photo")
        XCTAssertEqual(MessageExcerpt.of(Message(id: "4", text: "", date: base, isFromMe: false, dateRetracted: base)), "Unsent message")
    }
}
