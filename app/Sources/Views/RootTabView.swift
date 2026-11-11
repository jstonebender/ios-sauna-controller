import SwiftUI

struct RootTabView: View {
    @Environment(SaunaStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var isLandscape = false
    @State private var tab = 0

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

    // Classic fixed, full-width bottom bar (instead of iOS 26's floating pill).
    private var tabs: some View {
        tabContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FixedTabBar(selection: $tab)
            }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 1: logTab
        #if DEBUG
        case 2: debugTab
        #endif
        default: controlTab
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

/// Fixed, edge-to-edge bottom tab bar spanning the full width, with the tabs
/// spread evenly — the classic iOS look rather than the iOS 26 floating pill.
private struct FixedTabBar: View {
    @Binding var selection: Int

    private struct Item { let idx: Int; let title: String; let icon: String }
    private var items: [Item] {
        var list = [Item(idx: 0, title: "Control", icon: "flame.fill"),
                    Item(idx: 1, title: "Log", icon: "list.bullet.rectangle.portrait")]
        #if DEBUG
        list.append(Item(idx: 2, title: "Debug", icon: "ladybug.fill"))
        #endif
        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.idx) { item in
                let on = selection == item.idx
                Button {
                    selection = item.idx
                    Haptics.tap()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 20, weight: .semibold))
                        Text(item.title).font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(on ? Theme.ember : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
