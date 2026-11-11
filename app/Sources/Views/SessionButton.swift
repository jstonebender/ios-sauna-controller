import SwiftData
import SwiftUI

/// Single source of truth for "Get In" / "Get Out" so the Control screen and the
/// Log screen share identical behavior (session timing, scene, Live Activity,
/// session record + HealthKit on the way out).
@MainActor
enum SessionRunner {
    static let key = "activeSessionStart"
    static var activeStart: Double { UserDefaults.standard.double(forKey: key) }
    static var inSession: Bool { activeStart > 0 }

    static func getIn(store: SaunaStore) {
        Haptics.success()
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
        Task {
            await store.beginSession()
            await store.getInScene()   // interior lights on · chroma red · 25-min timer
            await SaunaActivityController.shared.beginSession(now, state: store.state)
        }
    }

    static func getOut(store: SaunaStore, ctx: ModelContext) {
        Haptics.success()
        let start = Date(timeIntervalSince1970: activeStart)
        let end = Date()
        UserDefaults.standard.set(0.0, forKey: key)
        Task {
            let result = await store.endSession()   // record the peak before the heat goes off
            let session = SaunaSession(start: start, end: end,
                                       peakTempF: result?.peakTempF ?? store.state.currentTempF,
                                       targetTempF: store.state.targetTempF)
            ctx.insert(session)
            try? ctx.save()
            await store.stop()   // Get Out = done: power + heater off
            await HealthKitManager.shared.log(start: start, end: end, peakTempF: session.peakTempF)
            await SaunaActivityController.shared.endSession(state: store.state)
        }
    }
}

/// Compact Get In / Get Out button for the Control screen.
struct SessionButton: View {
    @Environment(SaunaStore.self) private var store
    @Environment(\.modelContext) private var ctx
    @AppStorage(SessionRunner.key) private var activeStart: Double = 0

    private var inSession: Bool { activeStart > 0 }

    var body: some View {
        Button {
            inSession ? SessionRunner.getOut(store: store, ctx: ctx)
                      : SessionRunner.getIn(store: store)
        } label: {
            Label(inSession ? "Get Out" : "Get In",
                  systemImage: inSession ? "figure.walk.departure" : "figure.walk.arrival")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 54)
                .foregroundStyle(inSession ? Theme.textPrimary : Theme.bg0)
                .background {
                    if inSession {
                        RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.white.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Theme.stroke))
                    } else {
                        RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Theme.emberGradient)
                    }
                }
                .emberGlow(Theme.ember, radius: 14, active: !inSession)
        }
        .buttonStyle(.plain)
    }
}
