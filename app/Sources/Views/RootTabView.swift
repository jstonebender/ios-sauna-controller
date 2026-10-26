import SwiftUI

struct RootTabView: View {
    @Environment(SaunaStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var isLandscape = false

    var body: some View {
        Group {
            // Side by side only on a wide display held landscape (iPhone Duo unfolded, iPad);
            // portrait and the closed Duo (compact width) get the familiar tabs.
            if #available(iOS 27.1, *), hSizeClass == .regular, isLandscape {
                sideBySide
            } else {
                tabs
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { SaunaActivityController.shared.configure(settings); store.startPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.startPolling() } else { store.stopPolling() }
        }
    }

    /// Log on the leading (left) side, Control on the trailing (right) side. ArrangementView
    /// keeps the two panes off the Duo's fold; rotating to portrait hands back to the tabs.
    @available(iOS 27.1, *)
    private var sideBySide: some View {
        ArrangementView {
            logTab
                .splitArrangementLayoutRatio(0.42)
        } secondary: {
            controlTab
        }
        .arrangementViewStyle(.split)
    }

    private var tabs: some View {
        TabView {
            controlTab.tabItem { Label("Control", systemImage: "flame.fill") }
            logTab.tabItem { Label("Log", systemImage: "list.bullet.rectangle.portrait") }
            #if DEBUG
            debugTab.tabItem { Label("Debug", systemImage: "ladybug.fill") }
            #endif
        }
    }

    private var controlTab: some View {
        NavigationStack {
            ControlView()
                .background(Theme.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { settingsButton; powerButton }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var logTab: some View {
        NavigationStack {
            LogView()
                .background(Theme.background)
                .navigationTitle("Log")
                .toolbar { settingsButton }
        }
    }

    #if DEBUG
    private var debugTab: some View {
        NavigationStack { DebugView().background(Theme.background) }
    }
    #endif

    @ToolbarContentBuilder private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .tint(Theme.textSecondary)
        }
    }

    @ToolbarContentBuilder private var powerButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { Task { await store.setPower(!store.state.power) } } label: {
                Image(systemName: "power")
            }
            .tint(store.state.power ? Theme.ember : Theme.textSecondary)
        }
    }
}
