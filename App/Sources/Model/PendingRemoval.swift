import DownloadKit
import Foundation

struct AlertMessage: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct AddOutcome: Equatable {
    var added = 0
    /// The links the engine refused, and a message for each.
    var failedLinks: [URL] = []
    var failures: [String] = []
}

/// A removal waiting for the user to confirm: it would throw partly downloaded data away, or take several
/// entries off the list at once.
struct PendingRemoval: Equatable, Identifiable {
    let id = UUID()
    var ids: Set<DownloadID>
    var trashFiles: Bool
    /// How many of them have partial data that will be deleted.
    var partialCount: Int
    var totalCount: Int

    var title: String {
        totalCount == 1 ? String(localized: "Remove this download?") : String(localized: "Remove \(totalCount) downloads?")
    }

    /// Two whole sentences (what happens to partial data, what happens to finished files) joined by a space, so each
    /// can be translated as a sentence rather than assembled from fragments.
    var message: String {
        let files = trashFiles ? String(localized: "Finished files are moved to the Trash.") : String(localized: "Finished files are kept.")
        let partial: String
        switch partialCount {
        case 0: partial = String(localized: "They will be removed from the list.")
        case 1 where totalCount == 1: partial = String(localized: "The data downloaded so far will be deleted, and can’t be recovered.")
        case 1: partial = String(localized: "The data downloaded so far for 1 of them will be deleted, and can’t be recovered.")
        default: partial = String(localized: "The data downloaded so far for \(partialCount) of them will be deleted, and can’t be recovered.")
        }
        return partial + " " + files
    }
}
