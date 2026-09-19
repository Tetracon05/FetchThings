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
        // The speed mode lives at the foot of the sidebar, out of the way of the list.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpeedModePicker(model: model)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarSelection }, set: { if let item = $0 { model.sidebarSelection = item } })
    }

    private func row(_ item: SidebarItem) -> some View {
        let count = model.count(for: item)
        return Label(item.title, systemImage: item.symbol)
            .badge(count)
            .tag(item)
            .accessibilityValue(String(localized: "\(count) downloads"))
    }
}
