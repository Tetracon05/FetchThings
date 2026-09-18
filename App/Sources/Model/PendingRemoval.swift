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

/// A removal waiting for the user to confirm, because it would throw partly downloaded data away.
struct PendingRemoval: Equatable, Identifiable {
    let id = UUID()
    var ids: Set<DownloadID>
    var trashFiles: Bool
    /// How many of them have partial data that will be deleted.
    var partialCount: Int
    var totalCount: Int

    var title: String { totalCount == 1 ? "Remove this download?" : "Remove \(totalCount) downloads?" }

    var message: String {
        let partial = partialCount == 1
            ? "The data downloaded so far will be deleted, and can’t be recovered."
            : "The data downloaded so far for \(partialCount) of them will be deleted, and can’t be recovered."
        return trashFiles ? partial + " Finished files are moved to the Trash." : partial + " Finished files are kept."
    }
}
