import Foundation
import KeyboardShortcuts

/// The empty-note prompt: a small rotating line that depends on the note, the time of day and the date.
@MainActor
enum Placeholder {
    private static let lines = [
        "A blank page. Your move.",
        "Write it down before it flies away.",
        "Ideas are shy. Catch them here.",
        "Every great plan starts as a messy note.",
        "Nothing here yet. Anything is possible.",
        "Think out loud. Quietly.",
        "Your future self will thank you.",
        "Small notes, big ideas.",
        "Tip: ⌘↩ turns any line into a task.",
        "Tip: type - [ ] for a checkbox.",
        "Tip: ⌘T opens another page.",
    ]

    private static var hideTip: String {
        let key = KeyboardShortcuts.getShortcut(for: .toggleNote)?.description ?? "⌃⇧Space"
        return "Psst — \(key) tucks me away."
    }

    static func text(seed: Int, date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.month, .day, .hour, .weekday], from: date)
        let month = c.month ?? 0, day = c.day ?? 0, hour = c.hour ?? 12

        switch (month, day) {
        case (1, 1): return "New year, fresh page."
        case (2, 14): return "Write something sweet."
        case (3, 14): return "3.14159… keep going."
        case (4, 1): return "This note is definitely not empty."
        case (10, 31): return "Boo. Write something spooky."
        case (12, 24), (12, 25): return "Make a list. Check it twice."
        case (12, 31): return "One last note for the year?"
        default: break
        }

        // Roughly one note in three greets the moment instead of a random line.
        let pick = abs(seed) % (lines.count + 6)
        if pick == lines.count { return hideTip }
        if pick > lines.count {
            switch hour {
            case 5..<11: return c.weekday == 2 ? "Monday. Let’s make a plan." : "Good morning. What’s first?"
            case 11..<14: return "Midday thoughts go here."
            case 14..<18: return "Afternoon. Anything worth keeping?"
            case 18..<23: return "Evening. Let it all out."
            default: return "Late-night ideas are the good ones."
            }
        }
        return lines[pick]
    }
}
