import SwiftUI

struct RootTabView: View {
    @Environment(SaunaStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false

    var body: some View {
        Group {
            // Wide displays (iPhone Duo unfolded, iPad) get both screens at once; the
            // size class flips to compact when the Duo closes, falling back to tabs.
            if #available(iOS 27.1, *), hSizeClass == .regular {
                sideBySide
            } else {
                tabs
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { SaunaActivityController.shared.configure(settings); store.startPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.startPolling() } else { store.stopPolling() }
        }
    }

    /// Log on the leading (left) side, Control on the trailing (right) side. ArrangementView
    /// keeps the two panes off the Duo's fold and collapses to the primary alone when the
    /// device is closed in landscape.
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
