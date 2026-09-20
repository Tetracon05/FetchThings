import Foundation

/// Tells a paste from typing in the Add sheet's links field. A paste puts a whole address (or several lines) into the
/// field in one change; typing, autocorrect, dictation, and keystrokes that reach the field together on a busy main
/// thread add a few characters at a time. Judging by "more than one character arrived" turned a half-typed
/// `https://exam` into a card whenever two keystrokes landed together, so the size of the change is not enough: what
/// arrived has to look like an address.
enum PasteDetection {
    /// What `new` has that `old` lacks: the part between their common beginning and their common end.
    static func insertion(from old: String, to new: String) -> String {
        let before = Array(old), after = Array(new)
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        return String(after[head ..< after.count - tail])
    }

    /// The shortest thing a link can be once pasted: `http://a` is 8 characters.
    static let shortestLink = 8

    /// Whether the change from `old` to `new` is a paste of something to add: a line break (Option-Return, or several
    /// lines pasted), or one change that brought in a whole address, scheme included.
    static func looksLikePaste(from old: String, to new: String) -> Bool {
        if new.contains(where: \.isNewline) { return true }
        let inserted = insertion(from: old, to: new)
        return inserted.count >= shortestLink && inserted.contains("://")
    }
}
