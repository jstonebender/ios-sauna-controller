import SwiftData
import SwiftUI

@main
struct SaunaControllerApp: App {
    @State private var settings: AppSettings
    @State private var store: SaunaStore
    @State private var schedules = SchedulesStore()
    @State private var heating = HeatingModel()

    init() {
        let s = AppSettings()
        let h = HeatingModel()
        _settings = State(initialValue: s)
        _heating = State(initialValue: h)
        _store = State(initialValue: SaunaStore(settings: s, heating: h))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(settings)
                .environment(store)
                .environment(schedules)
                .environment(heating)
                .tint(Theme.ember)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: SaunaSession.self)
    }
}
