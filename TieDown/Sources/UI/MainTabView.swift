import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(model.tabs) { tab in
                NavigationStack {
                    WebScreen(model: model.screen(for: tab), title: tab.title)
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab.id)
            }

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag("more")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !network.isOnline {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: network.isOnline)
    }

    /// Tapping the already-selected tab returns that tab to its start page (standard iOS behaviour).
    private var tabSelection: Binding<String> {
        Binding(
            get: { model.selectedTabId },
            set: { newValue in
                if newValue == model.selectedTabId,
                   let tab = model.tabs.first(where: { $0.id == newValue })
                {
                    model.screen(for: tab).goHome()
                }
                model.selectedTabId = newValue
            }
        )
    }
}

struct OfflineBanner: View {
    var body: some View {
        Label("No internet connection", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.orange)
            .accessibilityAddTraits(.isStaticText)
    }
}
