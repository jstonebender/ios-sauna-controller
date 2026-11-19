import Combine
import SwiftUI

struct RootTabView: View {
    @Environment(SaunaStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SchedulesStore.self) private var schedules
    @Environment(HeatingModel.self) private var heating
    @Environment(\.modelContext) private var ctx
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var showSchedules = false
    @State private var confirmingPower = false
    @State private var isLandscape = false
    /// Ticks while the app is foregrounded, to close a session once its timer ends.
    private let autoEndTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            // Side by side only on a wide display held landscape (iPhone Duo unfolded, iPad);
            // portrait and the closed Duo (compact width) get the familiar tabs.
            if #available(iOS 27.1, *), hSizeClass == .regular, isLandscape {
                sideBySide
            } else {
                controlTab
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { SaunaActivityController.shared.configure(settings); store.startPolling(); syncSchedules() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.startPolling()
                // Catch a timer that ended while the app was away — logs the backdated session.
                SessionRunner.autoEndIfDue(store: store, ctx: ctx, settings: settings)
                syncSchedules()   // keep saunad's copy current (it fires them)
            } else {
                store.stopPolling()
            }
        }
        // Push to saunad on every edit — it, not the phone, actually fires schedules.
        .onChange(of: schedules.schedules) { _, _ in syncSchedules() }
        .onReceive(autoEndTick) { _ in
            SessionRunner.autoEndIfDue(store: store, ctx: ctx, settings: settings)
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

    private var controlTab: some View {
        NavigationStack {
            ControlView()
                .background(Theme.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { settingsButton; schedulesButton; powerButton }
                .toolbarBackground(.hidden, for: .navigationBar)
                .sheet(isPresented: $showSchedules) { SchedulesView() }
                .confirmationDialog(store.state.power ? "Turn the sauna off?" : "Turn the sauna on?",
                                    isPresented: $confirmingPower, titleVisibility: .visible) {
                    Button(store.state.power ? "Turn Off" : "Turn On",
                           role: store.state.power ? .destructive : nil) { togglePower() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(store.state.power ? "Cuts power — heat, timer and lights all stop."
                                           : "Powers on the sauna.")
                }
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

    @ToolbarContentBuilder private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .tint(Theme.textSecondary)
        }
    }

    @ToolbarContentBuilder private var schedulesButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSchedules = true } label: { Image(systemName: "calendar") }
                .tint(Theme.textSecondary)
        }
    }

    @ToolbarContentBuilder private var powerButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if settings.confirmActions { confirmingPower = true } else { togglePower() }
            } label: {
                Image(systemName: "power")
            }
            .tint(store.state.power ? Theme.ember : Theme.textSecondary)
        }
    }

    private func togglePower() { Task { await store.setPower(!store.state.power) } }

    /// Push the current schedules + learned heat rate up to saunad, which fires them.
    /// Best-effort: a failed sync just retries on the next edit / foreground / launch.
    private func syncSchedules() {
        guard let url = settings.url else { return }
        let client = BridgeClient(base: url, apiKey: settings.apiKey)
        let scheds = schedules.schedules
        let rate = heating.ratePerMin
        Task { try? await client.syncSchedules(scheds, heatRatePerMin: rate) }
    }
}
