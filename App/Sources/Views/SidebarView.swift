import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            Section("Downloads") {
                ForEach(SidebarItem.downloadItems) { row($0) }
            }
            Section("Categories") {
                ForEach(SidebarItem.categoryItems) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Filters")
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarSelection }, set: { if let item = $0 { model.sidebarSelection = item } })
    }

    private func row(_ item: SidebarItem) -> some View {
        let count = model.count(for: item)
        return Label(item.title, systemImage: item.symbol)
            .badge(count)
            .tag(item)
            .accessibilityValue(count == 1 ? "1 download" : "\(count) downloads")
    }
}
