import DownloadKit

enum SidebarItem: Hashable, Identifiable {
    case all, active, completed, failed
    case category(FileCategory)

    var id: Self { self }

    static let downloadItems: [SidebarItem] = [.all, .active, .completed, .failed]
    static let categoryItems: [SidebarItem] = FileCategory.allCases.map(SidebarItem.category)

    var title: String {
        switch self {
        case .all: String(localized: "All Downloads")
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .category(let category): category.title
        }
    }

    /// What the list says when this filter matches nothing while other downloads exist. Whole sentences: one built
    /// around a category's name ("No applications downloads.") reads badly and cannot be translated properly.
    var emptyMessage: String {
        switch self {
        case .all: String(localized: "There are no downloads.")
        case .active: String(localized: "There are no active downloads.")
        case .completed: String(localized: "There are no completed downloads.")
        case .failed: String(localized: "There are no failed downloads.")
        case .category(let category): String(localized: "There are no downloads in the category “\(category.title)”.")
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .category(let category): category.symbol
        }
    }

    /// "Active" is everything that is not finished: running, queued and paused downloads.
    func includes(_ download: DownloadSnapshot) -> Bool {
        switch self {
        case .all: true
        case .active: download.state != .completed && download.state != .failed
        case .completed: download.state == .completed
        case .failed: download.state == .failed
        case .category(let category): download.category == category
        }
    }
}
