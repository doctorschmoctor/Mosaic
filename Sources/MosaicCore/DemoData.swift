import Foundation

public enum DemoData {
    public static func conversations(now: Date = Date()) -> [Conversation] {
        let examples: [(String, [String], [(String, Bool)], Int)] = [
            ("Alex Morgan", ["alex@example.test"], [("Are we still on for coffee tomorrow?", false), ("Absolutely. The place on Spring Street?", true), ("Perfect. 10:30 works for me ☕", false), ("See you there!", true), ("Also, sending you that playlist tonight.", false)], 1),
            ("Weekend crew", ["mia@example.test", "jules@example.test", "sam@example.test"], [("Small cabin. Big weekend.", false), ("I'm in. Who's driving?", true), ("I can take three people 🚗", false), ("I'll bring breakfast stuff.", true), ("Let's leave Friday around 5?", false)], 2),
            ("Jamie Chen", ["jamie@example.test"], [("The new mockups are looking great.", false), ("Thanks! I simplified the navigation.", true), ("Much easier to follow now.", false), ("I'll send the final version this afternoon.", true), ("Amazing. No rush — take your time.", false)], 0),
            ("Mom", ["mom@example.test"], [("How's your week going?", false), ("Good! Busy, but good.", true), ("Don't forget to eat a real lunch 😊", false), ("Already on it. Are we doing dinner Sunday?", true), ("Of course. Your favorite pasta.", false)], 0),
            ("Sam Rivera", ["sam@example.test"], [("Found a new hiking trail for us.", false), ("Send me the details!", true), ("Great views. Only about 4 miles.", false)], 1),
            ("Design team", ["riley@example.test", "taylor@example.test"], [("Quick review at 2?", false), ("Works for me.", true), ("I'll share the board beforehand.", false)], 0),
            ("Taylor Brooks", ["taylor@example.test"], [("That restaurant was so good.", false), ("Already thinking about going back.", true)], 0),
            ("Riley Park", ["riley@example.test"], [("Did you finish the book?", false), ("Last chapter tonight!", true)], 0)
        ]
        return examples.enumerated().map { offset, example in
            let messages = example.2.enumerated().map { index, entry in
                Message(id: "demo-\(offset)-\(index)", text: entry.0,
                    date: now.addingTimeInterval(Double(-1800 - offset * 600 + index * 240)), isFromMe: entry.1,
                    sender: example.1.first, isDelivered: entry.1)
            }
            return Conversation(id: "demo-\(offset)", name: example.0, participants: example.1,
                preview: messages.last?.text ?? "", lastActivity: messages.last?.date ?? now,
                unreadCount: example.3, messages: messages)
        }
    }
}
