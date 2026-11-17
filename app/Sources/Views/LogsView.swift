import SwiftUI

/// Live browser for saunad's own log (GET /logs). Shows the real events — timer armed,
/// preheat re-pegged, schedule fired, heater/watchdog warnings — newest at the bottom.
/// Excludes the per-request HTTP access spam by default; a toggle reveals everything.
struct LogsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var entries: [LogEntry] = []
    @State private var level = Level.info
    @State private var showAll = false
    @State private var error: String?
    @State private var pollTask: Task<Void, Never>?

    enum Level: String, CaseIterable, Identifiable {
        case info = "info", warning = "warning", error = "error"
        var id: String { rawValue }
        var label: String {
            switch self { case .info: return "All"; case .warning: return "Warnings"; case .error: return "Errors" }
        }
    }

    private var client: BridgeClient? {
        guard let url = settings.url else { return nil }
        return BridgeClient(base: url, apiKey: settings.apiKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(Theme.textTertiary.opacity(0.3))
            logList
        }
        .background(Theme.background)
        .navigationTitle("saunad logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .tint(Theme.ember)
            }
        }
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
        .onChange(of: level) { _, _ in Task { await refresh() } }
        .onChange(of: showAll) { _, _ in Task { await refresh() } }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $level) {
                ForEach(Level.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $showAll) { Text("HTTP").font(.caption) }
                .toggleStyle(.button)
                .tint(Theme.ember)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Theme.emberHot).padding()
                    } else if entries.isEmpty {
                        Text("No log lines yet.").font(.caption)
                            .foregroundStyle(Theme.textTertiary).padding()
                    }
                    ForEach(entries) { row($0) }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: entries) { _, _ in
                withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private let bottomID = "logs-bottom"

    private func row(_ e: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(e.date, format: .dateTime.hour().minute().second())
                    .foregroundStyle(Theme.textTertiary)
                Text(e.level)
                    .foregroundStyle(color(e.level)).fontWeight(.semibold)
                Text(short(e.logger)).foregroundStyle(Theme.textTertiary)
            }
            .font(.system(.caption2, design: .monospaced))
            Text(e.msg)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(e.level == "INFO" ? Theme.textPrimary : color(e.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func short(_ logger: String) -> String {
        logger.hasPrefix("saunad.") ? String(logger.dropFirst("saunad.".count)) : logger
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "WARNING": return Theme.amber
        case "ERROR", "CRITICAL": return Theme.emberHot
        default: return Theme.textSecondary
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func refresh() async {
        guard let client else { error = "Set the saunad address in Settings first."; return }
        do {
            entries = try await client.logs(limit: 300, level: level.rawValue, all: showAll)
            error = nil
        } catch {
            self.error = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }
}
